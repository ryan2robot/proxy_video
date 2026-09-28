import 'dart:async';
import 'dart:io';

import '../cache/cache_entry.dart';
import '../cache/disk_cache.dart';
import '../cache/origin_client.dart';
import '../logger.dart';
import '../util/byte_range.dart';
import '../util/http_util.dart';

/// What one served window cost, used for request logging.
typedef _PumpOutcome = ({
  int sentBytes,
  bool peerGone,
  bool failed,
  int elapsedMs,
});

/// Serves media to browsers on top of the chunk cache, with the full range
/// semantics a `<video>` element depends on.
///
/// Two things make progressive playback work:
///
///  * answering a `Range` request with `206` and a matching `Content-Range`,
///    so the player knows the object's size and where it may seek, and
///  * streaming bytes as soon as the first chunk is on disk, instead of
///    buffering the whole object first.
///
/// Both live in [CacheEntry.readRange]; this class is the thin, testable
/// translation layer between HTTP and the cache. Every byte it forwards has
/// already been written to disk, which is why a second view of the same window
/// never touches the origin.
class MediaProxy {
  MediaProxy({
    required this.cache,
    this.continueAfterDisconnect = true,
    Logger? log,
  }) : _log = (log ?? rootLogger).child('proxy');

  /// Chunk cache that owns both the bytes and the upstream traffic.
  final DiskCache cache;

  /// Whether an aborted response keeps filling the cache in the background.
  ///
  /// When a player seeks away or the tab closes, the bytes it was about to
  /// receive are exactly what the next request will ask for. Finishing the
  /// window turns a wasted transfer into a warm cache.
  final bool continueAfterDisconnect;

  /// Upper bound on the final response close.
  ///
  /// A peer that vanished can leave the last write pending indefinitely, which
  /// would strand the handler and its log line forever instead of freeing the
  /// connection.
  static const Duration _closeTimeout = Duration(seconds: 10);

  final Logger _log;
  final Set<Future<void>> _backgroundFills = <Future<void>>{};
  int _backgroundFillCount = 0;
  int _backgroundFillTotal = 0;

  /// Background cache fills currently running.
  int get backgroundFillCount => _backgroundFillCount;

  /// Background cache fills started since launch.
  int get backgroundFillTotal => _backgroundFillTotal;

  /// Serves the media object [key] to [request].
  Future<void> serve(HttpRequest request, String key) async {
    if (request.method != 'GET' && request.method != 'HEAD') {
      request.response
        ..statusCode = HttpStatus.methodNotAllowed
        ..headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
      await request.response.close();
      return;
    }

    final safeKey = sanitizeKey(key);
    if (safeKey == null) {
      await _problem(request, HttpStatus.badRequest, 'Not a usable media key.');
      return;
    }

    final CacheEntry entry;
    final int totalSize;
    try {
      entry = await cache.entryFor(safeKey);
      totalSize = await entry.resolveTotalSize();
    } on OriginNotFoundException {
      await _problem(
        request,
        HttpStatus.notFound,
        '"$safeKey" is not available upstream.',
      );
      return;
    } on OriginRequestException catch (error) {
      _log.warn(
        'upstream rejected the request',
        fields: <String, Object?>{'key': safeKey, 'error': error},
      );
      await _problem(
        request,
        HttpStatus.badGateway,
        'The origin rejected the request.',
      );
      return;
    } on SocketException catch (error) {
      _log.warn(
        'upstream is unreachable',
        fields: <String, Object?>{'key': safeKey, 'error': error},
      );
      await _problem(
        request,
        HttpStatus.badGateway,
        'The origin is unreachable.',
      );
      return;
    } on TimeoutException {
      await _problem(
        request,
        HttpStatus.gatewayTimeout,
        'The origin timed out.',
      );
      return;
    } on HttpException catch (error) {
      _log.warn(
        'upstream connection failed',
        fields: <String, Object?>{'key': safeKey, 'error': error},
      );
      await _problem(
        request,
        HttpStatus.badGateway,
        'The origin connection failed.',
      );
      return;
    }

    final contentType = entry.contentType ?? contentTypeForPath(safeKey);

    if (totalSize == 0) {
      // Nothing can be ranged over, so answer a plain empty 200 rather than a
      // 206 whose Content-Range would describe no bytes at all.
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..headers.set(HttpHeaders.contentLengthHeader, '0')
        ..headers.set(HttpHeaders.contentTypeHeader, contentType);
      await request.response.close();
      return;
    }

    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    final parsed = RangeParseResult.parse(rangeHeader, totalSize);

    if (parsed.kind == RangeParseKind.unsatisfiable) {
      request.response
        ..statusCode = HttpStatus.requestedRangeNotSatisfiable
        ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          RangeParseResult.unsatisfiedContentRange(totalSize),
        );
      await request.response.close();
      _log.debug(
        'range is not satisfiable',
        fields: <String, Object?>{
          'key': safeKey,
          'range': rangeHeader,
          'size': totalSize,
          'note': parsed.note,
        },
      );
      return;
    }

    final partial = parsed.kind == RangeParseKind.satisfiable;
    final window = parsed.range ?? ByteRange(0, totalSize - 1);

