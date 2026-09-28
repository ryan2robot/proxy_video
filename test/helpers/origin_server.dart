import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:proxy_video/proxy_video.dart';

/// A minimal static-file origin with the range semantics a CDN exposes.
///
/// Test scaffolding, not part of the package: the proxy's contract is "talk
/// HTTP to a range-capable origin", and the only way to test that end to end is
/// to be one. Implements `HEAD`, plain `GET`, `Range`/`206`, `416`, and
/// optional bandwidth throttling, so progressive playback can be exercised
/// without a real network in the loop.
class OriginServer {
  OriginServer({
    required this.root,
    this.port = 0,
    this.throttleBytesPerSecond = 0,
    Logger? log,
  }) : _log = log ?? rootLogger;

  /// Directory files are served from; a request path maps onto it directly.
  final Directory root;

  /// Port to bind; `0` asks the OS for one.
  final int port;

  /// Bandwidth cap in bytes per second. `0` streams as fast as the socket takes.
  final int throttleBytesPerSecond;

  final Logger _log;

  static const int _pieceSize = 32 * 1024;
  static final RegExp _rangePattern = RegExp(r'^bytes=(\d*)-(\d*)$');

  HttpServer? _server;

  /// `HEAD` requests served.
  int headCount = 0;

  /// `GET` requests served, whether or not they carried a `Range`.
  int rangeRequestCount = 0;

  /// Port actually listening; differs from [port] when it was `0`.
  int get boundPort => _server?.port ?? port;

  /// Base URI of the running origin.
  Uri get baseUri => Uri(scheme: 'http', host: '127.0.0.1', port: boundPort);

  /// Maps an object key onto the URL this origin serves it from.
  Uri urlFor(String key) =>
      baseUri.replace(pathSegments: key.split('/'));

  /// Binds and starts serving.
  Future<void> start() async {
    if (_server != null) return;
    final server = await HttpServer.bind('127.0.0.1', port);
    // Compression would rewrite Content-Length and make byte ranges lie.
    server.autoCompress = false;
    _server = server;
    unawaited(_accept(server));
  }

  /// Stops serving and drops live connections.
  Future<void> stop() async {
    final server = _server;
    _server = null;
    if (server != null) await server.close(force: true);
  }

  Future<void> _accept(HttpServer server) async {
    await for (final request in server) {
      try {
        await _handle(request);
      } on Object catch (error) {
        _log.debug(
          'origin request failed',
          fields: <String, Object?>{'path': request.uri.path, 'error': error},
        );
        try {
          await request.response.close();
        } on Object {
          // The peer is gone; nothing left to close.
        }
      }
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.pathSegments.join('/');
    final file = File(p.join(root.path, path));

    if (request.method == 'HEAD') {
      headCount++;
      if (!file.existsSync()) return _notFound(request);

      final length = await file.length();
      final modified = (await file.lastModified()).toUtc();
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.set(HttpHeaders.contentLengthHeader, '$length')
        ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..headers.set(HttpHeaders.etagHeader, _etag(length))
        ..headers.set(HttpHeaders.lastModifiedHeader, formatHttpDate(modified))
        ..headers.set(HttpHeaders.contentTypeHeader, contentTypeForPath(path));
      await request.response.close();
      return;
    }

    if (request.method != 'GET') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }

    rangeRequestCount++;
    if (!file.existsSync()) return _notFound(request);

    final length = await file.length();
    final header = request.headers.value(HttpHeaders.rangeHeader);

    var partial = false;
    var from = 0;
    var to = length - 1;

    if (header != null) {
      final match = _rangePattern.firstMatch(header.trim());
      final captured =
          match != null && (match.group(1)!.isNotEmpty || match.group(2)!.isNotEmpty);

      if (captured) {
        final startText = match.group(1)!;
        final endText = match.group(2)!;

        if (startText.isEmpty) {
          final suffix = int.parse(endText);
          if (suffix <= 0 || length == 0) return _unsatisfiable(request, length);
          from = math.max(0, length - suffix);
        } else {
          from = int.parse(startText);
          if (from >= length) return _unsatisfiable(request, length);
          if (endText.isNotEmpty) {
            to = math.min(int.parse(endText), length - 1);
          }
        }

        if (to < from) return _unsatisfiable(request, length);
        partial = true;
      }
    }

    request.response
      ..bufferOutput = false
      ..statusCode = partial ? HttpStatus.partialContent : HttpStatus.ok
      ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..headers.set(HttpHeaders.contentTypeHeader, contentTypeForPath(path))
      ..headers.set(HttpHeaders.etagHeader, _etag(length))
      ..headers.set(HttpHeaders.contentLengthHeader, '${to - from + 1}');
    if (partial) {
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $from-$to/$length',
      );
    }

    await _write(request.response, file, from, to);
  }

  Future<void> _write(
    HttpResponse response,
    File file,
    int from,
    int to,
  ) async {
    final handle = await file.open();
    final stopwatch = Stopwatch()..start();
    final total = to - from + 1;
    var sent = 0;

    try {
      while (sent < total) {
        final size = math.min(_pieceSize, total - sent);
        await handle.setPosition(from + sent);
        final piece = await handle.read(size);
        if (piece.isEmpty) break;

        response.add(piece);
        sent += piece.length;

        // Pace the response to the configured rate, measuring from the start so
        // scheduling jitter does not accumulate into a slower transfer. The
        // final piece is never delayed: holding the response open past its last
        // byte would keep the file handle — and the temp directory a test is
        // about to delete — busy for no reason.
        if (throttleBytesPerSecond <= 0) {
          await response.flush();
        } else if (sent < total) {
          final budgetMs = (sent / throttleBytesPerSecond * 1000).round();
          final spentMs = stopwatch.elapsedMilliseconds;
          if (budgetMs > spentMs) {
            await Future<void>.delayed(
              Duration(milliseconds: budgetMs - spentMs),
            );
          }
        }
      }
    } finally {
      await handle.close();
      try {
        await response.close();
      } on Object {
        // The client vanished mid-write.
      }
    }
  }

  Future<void> _notFound(HttpRequest request) async {
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  Future<void> _unsatisfiable(HttpRequest request, int length) async {
    request.response
      ..statusCode = HttpStatus.requestedRangeNotSatisfiable
      ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
    await request.response.close();
  }

  /// A weak-but-stable tag: any change in length changes the tag.
  static String _etag(int length) => '"${length.toRadixString(16)}"';
}
