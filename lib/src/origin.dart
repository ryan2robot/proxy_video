import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'logger.dart';
import 'util.dart';

/// Metadata the origin advertises for one object.
class OriginMetadata {
  const OriginMetadata({
    required this.totalSize,
    this.etag,
    this.lastModified,
    this.contentType,
  });

  /// Total object size in bytes.
  final int totalSize;

  /// Origin entity tag, when it exposes one.
  final String? etag;

  /// Origin modification time, when it exposes one.
  final DateTime? lastModified;

  /// Origin content type, when it exposes one.
  final String? contentType;

  @override
  String toString() =>
      'OriginMetadata(size: $totalSize, etag: $etag, type: $contentType)';
}

/// Raised when the origin reports that an object does not exist.
class OriginNotFoundException implements Exception {
  const OriginNotFoundException(this.key);

  /// The missing object key.
  final String key;

  @override
  String toString() => 'OriginNotFoundException: "$key" was not found upstream';
}

/// Thrown when the origin returns fewer bytes than a range asked for.
class OriginTruncatedException implements Exception {
  const OriginTruncatedException({
    required this.key,
    required this.expected,
    required this.received,
  });

  /// The object being read.
  final String key;

  /// Number of bytes requested.
  final int expected;

  /// Number of bytes actually delivered.
  final int received;

  @override
  String toString() =>
      'OriginTruncatedException: "$key" delivered $received of $expected bytes';
}

/// Raised when the origin answers a range request with an unexpected status.
class OriginRequestException implements Exception {
  const OriginRequestException({
    required this.key,
    required this.statusCode,
    this.detail,
  });

  /// Object that was requested.
  final String key;

  /// HTTP status the origin answered with; `0` for a transport-level failure.
  final int statusCode;

  /// Extra context, such as a timeout description.
  final String? detail;

  @override
  String toString() {
    final suffix = detail == null ? '' : ' ($detail)';
    return 'OriginRequestException: "$key" answered $statusCode$suffix';
  }
}

/// Reads byte ranges from the origin (a real CDN, or a test double).
///
/// Deliberately narrow: the cache layer only ever needs to ask "how big is this
/// object" and "give me this byte range", which is exactly the surface a CDN
/// exposes.
abstract class OriginClient {
  /// Returns metadata for [key], or `null` when the object is missing.
  Future<OriginMetadata?> head(String key);

  /// Streams the inclusive byte range [start]-[end] of [key].
  ///
  /// Implementations must emit exactly `end - start + 1` bytes beginning at
  /// [start], even when the origin ignores `Range` and answers `200`: skipping
  /// the leading bytes is the client's responsibility.
  Stream<List<int>> openRange(String key, int start, int end);

  /// Releases pooled connections.
  void close();
}

/// [OriginClient] that reads ranges over HTTP from a CDN or object store.
///
/// The URL for a key is injected rather than derived, so the storage backend
/// stays in charge of how its objects are addressed — a bucket endpoint, a CDN
/// hostname, or a signed URL all work without this class knowing the
/// difference.
///
/// Requires the origin to answer `HEAD` with a `Content-Length`: that is how
/// the cache learns an object's size before deciding which chunks to fetch.
class HttpOriginClient implements OriginClient {
  HttpOriginClient({
    required this.urlFor,
    this.connectTimeout = const Duration(seconds: 10),
    this.requestTimeout = const Duration(seconds: 30),
    Logger? log,
  }) : _log = (log ?? rootLogger).child('upstream') {
    _client = HttpClient()
      ..connectionTimeout = connectTimeout
      // Decompression would silently change body lengths and make byte ranges
      // meaningless.
      ..autoUncompress = false
      ..maxConnectionsPerHost = 32;
  }

  /// Maps an object key onto the URL the origin serves it from.
  final Uri Function(String key) urlFor;

  /// How long to wait for a connection.
  final Duration connectTimeout;

  /// How long to wait for response headers.
  final Duration requestTimeout;

  final Logger _log;
  late final HttpClient _client;

  @override
  Future<OriginMetadata?> head(String key) async {
    final response = await _open(key, 'HEAD');

    // A HEAD response carries no body, so draining it only serves to release
    // the connection back to the pool.
    await _discard(response);

    final status = response.statusCode;
    if (status == HttpStatus.notFound) return null;
    if (status >= HttpStatus.badRequest) {
      throw OriginRequestException(key: key, statusCode: status);
    }

    final rawLength = response.headers.value(HttpHeaders.contentLengthHeader);
    final size = rawLength == null ? null : int.tryParse(rawLength);
    if (size == null) {
      throw OriginRequestException(
        key: key,
        statusCode: status,
        detail: 'the origin did not report a Content-Length',
      );
    }

    return OriginMetadata(
      totalSize: size,
      etag: response.headers.value(HttpHeaders.etagHeader),
      lastModified: parseHttpDate(
        response.headers.value(HttpHeaders.lastModifiedHeader),
      ),
      contentType: response.headers.contentType?.toString(),
    );
  }

