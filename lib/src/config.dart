import 'dart:io';

import 'logger.dart';
import 'util/byte_size.dart';

/// Default chunk granularity: 1 MiB, a good compromise between seek latency
/// and per-request overhead.
const int kDefaultChunkSize = 1 << 20;

/// Default disk budget: 2 GiB. `0` disables eviction.
const int kDefaultMaxCacheBytes = 2 << 30;

/// Default number of concurrent upstream range requests.
const int kDefaultMaxConcurrentUpstream = 4;

/// Everything the proxy needs, in one immutable object.
///
/// Nothing here reads a command line or the environment: a library is
/// configured by the program embedding it, not behind its back. Build one and
/// hand it to [VideoProxy], which wires the pieces together.
class Config {
  /// Creates a configuration and validates it straight away.
  ///
  /// Throws [ArgumentError] when a value cannot work, so a wrong setting fails
  /// at construction rather than on the first request.
  Config({
    required this.originBaseUrl,
    required this.cacheDirPath,
    this.chunkSize = kDefaultChunkSize,
    this.maxCacheBytes = kDefaultMaxCacheBytes,
    this.maxConcurrentUpstream = kDefaultMaxConcurrentUpstream,
    this.prefetchAhead = 0,
    this.continueAfterDisconnect = true,
    this.upstreamTimeout = const Duration(seconds: 30),
    this.connectTimeout = const Duration(seconds: 10),
    this.logLevel = LogLevel.info,
  }) {
    validate();
  }

  /// Base URL media is fetched from; an object key is appended to it.
  ///
  /// Any path prefix is preserved: `https://cdn.example.com/videos` plus the
  /// key `clips/a.mp4` resolves to
  /// `https://cdn.example.com/videos/clips/a.mp4`.
  final Uri originBaseUrl;

  /// Directory holding one `.bin` + `.meta.json` pair per cached object.
  final String cacheDirPath;

  /// Chunk granularity in bytes.
  final int chunkSize;

  /// Cache budget in bytes; `0` disables eviction.
  final int maxCacheBytes;

  /// Upper bound on in-flight upstream range requests.
  final int maxConcurrentUpstream;

  /// How many chunks to speculatively fetch after the one being read.
  final int prefetchAhead;

  /// Whether cache chunks keep filling after the client disconnects.
  final bool continueAfterDisconnect;

  /// Timeout for a single upstream range request.
  final Duration upstreamTimeout;

  /// Timeout for establishing an upstream connection.
  final Duration connectTimeout;

  /// Minimum severity the logger writes.
  final LogLevel logLevel;

  /// Directory holding the cache entries.
  Directory get cacheDirectory => Directory(cacheDirPath);

  /// Resolves an object [key] to the URL the origin serves it from.
  ///
  /// Every segment is percent-encoded on its own, so a key may contain `/`
  /// while staying inside the path the base URL defines.
  Uri urlFor(String key) {
    final encoded = key.split('/').map(Uri.encodeComponent).join('/');
    final base = originBaseUrl.toString();
    final separator = base.endsWith('/') ? '' : '/';
    return Uri.parse('$base$separator$encoded');
  }

  /// Throws [ArgumentError] when the configuration cannot work.
  void validate() {
    final scheme = originBaseUrl.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      throw ArgumentError.value(
        originBaseUrl,
        'originBaseUrl',
        'must be an http or https URL',
      );
    }
    if (originBaseUrl.host.isEmpty) {
      throw ArgumentError.value(
        originBaseUrl,
        'originBaseUrl',
        'must name a host',
      );
    }
    if (cacheDirPath.trim().isEmpty) {
      throw ArgumentError.value(cacheDirPath, 'cacheDirPath', 'must not be empty');
    }
    if (chunkSize < 4096) {
      throw ArgumentError(
        'chunkSize must be at least 4096 bytes (got $chunkSize).',
      );
    }
    if (maxCacheBytes != 0 && maxCacheBytes < chunkSize * 2) {
      throw ArgumentError(
        'maxCacheBytes ($maxCacheBytes) must be 0 (unlimited) or at least '
        'twice chunkSize (${chunkSize * 2}).',
      );
    }
    if (maxConcurrentUpstream < 1) {
      throw ArgumentError(
        'maxConcurrentUpstream must be at least 1 (got $maxConcurrentUpstream).',
      );
    }
    if (prefetchAhead < 0) {
      throw ArgumentError('prefetchAhead must not be negative.');
    }
    if (upstreamTimeout <= Duration.zero) {
      throw ArgumentError('upstreamTimeout must be positive.');
    }
    if (connectTimeout <= Duration.zero) {
      throw ArgumentError('connectTimeout must be positive.');
    }
  }

  /// Log-friendly snapshot of the effective settings.
  Map<String, Object?> describe() => <String, Object?>{
    'origin': originBaseUrl.toString(),
    'cacheDir': cacheDirPath,
    'chunkSize': formatByteSize(chunkSize),
    'maxCacheBytes': maxCacheBytes == 0
        ? 'unlimited'
        : formatByteSize(maxCacheBytes),
    'maxConcurrentUpstream': maxConcurrentUpstream,
    'prefetchAhead': prefetchAhead,
    'continueAfterDisconnect': continueAfterDisconnect,
    'upstreamTimeoutMs': upstreamTimeout.inMilliseconds,
    'connectTimeoutMs': connectTimeout.inMilliseconds,
    'logLevel': logLevel.name,
  };

  @override
  String toString() =>
      'Config(origin: $originBaseUrl, cache: $cacheDirPath, '
      'chunkSize: ${formatByteSize(chunkSize)})';
}
