import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// End-to-end smoke test for the two CLI entry points.
///
/// `dart test` covers the library in process, but nothing there proves that
/// `bin/pipeline.dart` and `bin/server.dart` actually wire the pieces together
/// and talk to each other. This script drives both as real child processes in a
/// scratch data directory, checks the wire-level behaviour a browser depends on,
/// and exits non-zero on the first disappointment.
///
/// Run with: `dart run tool/e2e_smoke.dart`
Future<void> main(List<String> arguments) async {
  final projectRoot = Directory.current.path;
  final dart = Platform.resolvedExecutable;
  final temp = Directory.systemTemp.createTempSync('proxy_video_e2e_');
  final report = _Report();

  stdout.writeln('proxy_video end-to-end smoke test');
  stdout.writeln('  scratch : ${temp.path}');
  stdout.writeln('');

  Process? server;

  try {
    stdout.writeln('1. transcode and publish a demo clip');
    final pipeline = await Process.start(dart, <String>[
      'run',
      'bin/pipeline.dart',
      '--data-dir',
      temp.path,
      '--demo',
      '--demo-duration',
      '3',
      '--key',
      'smoke/demo.mp4',
      '--log-level',
      'warn',
    ], workingDirectory: projectRoot);

    final pipelineOut = StringBuffer();
    final pipelineErr = StringBuffer();
    final drainPipeline = Future.wait<void>(<Future<void>>[
      pipeline.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .forEach(pipelineOut.write),
      pipeline.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .forEach(pipelineErr.write),
    ]);
    final pipelineExit = await pipeline.exitCode;
    await drainPipeline;

    report.check(
      pipelineExit == 0,
      'pipeline exits cleanly',
      'exit $pipelineExit ${pipelineErr.toString().trim()}',
    );

    final published = File(p.join(temp.path, 'origin', 'smoke', 'demo.mp4'));
    report.check(published.existsSync(), 'the clip landed in the bucket');
    if (!published.existsSync()) {
      report.finish();
      return;
    }

    final bytes = await published.readAsBytes();
    report.check(bytes.isNotEmpty, 'the clip has content');
    report.check(
      _moovPrecedesMdat(bytes),
      'the index is in front of the media',
    );

    stdout.writeln('');
    stdout.writeln('2. start the proxy server');
    const serverPort = 0;
    server = await Process.start(dart, <String>[
      'run',
      'bin/server.dart',
      '--data-dir',
      temp.path,
      '--port',
      '$serverPort',
      '--origin-port',
      '$serverPort',
      '--chunk-size',
      '64K',
      '--log-level',
      'warn',
    ], workingDirectory: projectRoot);

    final serverLog = StringBuffer();
    final libraryUrl = await _awaitLibraryUrl(
      server,
      into: serverLog,
      timeout: const Duration(seconds: 90),
    );
    report.check(
      libraryUrl != null,
      'the server announced its URL',
      (serverLog.length > 4000)
          ? '${serverLog.toString().substring(0, 4000)}...'
          : serverLog.toString(),
    );
    if (libraryUrl == null) {
      report.finish();
      return;
    }

    final client = HttpClient();
    try {
      stdout.writeln('');
      stdout.writeln('3. exercise the HTTP surface at $libraryUrl');

      final health = await _request(client, libraryUrl, '/healthz');
      report.check(health.status == 200, 'GET /healthz answers 200');
      report.check(
        health.text.contains('"status":"ok"'),
        '/healthz reports ok',
        health.text,
      );

      final library = await _request(client, libraryUrl, '/');
      report.check(library.status == 200, 'GET / serves the library');
      report.check(
        library.text.contains('Media library'),
        'the library page renders',
      );

      final player = await _request(client, libraryUrl, '/play/smoke/demo.mp4');
      report.check(player.status == 200, 'GET /play/<key> serves the player');
      report.check(
        player.text.contains('Cache diagnostics') &&
            player.text.contains('smoke/demo.mp4'),
        'the player page embeds the key and the diagnostics panel',
      );

      final media = await _request(client, libraryUrl, '/media/smoke/demo.mp4');
      report.check(media.status == 200, 'a plain GET returns 200');
      report.check(
        media.headers['accept-ranges'] == 'bytes',
        'the response advertises Accept-Ranges',
        media.headers['accept-ranges'],
      );
      report.check(
        media.body.length == bytes.length,
        'the whole object is delivered',
        '${media.body.length} of ${bytes.length} bytes',
      );

      final head = await _request(
        client,
        libraryUrl,
        '/media/smoke/demo.mp4',
        method: 'HEAD',
      );
      report.check(head.status == 200, 'HEAD answers 200');
      report.check(
        head.headers['content-length'] == '${bytes.length}',
        'HEAD reports the object size without a body',
        head.headers['content-length'],
      );
      report.check(head.body.isEmpty, 'HEAD carries no body');

      final first = await _request(
        client,
        libraryUrl,
        '/media/smoke/demo.mp4',
        range: 'bytes=0-99',
      );
      report.check(first.status == 206, 'a range request answers 206');
      report.check(
        first.headers['content-range'] == 'bytes 0-99/${bytes.length}',
        'Content-Range describes the slice',
        first.headers['content-range'],
      );
      report.check(
        first.headers['content-length'] == '100',
        'Content-Length is the slice length, not the object length',
        first.headers['content-length'],
      );
      report.check(
        _sameBytes(first.body, bytes.sublist(0, 100)),
        'the first 100 bytes match the object',
      );

      final middle = 4096;
      final seek = await _request(
        client,
        libraryUrl,
        '/media/smoke/demo.mp4',
        range: 'bytes=$middle-${middle + 99}',
      );
      report.check(
        seek.status == 206 &&
            _sameBytes(seek.body, bytes.sublist(middle, middle + 100)),
        'seeking into the middle returns the right bytes',
      );

      final beyond = await _request(
        client,
        libraryUrl,
        '/media/smoke/demo.mp4',
        range: 'bytes=${bytes.length + 10}-',
      );
      report.check(beyond.status == 416, 'an unsatisfiable range answers 416');
      report.check(
        beyond.headers['content-range'] == 'bytes */${bytes.length}',
        '416 names the real object size',
        beyond.headers['content-range'],
      );

      stdout.writeln('');
      stdout.writeln('4. cache behaviour');
      final statsAfterFirst = await _json(
        client,
        libraryUrl,
        '/api/stats',
        query: <String, String>{'key': 'smoke/demo.mp4'},
      );
      final requestsAfterFirst = statsAfterFirst['upstreamRequests'];
      final hitsBefore = statsAfterFirst['cacheHits'];
      report.check(
        requestsAfterFirst is int && requestsAfterFirst > 0,
        'the bytes came from the origin',
        '$requestsAfterFirst',
      );
      report.check(
        (statsAfterFirst['readyChunks'] as int? ?? 0) > 0,
        'chunks are on disk',
      );

      await _request(
        client,
        libraryUrl,
        '/media/smoke/demo.mp4',
        range: 'bytes=0-99',
      );
      final statsAfterRepeat = await _json(
        client,
        libraryUrl,
        '/api/stats',
        query: <String, String>{'key': 'smoke/demo.mp4'},
      );
      report.check(
        statsAfterRepeat['upstreamRequests'] == requestsAfterFirst,
        'replaying the same window does not touch the origin again',
        '${statsAfterRepeat['upstreamRequests']} vs $requestsAfterFirst',
      );
      report.check(
        statsAfterRepeat['cacheHits'] == (hitsBefore! as int) + 1,
        'the repeat is recorded as exactly one more cache hit',
        '${statsAfterRepeat['cacheHits']} versus $hitsBefore before',
      );

      final cached = Directory(p.join(temp.path, 'cache'));
      final cacheFiles = cached.existsSync()
          ? cached.listSync(recursive: true).whereType<File>().toList()
          : <File>[];
      report.check(
        cacheFiles.any((File file) => file.path.endsWith('.bin')) &&
            cacheFiles.any((File file) => file.path.endsWith('.meta.json')),
        'the cache holds a backing file and its metadata',
      );

      final jobs = await _request(client, libraryUrl, '/api/jobs');
      report.check(jobs.status == 200, 'GET /api/jobs answers 200');

      final missing = await _request(client, libraryUrl, '/api/nope');
      report.check(missing.status == 404, 'an unknown route answers 404');
      final wrongVerb = await _request(
        client,
        libraryUrl,
        '/api/media',
        method: 'POST',
      );
      report.check(wrongVerb.status == 405, 'a wrong verb answers 405');
    } finally {
      client.close(force: true);
    }
  } finally {
    server?.kill(ProcessSignal.sigkill);
    if (server != null) await server.exitCode;
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  }

  report.finish();
}