  @override
  Stream<List<int>> openRange(String key, int start, int end) async* {
    final response = await _open(key, 'GET', range: ByteRange(start, end));

    switch (response.statusCode) {
      case HttpStatus.partialContent:
        yield* _forward(response, key: key, expected: end - start + 1);

      case HttpStatus.ok:
        // The origin ignored `Range` and answered `200`. Trim on this side so
        // callers still receive exactly the window they asked for; letting it
        // through untrimmed would poison the cache with bytes written at the
        // wrong offset.
        yield* _trim(response, key: key, start: start, end: end);

      case HttpStatus.notFound:
        await _discard(response);
        throw OriginNotFoundException(key);

      case HttpStatus.requestedRangeNotSatisfiable:
        await _discard(response);
        throw OriginRequestException(
          key: key,
          statusCode: HttpStatus.requestedRangeNotSatisfiable,
          detail: 'the window $start-$end is not satisfiable',
        );

      default:
        final detail = await _readBody(response);
        throw OriginRequestException(
          key: key,
          statusCode: response.statusCode,
          detail: detail,
        );
    }
  }

  @override
  void close() => _client.close(force: true);

  /// Streams an already-correct `206` body through untouched.
  Stream<List<int>> _forward(
    HttpClientResponse response, {
    required String key,
    required int expected,
  }) async* {
    var received = 0;
    await for (final piece in response) {
      received += piece.length;
      yield piece;
    }

    if (received != expected) {
      throw OriginTruncatedException(
        key: key,
        expected: expected,
        received: received,
      );
    }
  }

  /// Trims a `200` body down to the requested window.
  Stream<List<int>> _trim(
    HttpClientResponse response, {
    required String key,
    required int start,
    required int end,
  }) async* {
    final expected = end - start + 1;
    var offset = 0;
    var delivered = 0;

    await for (final piece in response) {
      final pieceStart = offset;
      offset += piece.length;
      if (offset <= start) continue;
      if (pieceStart > end) break;

      final bytes = piece is Uint8List ? piece : Uint8List.fromList(piece);
      final lastInPiece = offset - 1;
      final windowEnd = end < lastInPiece ? end : lastInPiece;
      final from = start > pieceStart ? start - pieceStart : 0;
      final to = windowEnd - pieceStart + 1;
      if (to <= from) continue;

      delivered += to - from;
      yield Uint8List.sublistView(bytes, from, to);
    }

    if (delivered != expected) {
      throw OriginTruncatedException(
        key: key,
        expected: expected,
        received: delivered,
      );
    }
  }

  Future<HttpClientResponse> _open(
    String key,
    String method, {
    ByteRange? range,
  }) async {
    final url = urlFor(key);
    final request = await _client
        .openUrl(method, url)
        .timeout(
          connectTimeout,
          onTimeout: () => throw OriginRequestException(
            key: key,
            statusCode: 0,
            detail:
                'connecting to $url timed out '
                'after ${connectTimeout.inMilliseconds}ms',
          ),
        );

    request.followRedirects = true;
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    if (range != null) {
      request.headers.set(
        HttpHeaders.rangeHeader,
        'bytes=${range.start}-${range.end}',
      );
    }

    return request.close().timeout(
      requestTimeout,
      onTimeout: () => throw OriginRequestException(
        key: key,
        statusCode: 0,
        detail:
            '$url did not respond within ${requestTimeout.inMilliseconds}ms',
      ),
    );
  }

  /// Consumes a response the caller does not intend to read.
  ///
  /// Without this, an unread body keeps its connection unusable and the pool
  /// slowly starves — which surfaces much later as mysterious timeouts.
  Future<void> _discard(HttpClientResponse response) async {
    try {
      await response.drain<void>();
    } on Object catch (error) {
      _log.debug(
        'discarding a response body failed',
        fields: <String, Object?>{'error': error},
      );
    }
  }

  /// Reads a short error body for diagnostics, then releases the connection.
  Future<String?> _readBody(HttpClientResponse response) async {
    try {
      final builder = BytesBuilder(copy: false);
      await for (final piece in response) {
        builder.add(piece);
      }

      final text = String.fromCharCodes(builder.takeBytes()).trim();
      if (text.isEmpty) return null;
      return text.length <= 200 ? text : '${text.substring(0, 200)}...';
    } on Object {
      return null;
    }
  }
}
