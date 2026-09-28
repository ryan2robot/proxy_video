/// Metadata the origin advertises for one object.
class OriginMetadata {
  const OriginMetadata({
    required this.totalSize,
    this.etag,
    this.lastModified,
    this.contentType,
    this.acceptsRanges = true,
  });

  /// Total object size in bytes.
  final int totalSize;

  /// Origin entity tag, when it exposes one.
  final String? etag;

  /// Origin modification time, when it exposes one.
  final DateTime? lastModified;

  /// Origin content type, when it exposes one.
  final String? contentType;

  /// Whether the origin answered `Accept-Ranges: bytes`.
  final bool acceptsRanges;

  @override
  String toString() =>
      'OriginMetadata(size: $totalSize, etag: $etag, ranges: $acceptsRanges)';
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

/// Reads byte ranges from the origin (a real COS/CDN, or the local simulated
/// one).
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