/// Reads the server banner and returns the library URL it prints.
Future<Uri?> _awaitLibraryUrl(
  Process process, {
  required StringBuffer into,
  required Duration timeout,
}) async {
  final completer = Completer<Uri?>();
  const marker = 'library : ';

  final subscription = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .listen(
        (String line) {
          into.writeln(line);
          if (completer.isCompleted) return;
          final index = line.indexOf(marker);
          if (index >= 0) {
            completer.complete(
              Uri.parse(line.substring(index + marker.length).trim()),
            );
          }
        },
        onError: (Object error) {
          if (!completer.isCompleted) completer.complete(null);
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete(null);
        },
      );

  process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .listen(into.writeln, onError: (Object error) {});

  try {
    return await completer.future.timeout(timeout, onTimeout: () => null);
  } finally {
    unawaited(subscription.cancel());
  }
}

class _Response {
  _Response({
    required this.status,
    required this.headers,
    required this.body,
    required this.text,
  });

  final int status;
  final Map<String, String> headers;
  final Uint8List body;
  final String text;
}

Future<_Response> _request(
  HttpClient client,
  Uri base,
  String path, {
  String method = 'GET',
  String? range,
  Map<String, String>? query,
}) async {
  final target = base.replace(
    path: path,
    queryParameters: (query == null || query.isEmpty) ? null : query,
  );
  final request = await client.openUrl(method, target);
  if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);

  final response = await request.close();
  final builder = BytesBuilder(copy: false);
  await for (final piece in response) {
    builder.add(piece);
  }

  final headers = <String, String>{};
  response.headers.forEach((String name, List<String> values) {
    headers[name.toLowerCase()] = values.join(', ');
  });

  final body = builder.takeBytes();
  return _Response(
    status: response.statusCode,
    headers: headers,
    body: body,
    text: utf8.decode(body, allowMalformed: true),
  );
}

