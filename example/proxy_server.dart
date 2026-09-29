import 'dart:async';
import 'dart:io';

import 'package:proxy_video/proxy_video.dart';

/// A minimal media server built on [VideoProxy].
///
/// ```sh
/// dart run example/proxy_server.dart https://cdn.example.com ./cache 8080
/// ```
///
/// It serves everything under `/media/<key>`, where `<key>` is appended to the
/// configured origin base URL. Point a browser or `curl` at it:
///
/// ```sh
/// curl -r 0-1023 http://127.0.0.1:8080/media/clips/movie.mp4
/// ```
Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln(
      'usage: dart run example/proxy_server.dart '
      '<originBaseUrl> <cacheDir> [port]',
    );
    exitCode = 64;
    return;
  }

  final config = Config(
    originBaseUrl: Uri.parse(args[0]),
    cacheDirPath: args[1],
    // A smaller chunk makes progressive playback easier to see; the default is
    // 1 MiB, which trades a little latency for fewer upstream requests.
    chunkSize: 256 * 1024,
  );

  final log = rootLogger;

  final proxy = VideoProxy(config, log: log);
  final port = args.length > 2 ? int.parse(args[2]) : 8080;
  final server = await HttpServer.bind('127.0.0.1', port);

  log.info(
    'serving media',
    fields: <String, Object?>{
      'origin': config.originBaseUrl.toString(),
      'cacheDir': config.cacheDirPath,
      'url': 'http://127.0.0.1:${server.port}/media/<key>',
    },
  );

  // Shutting down cleanly matters: `close()` flushes cache metadata, so a
  // restart never finds a half-written chunk.
  StreamSubscription<ProcessSignal>? signal;
  signal = ProcessSignal.sigint.watch().listen((ProcessSignal _) async {
    log.info('shutting down');
    await server.close(force: true);
    await proxy.close();
    await signal?.cancel();
    exit(0);
  });

  await for (final request in server) {
    unawaited(_serve(request, proxy, log));
  }

  await proxy.close();
}

Future<void> _serve(HttpRequest request, VideoProxy proxy, Logger log) async {
  final segments = request.uri.pathSegments;
  if (segments.length < 2 || segments.first != 'media') {
    request.response
      ..statusCode = HttpStatus.notFound
      ..write('try /media/<key>');
    await request.response.close();
    return;
  }

  try {
    await proxy.serve(request, segments.skip(1).join('/'));
  } on Object catch (error, stackTrace) {
    // `serve` answers its own upstream failures; reaching here means something
    // unexpected, and the status line may already be on the wire.
    log.warn(
      'request failed',
      fields: <String, Object?>{'path': request.uri.path, 'error': error},
      stackTrace: Logger.level == LogLevel.debug ? stackTrace : null,
    );
    try {
      await request.response.close();
    } on Object {
      // Already streaming; there is nothing left to close politely.
    }
  }
}
