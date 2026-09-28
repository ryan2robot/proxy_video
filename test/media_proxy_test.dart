import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:proxy_video/proxy_video.dart';
import 'package:test/test.dart';

import 'helpers/test_origin.dart';

const int _chunkSize = 64 * 1024;
const int _payloadSize = 256 * 1024;
const String _key = 'clips/a.mp4';

/// A running proxy stack: origin client, cache, proxy and the HTTP server a
/// browser would actually talk to.
class Rig {
  Rig({
    required this.origin,
    required this.cache,
    required this.proxy,
    required this.server,
    required this.client,
  });

  final OriginClient origin;
  final DiskCache cache;
  final MediaProxy proxy;
  final HttpServer server;
  final HttpClient client;

  Uri url(String key) =>
      Uri.parse('http://127.0.0.1:${server.port}/media/$key');

  Future<void> dispose() async {
    client.close(force: true);
    await server.close(force: true);
    await proxy.whenIdle();
    await cache.close();
    origin.close();
  }
}

Future<Rig> startRig({
  required Directory cacheRoot,
  required OriginClient origin,
  int chunkSize = _chunkSize,
  bool continueAfterDisconnect = true,
}) async {
  final logger = Logger('test');
  final cache = DiskCache(
    root: cacheRoot,
    chunkSize: chunkSize,
    maxBytes: 0,
    origin: origin,
    log: logger,
  );
  final proxy = MediaProxy(
    cache: cache,
    continueAfterDisconnect: continueAfterDisconnect,
    log: logger,
  );

  final server = await HttpServer.bind('127.0.0.1', 0);
  unawaited(() async {
    await for (final request in server) {
      final segments = request.uri.pathSegments;
      if (segments.length >= 2 && segments.first == 'media') {
        await proxy.serve(request, segments.skip(1).join('/'));
      } else {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('nothing here');
        await request.response.close();
      }
    }
  }());

  return Rig(
    origin: origin,
    cache: cache,
    proxy: proxy,
    server: server,
    client: HttpClient(),
  );
}

/// Sends a request and returns the response with its headers, body unread.
Future<HttpClientResponse> open(
  Rig rig,
  String key, {
  String method = 'GET',
  String? range,
}) async {
  final request = await rig.client.openUrl(method, rig.url(key));
  if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
  return request.close();
}

Future<Uint8List> drain(HttpClientResponse response) async {
  final builder = BytesBuilder(copy: false);
  await for (final piece in response) {
    builder.add(piece);
  }
  return builder.takeBytes();
}

