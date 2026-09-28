import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:proxy_video/proxy_video.dart';
import 'package:test/test.dart';

import 'helpers/test_origin.dart';

Future<Uint8List> collect(Stream<List<int>> stream) async {
  final builder = BytesBuilder(copy: false);
  await for (final piece in stream) {
    builder.add(piece);
  }
  return builder.takeBytes();
}

void main() {
  late Directory temp;
  late Directory originRoot;
  late Uint8List payload;
  late OriginServer origin;
  late HttpOriginClient client;
  late HttpClient http;

  Uri objectUrl(String key) => origin.baseUri.replace(
    pathSegments: <String>['origin', ...key.split('/')],
  );

  Future<HttpClientResponse> send(
    String path, {
    String method = 'GET',
    String? range,
  }) async {
    final request = await http.openUrl(
      method,
      Uri.parse('${origin.baseUri}$path'),
    );
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    return request.close();
  }

  setUp(() async {
    Logger.level = LogLevel.error;
    temp = Directory.systemTemp.createTempSync('proxy_video_origin_test_');
    originRoot = Directory(p.join(temp.path, 'origin'));
    payload = makePayload(256 * 1024);

    final file = File(p.join(originRoot.path, 'clips', 'a.mp4'));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(payload);

    origin = OriginServer(root: originRoot, port: 0, log: Logger('test'));
    await origin.start();

    http = HttpClient();
    client = HttpOriginClient(urlFor: objectUrl, log: Logger('test'));
  });

  tearDown(() async {
    client.close();
    http.close(force: true);
    await origin.stop();
    Logger.reset();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  group('OriginServer wire behaviour', () {
    test('binds an ephemeral port when asked for one', () {
      expect(origin.isRunning, isTrue);
      expect(origin.boundPort, greaterThan(0));
    });

    test('serves a whole object with Accept-Ranges and an ETag', () async {
      final response = await send('/origin/clips/a.mp4');

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
      expect(response.headers.contentLength, payload.length);
      expect(response.headers.contentType?.mimeType, 'video/mp4');
      expect(response.headers.value(HttpHeaders.etagHeader), isNotNull);
      expect(response.headers.value(HttpHeaders.lastModifiedHeader), isNotNull);
      expect(await collect(response), payload);
    });

    test(
      'answers 206 with an exact Content-Range and Content-Length',
      () async {
        final response = await send(
          '/origin/clips/a.mp4',
          range: 'bytes=100-199',
        );

        expect(response.statusCode, HttpStatus.partialContent);
        expect(
          response.headers.value(HttpHeaders.contentRangeHeader),
          'bytes 100-199/${payload.length}',
        );
        expect(response.headers.contentLength, 100);
        expect(await collect(response), payload.sublist(100, 200));
      },
    );

    test('answers an open ended range with the tail of the object', () async {
      final from = payload.length - 10;
      final response = await send('/origin/clips/a.mp4', range: 'bytes=$from-');

      expect(response.statusCode, HttpStatus.partialContent);
      expect(
        response.headers.value(HttpHeaders.contentRangeHeader),
        'bytes $from-${payload.length - 1}/${payload.length}',
      );
      expect(await collect(response), payload.sublist(from));
    });

    test('answers a suffix range with the trailing bytes', () async {
      final response = await send('/origin/clips/a.mp4', range: 'bytes=-16');

      expect(response.statusCode, HttpStatus.partialContent);
      expect(await collect(response), payload.sublist(payload.length - 16));
    });

    test('answers 416 with an unsatisfied Content-Range', () async {
      final response = await send(
        '/origin/clips/a.mp4',
        range: 'bytes=999999-',
      );

      expect(response.statusCode, HttpStatus.requestedRangeNotSatisfiable);
      expect(
        response.headers.value(HttpHeaders.contentRangeHeader),
        'bytes */${payload.length}',
      );
      await response.drain<void>();
    });

    test('ignores a multi-range request and sends the whole object', () async {
      final response = await send(
        '/origin/clips/a.mp4',
        range: 'bytes=0-9,20-29',
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(await collect(response), payload);
    });

    test('HEAD reports the size without a body', () async {
      final response = await send('/origin/clips/a.mp4', method: 'HEAD');

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers.contentLength, payload.length);
      expect(await collect(response), isEmpty);
      expect(origin.headCount, 1);
    });

    test('404s for a missing object and for paths outside /origin', () async {
      final missing = await send('/origin/nope.mp4');
      expect(missing.statusCode, HttpStatus.notFound);
      await missing.drain<void>();

      final elsewhere = await send('/elsewhere/a.mp4');
      expect(elsewhere.statusCode, HttpStatus.notFound);
      await elsewhere.drain<void>();
    });

    test('refuses a key that tries to escape the origin root', () async {
      final response = await send('/origin/..%2F..%2Fpubspec.yaml');

      expect(
        response.statusCode,
        anyOf(HttpStatus.badRequest, HttpStatus.notFound),
      );
      await response.drain<void>();
    });

    test('rejects methods other than GET and HEAD', () async {
      final request = await http.postUrl(
        Uri.parse('${origin.baseUri}/origin/clips/a.mp4'),
      );
      final response = await request.close();

      expect(response.statusCode, HttpStatus.methodNotAllowed);
      expect(response.headers.value(HttpHeaders.allowHeader), 'GET, HEAD');
      await response.drain<void>();
    });

    test('counts only range requests as range requests', () async {
      await (await send('/origin/clips/a.mp4')).drain<void>();
      expect(origin.rangeRequestCount, 0);

      await (await send(
        '/origin/clips/a.mp4',
        range: 'bytes=0-9',
      )).drain<void>();
      expect(origin.rangeRequestCount, 1);

      await (await send(
        '/origin/clips/a.mp4',
        range: 'bytes=999999-',
      )).drain<void>();
      expect(origin.rangeRequestCount, 2);
    });
  });

  group('HttpOriginClient against a real origin', () {
    test('head() reports size, validator and range support', () async {
      final metadata = await client.head('clips/a.mp4');

      expect(metadata, isNotNull);
      expect(metadata!.totalSize, payload.length);
      expect(metadata.acceptsRanges, isTrue);
      expect(metadata.etag, isNotNull);
      expect(metadata.lastModified, isNotNull);
      expect(metadata.contentType, startsWith('video/mp4'));
    });

    test('head() returns null for a missing object', () async {
      expect(await client.head('nope.mp4'), isNull);
    });

    test('openRange streams exactly the requested window', () async {
      expect(
        await collect(client.openRange('clips/a.mp4', 1000, 1999)),
        payload.sublist(1000, 2000),
      );
    });

    test('openRange reads a window that spans several body chunks', () async {
      final from = 3 * 64 * 1024 - 100;
      final to = 3 * 64 * 1024 + 100;

      expect(
        await collect(client.openRange('clips/a.mp4', from, to)),
        payload.sublist(from, to + 1),
      );
    });

    test('openRange reads the whole object', () async {
      expect(
        await collect(client.openRange('clips/a.mp4', 0, payload.length - 1)),
        payload,
      );
    });

    test('openRange reports a missing object', () async {
      await expectLater(
        collect(client.openRange('nope.mp4', 0, 15)),
        throwsA(isA<OriginNotFoundException>()),
      );
    });

    test('openRange reports an unsatisfiable window', () async {
      await expectLater(
        collect(
          client.openRange('clips/a.mp4', payload.length, payload.length + 15),
        ),
        throwsA(isA<OriginRequestException>()),
      );
    });
  });

  group('HttpOriginClient against an origin that ignores Range', () {
    late HttpServer naive;
    late HttpOriginClient naiveClient;

    setUp(() async {
      naive = await HttpServer.bind('127.0.0.1', 0);

      unawaited(() async {
        await for (final request in naive) {
          // Deliberately ignore the Range header, the way a plain static file
          // server would.
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.set(HttpHeaders.acceptRangesHeader, 'none')
            ..headers.set(HttpHeaders.contentLengthHeader, '${payload.length}');

          if (request.method != 'HEAD') {
            for (var offset = 0; offset < payload.length; offset += 8192) {
              request.response.add(
                payload.sublist(
                  offset,
                  math.min(offset + 8192, payload.length),
                ),
              );
            }
          }
          await request.response.close();
        }
      }());

      naiveClient = HttpOriginClient(
        urlFor: (String key) =>
            Uri.parse('http://127.0.0.1:${naive.port}/objects/$key'),
        log: Logger('test'),
      );
    });

    tearDown(() async {
      naiveClient.close();
      await naive.close(force: true);
    });

    test('trims the leading bytes so callers still get their window', () async {
      expect(
        await collect(naiveClient.openRange('clips/a.mp4', 1000, 1999)),
        payload.sublist(1000, 2000),
      );
    });

    test('trims a window that starts inside the first body chunk', () async {
      expect(
        await collect(naiveClient.openRange('clips/a.mp4', 10, 20)),
        payload.sublist(10, 21),
      );
    });

    test(
      'reports truncation when the requested window is past the end',
      () async {
        await expectLater(
          collect(
            naiveClient.openRange(
              'clips/a.mp4',
              payload.length + 100,
              payload.length + 200,
            ),
          ),
          throwsA(isA<OriginTruncatedException>()),
        );
      },
    );
  });
}