    // `bufferOutput = false` is what makes this a stream rather than a
    // build-then-send: each `add` goes straight to the socket, so the player
    // starts decoding while later chunks are still being fetched.
    final response = request.response
      ..bufferOutput = false
      ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..headers.set(HttpHeaders.contentTypeHeader, contentType)
      // This proxy *is* the cache. Letting the browser buffer a second copy
      // would double the disk cost and hide the cache behaviour the debug UI
      // exists to show.
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..headers.set(HttpHeaders.contentLengthHeader, '${window.length}');

    final etag = entry.etag;
    if (etag != null) response.headers.set(HttpHeaders.etagHeader, etag);

    final lastModified = entry.lastModified;
    if (lastModified != null) {
      response.headers.set(
        HttpHeaders.lastModifiedHeader,
        formatHttpDate(lastModified),
      );
    }

    response.statusCode = partial ? HttpStatus.partialContent : HttpStatus.ok;
    if (partial) {
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        window.contentRange(totalSize),
      );
    }

    if (request.method == 'HEAD') {
      await response.close();
      _log.debug(
        'reported media metadata',
        fields: <String, Object?>{
          'key': safeKey,
          'size': totalSize,
          'range': rangeHeader,
        },
      );
      return;
    }

    // Push the status line and headers out before the first byte is fetched.
    // A player can then size its buffer and decide where to seek while the
    // origin is still being contacted, instead of waiting for data to learn
    // anything at all.
    await response.flush();

    final wasCached = entry.isRangeCached(window.start, window.end);
    entry.recordServe(wasCached: wasCached);

    final outcome = await _pump(response, entry, window);

    // Anything short of the whole window means the peer stopped listening
    // before the transfer finished. An upstream failure is tracked separately
    // and must not trigger even more upstream traffic.
    final shortBy = window.length - outcome.sentBytes;
    final aborted = !outcome.failed && shortBy > 0;

    if (aborted && continueAfterDisconnect) {
      _startBackgroundFill(entry, window);
    }

    _log.debug(
      'served media',
      fields: <String, Object?>{
        'key': safeKey,
        'status': response.statusCode,
        'range': rangeHeader,
        'cached': wasCached,
        'bytes': outcome.sentBytes,
        'ms': outcome.elapsedMs,
        if (aborted) 'aborted': true,
        if (outcome.peerGone) 'peerGone': true,
        if (shortBy > 0) 'shortBy': shortBy,
        if (outcome.failed) 'failed': true,
      },
    );
  }

  /// Waits for background cache fills, so a shutdown does not leave them
  /// half-written.
  Future<void> whenIdle() async {
    while (_backgroundFills.isNotEmpty) {
      await Future.wait<void>(_backgroundFills.toList(growable: false));
    }
  }

  /// Streams [window] to the client, with the cache filling as a side effect.
  ///
  /// A fresh chunk is already on disk by the time its bytes reach the socket,
  /// so "write the stream to the cache" and "send it to the browser" are the
  /// same pass rather than two.
  Future<_PumpOutcome> _pump(
    HttpResponse response,
    CacheEntry entry,
    ByteRange window,
  ) async {
    final stopwatch = Stopwatch()..start();
    var sent = 0;
    var clientGone = false;
    var failed = false;

    // `done` completes with an error when the peer disappears. Recording that
    // lets the loop stop between chunks instead of waiting for a write to blow
    // up, while still letting the chunk already in flight finish and land in
    // the cache.
    unawaited(
      response.done.then<void>(
        (_) {},
        onError: (Object error) {
          clientGone = true;
        },
      ),
    );

    try {
      await for (final piece in entry.readRange(window.start, window.end)) {
        if (clientGone) break;
        response.add(piece);
        sent += piece.length;
      }
      await response.flush();
    } on SocketException {
      clientGone = true;
    } on HttpException {
      clientGone = true;
    } on Object catch (error, stackTrace) {
      failed = true;
      _log.error(
        'streaming failed',
        fields: <String, Object?>{'key': entry.key, 'error': error},
        stackTrace: Logger.level == LogLevel.debug ? stackTrace : null,
      );
    } finally {
      try {
        await response.close().timeout(_closeTimeout);
      } on Object {
        clientGone = true;
      }
    }

    stopwatch.stop();
    return (
      sentBytes: sent,
      peerGone: clientGone,
      failed: failed,
      elapsedMs: stopwatch.elapsedMilliseconds,
    );
  }

  void _startBackgroundFill(CacheEntry entry, ByteRange window) {
    // Resume where the transfer was cut short. Re-reading the part that already
    // landed would double the origin traffic for nothing.
    final resumeAt = entry.firstUncachedOffset(window.start, window.end);
    if (resumeAt == null) return;

    _backgroundFillCount++;
    _backgroundFillTotal++;
    final fill = () async {
      try {
        // Draining discards the bytes but keeps their side effect: every chunk
        // is written to disk on the way past.
        await entry.readRange(resumeAt, window.end).drain<void>();
      } on Object catch (error) {
        _log.debug(
          'background fill stopped',
          fields: <String, Object?>{'key': entry.key, 'error': error},
        );
      }
    }();

    _backgroundFills.add(fill);
    unawaited(
      fill.whenComplete(() {
        _backgroundFills.remove(fill);
        _backgroundFillCount--;
      }),
    );
  }

  Future<void> _problem(
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