Future<Map<String, Object?>> _json(
  HttpClient client,
  Uri base,
  String path, {
  Map<String, String>? query,
}) async {
  final response = await _request(client, base, path, query: query);
  if (response.status != 200) {
    throw StateError('GET $path answered ${response.status}');
  }
  return jsonDecode(response.text) as Map<String, Object?>;
}

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

/// Whether the MP4 index sits in front of the media payload.
bool _moovPrecedesMdat(Uint8List bytes) {
  final head = String.fromCharCodes(bytes.take(256 * 1024));
  final moov = head.indexOf('moov');
  final mdat = head.indexOf('mdat');
  return moov >= 0 && mdat >= 0 && moov < mdat;
}

class _Report {
  final List<String> failures = <String>[];
  int checks = 0;

  void check(bool condition, String description, [String? detail]) {
    checks++;
    if (condition) {
      stdout.writeln('  ok   $description');
      return;
    }
    final suffix = (detail == null || detail.isEmpty) ? '' : ' -> $detail';
    stdout.writeln('  FAIL $description$suffix');
    failures.add(description);
  }

  void finish() {
    stdout.writeln('');
    if (failures.isEmpty) {
      stdout.writeln('$checks checks passed.');
      exitCode = 0;
      return;
    }

    stdout.writeln('${failures.length} of $checks checks FAILED:');
    for (final failure in failures) {
      stdout.writeln('  - $failure');
    }
    exitCode = 1;
  }
}
