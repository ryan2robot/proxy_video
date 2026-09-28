import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:proxy_video/proxy_video.dart';

/// Starts the proxy service.
///
/// Three pieces are wired together here, and the order matters:
///
///   1. the **origin** — a real HTTP endpoint serving objects with full range
///      support. With the local backend it is the simulated CDN; with COS it is
///      the bucket or the CDN in front of it,
///   2. the **cache**, which owns chunk state and upstream traffic, and
///   3. the **app server**, which serves `/media`, the JSON API and the UI.
///
/// The proxy only ever talks HTTP to step 1, which is what makes swapping a real
/// CDN in a configuration change rather than a code change.
Future<void> main(List<String> arguments) async {
  final parser = Config.buildServerParser();

  final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (error) {
    stderr
      ..writeln('error: ${error.message}')
      ..writeln(_usage(parser));
    exitCode = exitUsage;
    return;
  }

  if (cliFlag(args, 'help')) {
    stdout.writeln(_usage(parser));
    return;
  }

  try {
    exitCode = await _run(args);
  } on Object catch (error, stackTrace) {
    stderr.writeln('error: $error');
    if (Logger.level == LogLevel.debug) stderr.writeln(stackTrace);
    exitCode = exitFailure;
  }
}

Future<int> _run(ArgResults args) async {
  final Config config;
  try {
    config = Config.fromArgs(args);
  } on ArgumentError catch (error) {
    stderr.writeln('error: ${error.message}');
    return exitUsage;
  } on FormatException catch (error) {
    stderr.writeln('error: ${error.message}');
    return exitUsage;
  }

  Logger.configure(level: config.logLevel, colorEnabled: config.colorizeLogs);
  final log = rootLogger;

  await config.ensureDirectories();
  log.info('starting proxy_video', fields: config.describe());

  if (!config.servesLoopbackOnly) {
    log.warn(
      'listeners are reachable beyond loopback; the API has no authentication',
      fields: <String, Object?>{
        'bind': config.bindAddress,
        'originBind': config.originBindAddress,
      },
    );
  }

  OriginServer? originServer;
  OriginClient? originClient;
  Storage? storage;
  DiskCache? cache;
  AppServer? server;

  try {
    final mode =
        cliEnum(args, 'storage', <String>['auto', 'local', 'cos']) ?? 'auto';
    final wantsCos =
        mode == 'cos' ||
        (mode == 'auto' &&
            CosCredentials.tryFromEnvironment(Platform.environment) != null);

    if (wantsCos) {
      storage = CosStorage.tryFromEnvironment(Platform.environment, log: log);
      if (storage == null) {
        stderr.writeln(
          'error: --storage cos needs ${CosCredentials.requiredEnvironmentKeys.join(', ')}.',
        );
        return exitUsage;
      }
      log.info(
        'reading media from COS',
        fields: <String, Object?>{'credentials': storage.toString()},
      );
    } else {
      final origin = OriginServer(
        root: config.originDirectory,
        bindAddress: config.originBindAddress,
        port: config.originPort,
        throttleBytesPerSecond: config.originThrottleBytesPerSecond,
        log: log,
      );
      await origin.start();
      originServer = origin;

      storage = LocalDirStorage(
        root: config.originDirectory,
        originBaseUri: origin.baseUri,
        log: log,
      );
    }

    final upstream = HttpOriginClient(
      urlFor: storage.urlFor,
      connectTimeout: config.connectTimeout,
      requestTimeout: config.upstreamTimeout,
      log: log,
    );
    originClient = upstream;

    final diskCache = DiskCache(
      root: config.cacheDirectory,
      chunkSize: config.chunkSize,
      maxBytes: config.maxCacheBytes,
      origin: upstream,
      log: log,
      maxConcurrentUpstream: config.maxConcurrentUpstream,
      prefetchAhead: config.prefetchAhead,
    );
    cache = diskCache;

    final appServer = AppServer(
      config: config,
      storage: storage,
      cache: diskCache,
      proxy: MediaProxy(
        cache: diskCache,
        continueAfterDisconnect: config.continueAfterDisconnect,
        log: log,
      ),
      transcodes: TranscodeService(config: config, storage: storage, log: log),
      log: log,
    );
    server = appServer;

    // The cache is constructed before the app server starts, so any entry left
    // by a previous run is already on disk; kicking the budget once keeps a
    // stale oversized cache from surviving the restart.
    unawaited(diskCache.enforceBudget(force: true));

    await appServer.start();

    stdout
      ..writeln()
      ..writeln('proxy_video is ready')
      ..writeln('  library : ${appServer.baseUri}')
      ..writeln('  media   : ${appServer.baseUri}/media/<key>')
      ..writeln('  storage : ${storage.runtimeType}')
      ..writeln('  cache   : ${config.cacheDirPath}')
      ..writeln(
        '  chunks  : ${formatByteSize(config.chunkSize)} x '
        '${config.maxConcurrentUpstream} concurrent upstream',
      );
    if (originServer != null) {
      stdout.writeln('  origin  : ${originServer.baseUri}');
    }
    stdout.writeln('Press Ctrl+C to stop.');

    await _waitForShutdownSignal();
    log.info('shutting down');

    return exitSuccess;
  } on CliUsageException catch (error) {
    stderr.writeln('error: ${error.message}');
    return exitUsage;
  } finally {
    await server?.stop();
    await cache?.close();
    originClient?.close();
    await storage?.close();
    await originServer?.stop();
  }
}

/// Completes on the first Ctrl+C or termination signal.
///
/// Draining the servers in a `finally` is what makes a restart safe: metadata is
/// flushed and file handles are released rather than left to the OS.
Future<void> _waitForShutdownSignal() {
  final completer = Completer<void>();
  final subscriptions = <StreamSubscription<ProcessSignal>>[];

  void handle(ProcessSignal signal) {
    if (!completer.isCompleted) completer.complete();
  }

  // Windows cannot watch SIGTERM at all, and the failure arrives asynchronously
  // on the stream rather than from `watch()`, so it has to be filtered on both
  // sides: an unhandled error here would kill the server at startup.
  for (final signal in <ProcessSignal>[
    ProcessSignal.sigint,
    if (!Platform.isWindows) ProcessSignal.sigterm,
  ]) {
    try {
      subscriptions.add(
        signal.watch().listen(handle, onError: (Object error) {}),
      );
    } on Object {
      // A platform that refuses the signal simply keeps the default behaviour.
    }
  }

  return completer.future.whenComplete(() {
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel());
    }
  });
}

String _usage(ArgParser parser) =>
    '''
Serve published media through a Range-capable, disk-caching HTTP proxy.

Usage: dart run bin/server.dart [options]

${parser.usage}

Examples:
  dart run bin/server.dart
  dart run bin/server.dart --port 8080 --origin-port 8090
  dart run bin/server.dart --origin-throttle 1M --chunk-size 256K

Open the printed library URL to browse and play, and watch the cache fill up.''';
