import 'dart:io';

import 'cache/disk_cache.dart';
import 'cache/origin_client.dart';
import 'config.dart';
import 'logger.dart';
import 'proxy/http_origin_client.dart';
import 'proxy/media_proxy.dart';

/// A range proxy over a disk-backed chunk cache, wired up from one [Config].
///
/// This is the whole package in one object: construct it, hand it the requests
/// you want served, and close it on shutdown.
///
/// ```dart
/// final app = VideoProxy(config);
/// final server = await HttpServer.bind('127.0.0.1', 8080);
/// await for (final request in server) {
///   await app.serve(request, request.uri.pathSegments.skip(1).join('/'));
/// }
/// await app.close();
/// ```
class VideoProxy {
  /// Builds the cache and the proxy from [config].
  ///
  /// [log] defaults to [rootLogger]; pass a configured child logger to keep
  /// this subsystem's output separate.
  VideoProxy(this.config, {Logger? log}) {
    final logger = log ?? rootLogger;

    final upstream = HttpOriginClient(
      urlFor: config.urlFor,
      connectTimeout: config.connectTimeout,
      requestTimeout: config.upstreamTimeout,
      log: logger,
    );
    origin = upstream;
    cache = DiskCache(
      root: config.cacheDirectory,
      chunkSize: config.chunkSize,
      maxBytes: config.maxCacheBytes,
      origin: upstream,
      log: logger,
      maxConcurrentUpstream: config.maxConcurrentUpstream,
      prefetchAhead: config.prefetchAhead,
    );
    proxy = MediaProxy(
      cache: cache,
      continueAfterDisconnect: config.continueAfterDisconnect,
      log: logger,
    );
  }

  /// Settings this instance was built from.
  final Config config;

  /// Where missing bytes come from.
  late final OriginClient origin;

  /// The chunk cache holding the bytes.
  late final DiskCache cache;

  /// The range proxy that serves clients.
  late final MediaProxy proxy;

  /// Serves the media object [key] to [request].
  ///
  /// [key] is an object key such as `clips/a.mp4`; it is validated before any
  /// file or upstream access happens.
  Future<void> serve(HttpRequest request, String key) =>
      proxy.serve(request, key);

  /// Waits for background fills, flushes cache metadata and drops connections.
  ///
  /// Call this once when the surrounding application shuts down: without it a
  /// restart can leave a half-written chunk or an open upstream socket behind.
  Future<void> close() async {
    await proxy.whenIdle();
    await cache.close();
    origin.close();
  }
}
