import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../logger.dart';
import '../util/byte_range.dart';
import '../util/http_util.dart';

/// A stand-in for the CDN that fronts the object store.
///
/// It publishes `<root>/<key>` over HTTP with the full range behaviour a real
/// edge would offer: `GET` and `HEAD`, `206` with `Content-Range`, `416` for an
/// unsatisfiable range, plus `Accept-Ranges`, `ETag` and `Last-Modified`.
///
/// The point is that the proxy is exercised against a *real* HTTP origin. If
/// the origin mis-stated a range, or the proxy mishandled a `206`, the
/// difference shows up here instead of hiding behind a shortcut file read.
/// [throttleBytesPerSecond] and [latency] additionally let a test model a slow
/// CDN, which is the only way to prove that playback really starts before the
/// whole object has been transferred.
class OriginServer {
  OriginServer({
    required this.root,
    this.bindAddress = '127.0.0.1',
    this.port = 8090,
    this.throttleBytesPerSecond = 0,
    this.latency = Duration.zero,
    Logger? log,
  }) : _log = (log ?? rootLogger).child('origin');

  /// Directory holding the objects; keys map onto it directly.
  final Directory root;

  /// Address to bind.
  final String bindAddress;

  /// Port to bind; `0` asks the OS for a free one.
  final int port;

  /// Bandwidth cap in bytes per second; `0` means unlimited.
  final int throttleBytesPerSecond;

  /// Delay inserted before the first byte of every response.
  final Duration latency;

  final Logger _log;

  HttpServer? _server;
  int _requestCount = 0;
  int _rangeRequestCount = 0;
  int _headCount = 0;

  /// Port actually listening; differs from [port] when it was `0`.
  int get boundPort => _server?.port ?? port;

  /// Base URI of the running server.
  Uri get baseUri => Uri(scheme: 'http', host: bindAddress, port: boundPort);

  /// Whether the server is listening.
  bool get isRunning => _server != null;

  /// Requests served since start, for assertions about cache hits.
  int get requestCount => _requestCount;

  /// Requests that carried a usable `Range` header.
  int get rangeRequestCount => _rangeRequestCount;

  /// `HEAD` requests served.
  int get headCount => _headCount;

  /// Binds and starts serving.
  Future<void> start() async {
    if (_server != null) return;

    final server = await HttpServer.bind(bindAddress, port);
    // Compression would rewrite Content-Length and invalidate byte ranges;
    // media is already compressed, so there is nothing to gain either.
    server.autoCompress = false;
    _server = server;

    unawaited(_accept(server));
    _log.info(
      'origin listening',
      fields: <String, Object?>{'url': baseUri.toString(), 'root': root.path},
    );
  }

  /// Stops serving and drops keep-alive connections.
  Future<void> stop() async {
    final server = _server;
    _server = null;
    if (server != null) await server.close(force: true);
  }

  Future<void> _accept(HttpServer server) async {
    await for (final request in server) {
      // Each request is handled independently; `_handleSafely` never throws.
      unawaited(_handleSafely(request));
    }
  }

  Future<void> _handleSafely(HttpRequest request) async {
    _requestCount++;
    try {
      await _handle(request);
    } on Object catch (error, stackTrace) {
      _log.warn(
        'origin request failed',
        fields: <String, Object?>{'path': request.uri.path, 'error': error},
        stackTrace: Logger.level == LogLevel.debug ? stackTrace : null,
      );
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } on Object {
        // The peer is already gone; there is nobody left to tell.
      }
    }
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.method == 'HEAD') _headCount++;

    if (request.method != 'GET' && request.method != 'HEAD') {
      request.response
        ..statusCode = HttpStatus.methodNotAllowed
        ..headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
      await request.response.close();
      return;
    }

    final segments = request.uri.pathSegments;
    if (segments.length < 2 || segments.first != 'origin') {
      await _sendStatus(
        request,
        HttpStatus.notFound,
        'This origin only serves /origin/<key>.',
      );
      return;
    }

    final key = sanitizeKey(segments.skip(1).join('/'));
    if (key == null) {
      await _sendStatus(request, HttpStatus.badRequest, 'Unusable object key.');
      return;
    }

    final file = File(p.joinAll(<String>[root.path, ...key.split('/')]));
    if (!file.existsSync()) {
      await _sendStatus(request, HttpStatus.notFound, '"$key" was not found.');
      return;
    }

    final size = await file.length();
    final modified = await file.lastModified();

    final response = request.response
      ..bufferOutput = false
      ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..headers.set(HttpHeaders.contentTypeHeader, contentTypeForPath(key))
      ..headers.set(HttpHeaders.etagHeader, makeEtag(size, modified))
      ..headers.set(HttpHeaders.lastModifiedHeader, formatHttpDate(modified));

    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    final parsed = RangeParseResult.parse(rangeHeader, size);
    if (parsed.kind == RangeParseKind.satisfiable ||
        parsed.kind == RangeParseKind.unsatisfiable) {
      _rangeRequestCount++;
    }

    final headOnly = request.method == 'HEAD';

    switch (parsed.kind) {
      case RangeParseKind.unsatisfiable:
        response
          ..statusCode = HttpStatus.requestedRangeNotSatisfiable
          ..headers.set(
            HttpHeaders.contentRangeHeader,
            RangeParseResult.unsatisfiedContentRange(size),
          );
        await response.close();

      case RangeParseKind.satisfiable:
        final range = parsed.range!;
        response
          ..statusCode = HttpStatus.partialContent
          ..headers.set(
            HttpHeaders.contentRangeHeader,
            range.contentRange(size),
          )
          ..headers.set(HttpHeaders.contentLengthHeader, '${range.length}');

        if (headOnly) {
          await response.close();
          return;
        }
        await _delayFirstByte();
        await _pipe(response, file.openRead(range.start, range.end + 1));

      case RangeParseKind.none:
      case RangeParseKind.ignore:
        response
          ..statusCode = HttpStatus.ok
          ..headers.set(HttpHeaders.contentLengthHeader, '$size');

        if (headOnly) {
          await response.close();
          return;
        }
        await _delayFirstByte();
        await _pipe(response, file.openRead());
    }
  }

  Future<void> _delayFirstByte() async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);
  }

  Future<void> _pipe(HttpResponse response, Stream<List<int>> source) async {
    final throttle = throttleBytesPerSecond;
    try {
      await for (final piece in source) {
        if (throttle > 0) {
          // Pace the origin so "playback started before the file finished"
          // cannot accidentally pass on a fast local disk.
          final micros =
              (piece.length * Duration.microsecondsPerSecond) ~/ throttle;
          if (micros > 0) {
            await Future<void>.delayed(Duration(microseconds: micros));
          }
        }
        response.add(piece);
      }
      await response.flush();
    } on SocketException {
      // The client disconnected mid-response. Aborts are expected whenever a
      // player seeks, so this is not an error worth reporting.
    } finally {
      try {
        await response.close();
      } on Object {
        // Same as above: the socket is already gone.
      }
    }
  }

  Future<void> _sendStatus(
    HttpRequest request,
    int statusCode,
    String message,
  ) async {
    final response = request.response
      ..statusCode = statusCode
      ..headers.set(HttpHeaders.contentTypeHeader, 'text/plain; charset=utf-8');

    if (request.method != 'HEAD') response.write(message);
    await response.close();
  }
}
