import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:proxy_video/proxy_video.dart';
import 'package:test/test.dart';

import 'helpers/test_origin.dart';

/// Drains a response body into a single buffer.
Future<Uint8List> collect(HttpClientResponse response) async {
  final builder = BytesBuilder(copy: false);
  await for (final piece in response) {
    builder.add(piece);
  }
  return builder.takeBytes();
}

void main() {
  const chunkSize = 32 * 1024;

  late Directory temp;
  late Uint8List payload;
  late OriginServer originServer;
  late HttpOriginClient upstream;
  late LocalDirStorage storage;
  late DiskCache cache;
  late AppServer server;
  late HttpClient http;

  setUp(() async {
    Logger.level = LogLevel.error;
    temp = Directory.systemTemp.createTempSync('proxy_video_server_test_');
    payload = makePayload(128 * 1024);

    final originRoot = Directory(p.join(temp.path, 'origin'));
    final file = File(p.join(originRoot.path, 'clips', 'a.mp4'));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(payload);

    originServer = OriginServer(root: originRoot, port: 0, log: Logger('test'));
    await originServer.start();

    storage = LocalDirStorage(
      root: originRoot,
      originBaseUri: originServer.baseUri,
      log: Logger('test'),
    );
    upstream = HttpOriginClient(urlFor: storage.urlFor, log: Logger('test'));

    final config = Config.forTesting(
      projectRoot: Directory.current.path,
      dataDirPath: p.join(temp.path, 'data'),
      // Keep the config truthful about where the origin actually listens; the
      // health endpoint reports it back.
      originPort: originServer.boundPort,
      chunkSize: chunkSize,
    );

    cache = DiskCache(
      root: Directory(p.join(temp.path, 'cache')),
      chunkSize: chunkSize,
      maxBytes: 0,
      origin: upstream,
      log: Logger('test'),
    );

    server = AppServer(
      config: config,
      storage: storage,
      cache: cache,
      proxy: MediaProxy(cache: cache, log: Logger('test')),
      transcodes: TranscodeService(
        config: config,
        storage: storage,
        log: Logger('test'),
      ),
      log: Logger('test'),
    );
    await server.start();

    http = HttpClient();
  });

  tearDown(() async {
    http.close(force: true);
    await server.stop();
    await cache.close();
    upstream.close();
    await originServer.stop();
    Logger.reset();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Uri url(String path) => Uri.parse('${server.baseUri}$path');

  Future<HttpClientResponse> send(
    String path, {
    String method = 'GET',
    String? range,
  }) async {
    final request = await http.openUrl(method, url(path));
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    return request.close();
  }

  Future<Map<String, Object?>> sendJson(
    String path, {
    String method = 'GET',
    Object? body,
  }) async {
    final request = await http.openUrl(method, url(path));
    if (body != null) {
      final encoded = utf8.encode(jsonEncode(body));
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set(HttpHeaders.contentLengthHeader, '${encoded.length}');
      request.add(encoded);
    }

    final response = await request.close();
    final text = await utf8.decodeStream(response);
    expect(
      response.statusCode,
      lessThan(400),
      reason: '$method $path answered ${response.statusCode}: $text',
    );
    return jsonDecode(text) as Map<String, Object?>;
  }

  Future<Map<String, Object?>> waitForJob(String id) async {
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (true) {
      final job = await sendJson('/api/jobs/$id');
      if (job['status'] == 'done') return job;
      if (job['status'] == 'failed') {
        fail('job failed: ${job['message']}');
      }
      if (DateTime.now().isAfter(deadline)) fail('job did not finish in time');
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
  }

  group('health and discovery', () {
    test('reports what it is serving', () async {
      final health = await sendJson('/healthz');

      expect(health['status'], 'ok');
      expect(health['storage'], contains('LocalDirStorage'));
      expect(health['origin'], originServer.baseUri.toString());
    });

    test('lists published objects with play and stream URLs', () async {
      final payloadJson = await sendJson('/api/media');
      final objects = payloadJson['objects']! as List<Object?>;
      final first = objects.single! as Map<String, Object?>;

      expect(first['key'], 'clips/a.mp4');
      expect(first['size'], payload.length);
      expect(first['playUrl'], '/play/clips/a.mp4');
      expect(first['streamUrl'], '/media/clips/a.mp4');
      expect(first['cache'], isNull, reason: 'nothing has been fetched yet');
    });

    test('answers 204 for the favicon', () async {
      final response = await send('/favicon.ico');
      expect(response.statusCode, HttpStatus.noContent);
      await response.drain<void>();
    });
  });

  group('pages', () {
    test('serves the media library', () async {
      final response = await send('/');
      final html = await utf8.decodeStream(response);

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers.contentType?.mimeType, 'text/html');
      expect(html, contains('Media library'));
      expect(html, contains('/api/media'));
    });

    test('serves a player page that embeds the key', () async {
      final response = await send('/play/clips/a.mp4');
      final html = await utf8.decodeStream(response);

      expect(response.statusCode, HttpStatus.ok);
      expect(html, contains('PROXY_VIDEO'));
      expect(html, contains('clips/a.mp4'));
      expect(html, contains('/media/'));
      expect(html, contains('Cache diagnostics'));
    });

    test('refuses to render a page for an unusable key', () async {
      final response = await send('/play/..%2F..%2Fpubspec.yaml');

      expect(response.statusCode, HttpStatus.badRequest);
      await response.drain<void>();
    });
  });

  group('proxy routes', () {
    test('streams a range and records the cache progress', () async {
      final response = await send('/media/clips/a.mp4', range: 'bytes=0-999');

      expect(response.statusCode, HttpStatus.partialContent);
      expect(
        response.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 0-999/${payload.length}',
      );
      expect(await collect(response), payload.sublist(0, 1000));

      final entry = await sendJson('/api/stats?key=clips%2Fa.mp4');
      expect(entry['known'], isTrue);
      expect(entry['readyChunks'], 1);
      expect(entry['upstreamRequests'], 1);
    });

    test('answers 404 for a key the origin does not have', () async {
      final response = await send('/media/clips/missing.mp4');

      expect(response.statusCode, HttpStatus.notFound);
      await response.drain<void>();
    });

    test('asks for the key when the path has none', () async {
      final response = await send('/media');

      expect(response.statusCode, HttpStatus.badRequest);
      await response.drain<void>();
    });
  });

  group('routing errors', () {
    test('answers 404 for an unknown path', () async {
      final response = await send('/nope');

      expect(response.statusCode, HttpStatus.notFound);
      await response.drain<void>();
    });

    test('answers 405 and names the allowed methods', () async {
      final response = await send('/api/media', method: 'POST');

      expect(response.statusCode, HttpStatus.methodNotAllowed);
      expect(
        response.headers.value(HttpHeaders.allowHeader),
        allOf(contains('GET'), contains('HEAD')),
      );
      await response.drain<void>();
    });
  });

  group('cache control', () {
    test('reports unknown keys as not known', () async {
      final stats = await sendJson('/api/stats?key=clips%2Fnever-fetched.mp4');
      expect(stats['known'], isFalse);
    });

    test('drops a single key on request', () async {
      final streamed = await send('/media/clips/a.mp4', range: 'bytes=0-999');
      await streamed.drain<void>();
      expect(
        (await sendJson('/api/stats?key=clips%2Fa.mp4'))['readyChunks'],
        1,
      );

      final cleared = await sendJson(
        '/api/cache',
        method: 'POST',
        body: <String, Object?>{'key': 'clips/a.mp4'},
      );

      expect(cleared['cleared'], 'clips/a.mp4');
      expect(cleared['entries'], 0);
      expect(cleared['totalBytes'], 0);

      // The object itself is untouched; only the local copy is gone.
      final response = await send('/media/clips/a.mp4', range: 'bytes=0-9');
      expect(response.statusCode, HttpStatus.partialContent);
      await response.drain<void>();
    });

    test('drops everything when no key is given', () async {
      final streamed = await send('/media/clips/a.mp4', range: 'bytes=0-999');
      await streamed.drain<void>();

      final cleared = await sendJson('/api/cache', method: 'POST');

      expect(cleared['cleared'], '*');
      expect(cleared['totalBytes'], 0);
    });

    test('rejects an unusable key', () async {
      final request = await http.postUrl(url('/api/cache'));
      final body = utf8.encode(
        jsonEncode(<String, Object?>{'key': '../../escape'}),
      );
      request.headers.set(HttpHeaders.contentLengthHeader, '${body.length}');
      request.add(body);

      final response = await request.close();
      expect(response.statusCode, HttpStatus.badRequest);
      await response.drain<void>();
    });
  });

  group('transcode API', () {
    test('runs a demo transcode end to end and publishes it', () async {
      final submitted = await sendJson(
        '/api/transcode',
        method: 'POST',
        body: <String, Object?>{
          'demo': true,
          'key': 'clips/demo.mp4',
          'duration': 2,
          'crf': 30,
        },
      );

      expect(submitted['key'], 'clips/demo.mp4');
      final job = await waitForJob(submitted['id']! as String);

      expect(job['status'], 'done');
      expect(job['phase'], 'done');
      expect(job['outputBytes'], greaterThan(0));

      // It must show up in the library, and the scratch file must be gone.
      final library = await sendJson('/api/media');
      final keys = (library['objects']! as List<Object?>)
          .map((Object? object) => (object! as Map<String, Object?>)['key'])
          .toList();
      expect(keys, contains('clips/demo.mp4'));

      // And it must be playable through the proxy, with the index in front so a
      // player can seek without downloading the whole file first.
      final response = await send(
        '/media/clips/demo.mp4',
        range: 'bytes=0-65535',
      );
      expect(response.statusCode, HttpStatus.partialContent);

      final head = await collect(response);
      final text = String.fromCharCodes(head);
      expect(text.indexOf('moov'), isNonNegative);
      expect(text.indexOf('moov'), lessThan(text.indexOf('mdat')));
    });

    test('rejects a request with neither input nor demo', () async {
      final request = await http.postUrl(url('/api/transcode'));
      final body = utf8.encode(jsonEncode(<String, Object?>{'key': 'a.mp4'}));
      request.headers.set(HttpHeaders.contentLengthHeader, '${body.length}');
      request.add(body);

      final response = await request.close();
      final payload =
          jsonDecode(await utf8.decodeStream(response)) as Map<String, Object?>;

      expect(response.statusCode, HttpStatus.badRequest);
      expect(payload['error'], contains('input'));
    });

    test('rejects an input path that does not exist', () async {
      final request = await http.postUrl(url('/api/transcode'));
      final body = utf8.encode(
        jsonEncode(<String, Object?>{'input': p.join(temp.path, 'nope.mov')}),
      );
      request.headers.set(HttpHeaders.contentLengthHeader, '${body.length}');
      request.add(body);

      final response = await request.close();
      expect(response.statusCode, HttpStatus.badRequest);
      await response.drain<void>();
    });

    test('rejects an unusable destination key', () async {
      final request = await http.postUrl(url('/api/transcode'));
      final body = utf8.encode(
        jsonEncode(<String, Object?>{'demo': true, 'key': '../escape.mp4'}),
      );
      request.headers.set(HttpHeaders.contentLengthHeader, '${body.length}');
      request.add(body);

      final response = await request.close();
      expect(response.statusCode, HttpStatus.badRequest);
      await response.drain<void>();
    });

    test('answers 404 for an unknown job', () async {
      final response = await send('/api/jobs/job-9999');

      expect(response.statusCode, HttpStatus.notFound);
      await response.drain<void>();
    });

    test('lists jobs with the queue depth', () async {
      final payload = await sendJson('/api/jobs');

      expect(payload['jobs'], isA<List<Object?>>());
      expect(payload['queued'], isA<int>());
      expect(payload['busy'], isA<bool>());
    });
  });
}