/// Polls [predicate] until it holds, so tests never depend on a fixed sleep.
Future<void> waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 10),
  String description = 'condition',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('timed out waiting for $description');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late Directory temp;
  late Directory originRoot;
  late Uint8List payload;
  late OriginServer originServer;
  late Rig rig;

  Uri Function(String) originUrlFor(OriginServer server) =>
      (String key) => server.baseUri.replace(
        pathSegments: <String>['origin', ...key.split('/')],
      );

  Future<Rig> startSlowRig(String folder, int bytesPerSecond) async {
    final throttled = OriginServer(
      root: originRoot,
      port: 0,
      throttleBytesPerSecond: bytesPerSecond,
      log: Logger('test'),
    );
    await throttled.start();
    addTearDown(throttled.stop);

    final slow = await startRig(
      cacheRoot: Directory(p.join(temp.path, folder)),
      origin: HttpOriginClient(
        urlFor: originUrlFor(throttled),
        log: Logger('test'),
      ),
    );
    addTearDown(slow.dispose);
    return slow;
  }

  setUp(() async {
    Logger.level = LogLevel.error;
    temp = Directory.systemTemp.createTempSync('proxy_video_proxy_test_');
    payload = makePayload(_payloadSize);

    originRoot = Directory(p.join(temp.path, 'origin'));
    final file = File(p.join(originRoot.path, 'clips', 'a.mp4'));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(payload);

    originServer = OriginServer(root: originRoot, port: 0, log: Logger('test'));
    await originServer.start();

    rig = await startRig(
      cacheRoot: Directory(p.join(temp.path, 'cache')),
      origin: HttpOriginClient(
        urlFor: originUrlFor(originServer),
        log: Logger('test'),
      ),
    );
  });

  tearDown(() async {
    await rig.dispose();
    await originServer.stop();
    Logger.reset();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  group('range semantics', () {
    test('serves the whole object as 200 with Accept-Ranges', () async {
      final response = await open(rig, _key);

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
      expect(response.headers.contentLength, _payloadSize);
      expect(response.headers.contentType?.mimeType, 'video/mp4');
      expect(await drain(response), payload);
    });

    test('answers bytes=0- with a full length 206', () async {
      final response = await open(rig, _key, range: 'bytes=0-');

      expect(response.statusCode, HttpStatus.partialContent);
      expect(
        response.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 0-${_payloadSize - 1}/$_payloadSize',
      );
      expect(response.headers.contentLength, _payloadSize);
      expect(await drain(response), payload);
    });

    test('answers bytes=s-e with an exact slice and length', () async {
      final response = await open(rig, _key, range: 'bytes=1000-1999');

      expect(response.statusCode, HttpStatus.partialContent);
      expect(
        response.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 1000-1999/$_payloadSize',
      );
      expect(response.headers.contentLength, 1000);
      expect(await drain(response), payload.sublist(1000, 2000));
    });

    test('answers a suffix range with the trailing bytes', () async {
      final response = await open(rig, _key, range: 'bytes=-16');

      expect(response.statusCode, HttpStatus.partialContent);
      expect(
        response.headers.value(HttpHeaders.contentRangeHeader),
        'bytes ${_payloadSize - 16}-${_payloadSize - 1}/$_payloadSize',
      );
      expect(await drain(response), payload.sublist(_payloadSize - 16));
    });

    test('answers 416 with an unsatisfied Content-Range', () async {
      final response = await open(rig, _key, range: 'bytes=99999999-');

      expect(response.statusCode, HttpStatus.requestedRangeNotSatisfiable);
      expect(
        response.headers.value(HttpHeaders.contentRangeHeader),
        'bytes */$_payloadSize',
      );
      await drain(response);
    });

    test('downgrades a multi-range request to a full 200', () async {
      final response = await open(rig, _key, range: 'bytes=0-9,20-29');

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers.contentLength, _payloadSize);
      expect(await drain(response), payload);
    });

    test('answers HEAD with the metadata and no body', () async {
      final response = await open(rig, _key, method: 'HEAD');

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
      expect(response.headers.contentLength, _payloadSize);
      expect(response.headers.value(HttpHeaders.etagHeader), isNotNull);
      expect(await drain(response), isEmpty);
    });

    test('answers HEAD for a range with a 206 and no body', () async {
      final response = await open(
        rig,
        _key,
        method: 'HEAD',
        range: 'bytes=0-99',
      );

      expect(response.statusCode, HttpStatus.partialContent);
      expect(response.headers.contentLength, 100);
      expect(await drain(response), isEmpty);
    });

    test('rejects methods other than GET and HEAD', () async {
      final request = await rig.client.postUrl(rig.url(_key));
      final response = await request.close();

      expect(response.statusCode, HttpStatus.methodNotAllowed);
      expect(response.headers.value(HttpHeaders.allowHeader), 'GET, HEAD');
      await drain(response);
    });

    test('answers 404 when the origin does not have the object', () async {
      final response = await open(rig, 'clips/missing.mp4');

      expect(response.statusCode, HttpStatus.notFound);
      await drain(response);
      expect(originServer.rangeRequestCount, 0);
    });

    test('refuses a key that tries to escape the cache', () async {
      final response = await open(rig, '..%2F..%2Fpubspec.yaml');

      expect(response.statusCode, HttpStatus.badRequest);
      await drain(response);
    });
  });

  group('caching', () {
    test('a repeat request is served without touching the origin', () async {
      final first = await open(rig, _key, range: 'bytes=0-9999');
      final firstBytes = await drain(first);
      final requestsAfterFirst = originServer.rangeRequestCount;
      expect(requestsAfterFirst, greaterThan(0));

      final second = await open(rig, _key, range: 'bytes=0-9999');
      final secondBytes = await drain(second);

      expect(secondBytes, firstBytes);
      expect(originServer.rangeRequestCount, requestsAfterFirst);

      final entry = rig.cache.peekEntry(_key)!;
      expect(entry.cacheMisses, 1);
      expect(entry.cacheHits, 1);
      expect(entry.cacheHitRate, 0.5);
    });

    test('a seek fetches only the chunk that covers it', () async {
      const start = 200 * 1024;

      final response = await open(
        rig,
        _key,
        range: 'bytes=$start-${start + 9}',
      );

      expect(await drain(response), payload.sublist(start, start + 10));

      final entry = rig.cache.peekEntry(_key)!;
      expect(entry.upstreamRequestCount, 1);
      expect(originServer.rangeRequestCount, 1);
      expect(entry.readyChunkCount, 1);
      expect(entry.chunkCount, 4);
      expect(entry.isRangeCached(0, 1000), isFalse);
    });

    test('reuses cached metadata for later HEAD requests', () async {
      final first = await open(rig, _key, method: 'HEAD');
      await drain(first);
      final headsAfterFirst = originServer.headCount;

      final second = await open(rig, _key, method: 'HEAD');
      await drain(second);

      expect(originServer.headCount, headsAfterFirst);
      expect(originServer.rangeRequestCount, 0);
    });

    test('a window spanning several chunks is served in order', () async {
      final from = 3 * _chunkSize - 100;
      final to = 3 * _chunkSize + 100;

      final response = await open(rig, _key, range: 'bytes=$from-$to');

      expect(await drain(response), payload.sublist(from, to + 1));
      expect(rig.cache.peekEntry(_key)!.readyChunkCount, 2);
    });
  });

  group('progressive playback', () {
    test('forwards the first chunk while later chunks are still parked', () async {
      // The gated origin serves chunk 0 immediately and blocks everything
      // after it. A proxy that buffered the whole window before replying would
      // never emit a single byte, so a first piece arriving at all is the proof.
      final gated = GatedOrigin(payload);
      final gatedRig = await startRig(
        cacheRoot: Directory(p.join(temp.path, 'gated-cache')),
        origin: gated,
      );
      addTearDown(gatedRig.dispose);

      final response = await open(gatedRig, _key, range: 'bytes=0-');
      expect(response.statusCode, HttpStatus.partialContent);

      final collected = BytesBuilder(copy: false);
      final firstPiece = Completer<void>();
      final completion = response.forEach((List<int> piece) {
        collected.add(piece);
        if (!firstPiece.isCompleted) firstPiece.complete();
      });

      await firstPiece.future.timeout(const Duration(seconds: 15));
      await waitFor(
        () => gated.blocked.isNotEmpty,
        description: 'a later chunk request to be parked',
      );

      // The byte just handed to the socket is already durable: chunks are
      // written and flushed before they are forwarded, never the other way
      // round. An abort therefore cannot lose work.
      final entry = gatedRig.cache.peekEntry(_key)!;
      expect(entry.isRangeCached(0, _chunkSize - 1), isTrue);

      gated.gate.complete();
      await completion;

      expect(collected.takeBytes(), payload);
    });

    test(
      'starts streaming long before the object has been transferred',
      () async {
        // 256 KiB at 256 KiB/s: a fully buffered response would need about a
        // second, so bytes reaching the client with only one chunk cached can
        // only mean the response is streaming.
        final slowRig = await startSlowRig('slow-cache', 256 * 1024);

        final response = await open(slowRig, _key);
        expect(response.statusCode, HttpStatus.ok);

        final entry = slowRig.cache.peekEntry(_key)!;
        final firstPiece = Completer<int>();
        final completion = response.forEach((List<int> piece) {
          if (!firstPiece.isCompleted) {
            firstPiece.complete(entry.readyChunkCount);
          }
        });

        final readyWhenFirstPieceArrived = await firstPiece.future.timeout(
          const Duration(seconds: 30),
        );
        await completion;

        expect(
          readyWhenFirstPieceArrived,
          lessThan(entry.chunkCount),
          reason: 'bytes must arrive before the whole object is cached',
        );
        expect(entry.isComplete, isTrue);
      },
    );
  });

  group('disconnects', () {
    test('a chunk already in flight still lands in the cache', () async {
      final gated = GatedOrigin(payload);
      final gatedRig = await startRig(
        cacheRoot: Directory(p.join(temp.path, 'inflight-cache')),
        origin: gated,
      );
      addTearDown(gatedRig.dispose);

      final response = await open(gatedRig, _key);
      final subscription = response.listen(
        (List<int> piece) {},
        onError: (Object error) {},
      );

      await waitFor(
        () => gated.blocked.isNotEmpty,
        description: 'a later chunk request to be parked',
      );
      // Walk away exactly like a player that seeks elsewhere.
      await subscription.cancel();

      // The fetch the proxy already started must not be collateral damage: it
      // is deliberately decoupled from the client's stream.
      gated.gate.complete();
      final entry = gatedRig.cache.peekEntry(_key)!;
      await waitFor(
        () => entry.readyChunkCount >= 2,
        description: 'the in-flight chunk to land on disk',
      );

      expect(entry.isRangeCached(0, 2 * _chunkSize - 1), isTrue);
    });

    test('a connection that dies mid-response does not lose the work', () async {
      final gated = GatedOrigin(payload);
      final gatedRig = await startRig(
        cacheRoot: Directory(p.join(temp.path, 'resume-cache')),
        origin: gated,
      );
      addTearDown(gatedRig.dispose);

      final response = await open(gatedRig, _key);
      final subscription = response.listen(
        (List<int> piece) {},
        onError: (Object error) {},
      );

      await waitFor(
        () => gated.blocked.isNotEmpty,
        description: 'a later chunk request to be parked',
      );

      // Losing the connection mid-response is what the proxy sees when a
      // browser abandons a media request. A Dart `HttpClient` is a poor stand-in
      // for that: cancelling its subscription leaves the socket open, so the OS
      // keeps acknowledging writes and the server has nothing to react to.
      // Dropping the server side produces the same event from the proxy's point
      // of view, and it is deterministic.
      await gatedRig.server.close(force: true);
      await subscription.cancel();
      gated.gate.complete();

      // Whichever path the proxy takes — noticing the dead peer and resuming in
      // the background, or simply finishing the window as it streams — the
      // guarantee is the same: a fetched chunk is written before its bytes are
      // handed over, so nothing is discarded.
      final entry = gatedRig.cache.peekEntry(_key)!;
      await waitFor(
        () => entry.isComplete,
        timeout: const Duration(seconds: 30),
        description: 'the window to finish landing in the cache',
      );

      expect(entry.cachedBytes, _payloadSize);
      expect(
        entry.isRangeCached(0, _payloadSize - 1),
        isTrue,
        reason: 'a dead connection must not cost already fetched bytes',
      );
    });

    test('resumes from the first chunk that is not on disk yet', () async {
      // The cache is what decides where a background fill picks up, so assert
      // the rule directly rather than inferring it from a network race.
      final entry = await rig.cache.entryFor(_key);
      expect(entry.firstUncachedOffset(0, _payloadSize - 1), 0);

      await drain(await open(rig, _key, range: 'bytes=0-${_chunkSize - 1}'));

      expect(entry.isRangeCached(0, _chunkSize - 1), isTrue);
      expect(entry.firstUncachedOffset(0, _payloadSize - 1), _chunkSize);
      expect(entry.firstUncachedOffset(0, _chunkSize - 1), isNull);
    });
  });
}
