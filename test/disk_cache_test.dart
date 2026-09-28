import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:proxy_video/proxy_video.dart';
import 'package:test/test.dart';

import 'helpers/test_origin.dart';

/// Drains a byte stream into a single buffer for comparison.
Future<Uint8List> collect(Stream<List<int>> stream) async {
  final builder = BytesBuilder(copy: false);
  await for (final piece in stream) {
    builder.add(piece);
  }
  return builder.takeBytes();
}

void main() {
  const chunkSize = 64 * 1024;
  const payloadSize = 256 * 1024;
  const budget = 300 * 1024;

  late Directory temp;
  late FakeOrigin origin;
  late DiskCache cache;

  DiskCache openCache({
    String folder = 'cache',
    int maxBytes = 0,
    Duration latency = Duration.zero,
  }) {
    origin.latency = latency;
    return DiskCache(
      root: Directory(p.join(temp.path, folder)),
      chunkSize: chunkSize,
      maxBytes: maxBytes,
      origin: origin,
      log: Logger('test'),
      maxConcurrentUpstream: 4,
    );
  }

  setUp(() {
    Logger.level = LogLevel.error;
    temp = Directory.systemTemp.createTempSync('proxy_video_cache_test_');
    origin = FakeOrigin(makePayload(payloadSize));
    cache = openCache();
  });

  tearDown(() async {
    await cache.close();
    Logger.reset();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  group('chunk bookkeeping', () {
    test('chunkCountFor rounds up', () {
      expect(chunkCountFor(0, 1024), 0);
      expect(chunkCountFor(1, 1024), 1);
      expect(chunkCountFor(1024, 1024), 1);
      expect(chunkCountFor(1025, 1024), 2);
      expect(chunkCountFor(4 * 1024, 1024), 4);
    });

    test('chunk bitmaps round-trip and drop out-of-range indices', () {
      final bitmap = encodeChunkBitmap(<int>[0, 3, 9, 100, 9999], 130);

      expect(decodeChunkBitmap(bitmap, 130), <int>{0, 3, 9, 100});
      expect(countChunkBitmapBits(bitmap), 4);
      expect(decodeChunkBitmap(bitmap, 5), <int>{0, 3});
      expect(decodeChunkBitmap('', 130), isEmpty);
      expect(decodeChunkBitmap(bitmap, 0), isEmpty);
    });

    test('metadata survives a JSON round-trip', () {
      final meta = CacheEntryMeta(
        key: 'clips/a.mp4',
        totalSize: 1000,
        chunkSize: 256,
        chunkBitmap: encodeChunkBitmap(<int>[0, 2], 4),
        etag: '"v1"',
        contentType: 'video/mp4',
        lastModified: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 2),
      );

      final parsed = CacheEntryMeta.tryParse(jsonEncode(meta.toJson()))!;

      expect(parsed.key, 'clips/a.mp4');
      expect(parsed.totalSize, 1000);
      expect(parsed.chunkSize, 256);
      expect(parsed.etag, '"v1"');
      expect(parsed.contentType, 'video/mp4');
      expect(parsed.lastModified, DateTime.utc(2026, 1, 1));
      expect(decodeChunkBitmap(parsed.chunkBitmap, 4), <int>{0, 2});
    });

    test('unusable metadata is rejected rather than throwing', () {
      expect(CacheEntryMeta.tryParse('not json at all'), isNull);
      expect(CacheEntryMeta.tryParse('{"key":"a"}'), isNull);
      expect(CacheEntryMeta.tryParse('[]'), isNull);
      expect(
        CacheEntryMeta.tryParse(
          '{"key":"a","totalSize":-1,"chunkSize":1,"chunkBitmap":""}',
        ),
        isNull,
      );
    });
  });

  group('CacheEntry range reads', () {
    test('fills a chunk on demand and serves the requested slice', () async {
      final entry = await cache.entryFor('clips/a.mp4');

      final data = await collect(entry.readRange(0, 1000));

      expect(data, origin.bytes.sublist(0, 1001));
      expect(entry.knownTotalSize, payloadSize);
      expect(entry.chunkCount, 4);
      expect(entry.readyChunkCount, 1);
      expect(entry.isRangeCached(0, 1000), isTrue);
      expect(origin.requestedRanges, <ByteRange>[
        const ByteRange(0, chunkSize - 1),
      ]);
    });

    test('a seek downloads only the chunks covering it', () async {
      final entry = await cache.entryFor('clips/a.mp4');

      const start = 200 * 1024;
      final data = await collect(entry.readRange(start, start + 10));

      expect(data, origin.bytes.sublist(start, start + 11));
      expect(origin.requestedRanges, <ByteRange>[
        const ByteRange(3 * chunkSize, 4 * chunkSize - 1),
      ]);
      expect(entry.readyChunkCount, 1);
      expect(entry.isRangeCached(0, 1000), isFalse);
    });

    test('reassembles a range that spans a chunk boundary', () async {
      final entry = await cache.entryFor('clips/a.mp4');

      final from = chunkSize - 5;
      final to = chunkSize + 5;
      final data = await collect(entry.readRange(from, to));

      expect(data, origin.bytes.sublist(from, to + 1));
      expect(entry.readyChunkCount, 2);
    });

    test(
      'a cached range is served without touching the origin again',
      () async {
        final entry = await cache.entryFor('clips/a.mp4');
        await collect(entry.readRange(0, 70000));

        final requestsAfterFirstRead = origin.rangeRequestCount;
        final data = await collect(entry.readRange(60000, 70000));

        expect(data, origin.bytes.sublist(60000, 70001));
        expect(origin.rangeRequestCount, requestsAfterFirstRead);
      },
    );

    test(
      'concurrent reads of the same missing chunk share one fetch',
      () async {
        final entry = await cache.entryFor('clips/a.mp4');
        origin.latency = const Duration(milliseconds: 20);

        final results = await Future.wait(<Future<Uint8List>>[
          collect(entry.readRange(0, 100)),
          collect(entry.readRange(0, 100)),
          collect(entry.readRange(0, 100)),
        ]);

        expect(origin.rangeRequestCount, 1);
        for (final result in results) {
          expect(result, origin.bytes.sublist(0, 101));
        }
      },
    );

    test(
      'clamps a range that runs past the end and completes the object',
      () async {
        final entry = await cache.entryFor('clips/a.mp4');

        final data = await collect(entry.readRange(0, payloadSize + 9999));

        expect(data, origin.bytes);
        expect(entry.isComplete, isTrue);
        expect(entry.readyChunkCount, 4);
        expect(entry.cachedBytes, payloadSize);
      },
    );

    test('reports a missing object as OriginNotFoundException', () async {
      origin.missing = true;
      final entry = await cache.entryFor('clips/missing.mp4');

      await expectLater(
        collect(entry.readRange(0, 10)),
        throwsA(isA<OriginNotFoundException>()),
      );
    });

    test(
      'writes cached bytes to the mirrored path under the cache root',
      () async {
        final entry = await cache.entryFor('clips/takes/a.mp4');
        await collect(entry.readRange(0, 100));

        expect(entry.dataFile.existsSync(), isTrue);
        expect(entry.metaFile.existsSync(), isTrue);
        expect(
          p.normalize(entry.dataFile.path),
          p.normalize(p.join(cache.root.path, 'clips', 'takes', 'a.mp4.bin')),
        );
        expect(await entry.dataFile.length(), payloadSize);
      },
    );
  });

  group('persistence across restarts', () {
    test(
      'metadata from a previous process keeps cached chunks usable',
      () async {
        final entry = await cache.entryFor('clips/a.mp4');
        await collect(entry.readRange(0, 2000));
        await cache.close();

        final requestsBefore = origin.rangeRequestCount;
        final reopened = openCache();
        final reopenedEntry = await reopened.entryFor('clips/a.mp4');
        final data = await collect(reopenedEntry.readRange(0, 2000));

        expect(data, origin.bytes.sublist(0, 2001));
        expect(reopenedEntry.readyChunkCount, 1);
        expect(reopenedEntry.knownTotalSize, payloadSize);
        expect(origin.rangeRequestCount, requestsBefore);

        await reopened.close();
      },
    );

    test('a changed entity tag invalidates the cached bytes', () async {
      origin.etag = '"v1"';
      final entry = await cache.entryFor('clips/a.mp4');
      await collect(entry.readRange(0, 2000));
      await cache.close();

      // Same size, different content: only the tag reveals the swap.
      origin.bytes = makePayload(payloadSize, seed: 7);
      origin.etag = '"v2"';

      final reopened = openCache();
      final reopenedEntry = await reopened.entryFor('clips/a.mp4');
      final requestsBefore = origin.rangeRequestCount;
      final data = await collect(reopenedEntry.readRange(0, 2000));

      expect(data, origin.bytes.sublist(0, 2001));
      expect(origin.rangeRequestCount, greaterThan(requestsBefore));

      await reopened.close();
    });
  });

  group('budget enforcement', () {
    test('evicts the least recently used object first', () async {
      final limited = openCache(maxBytes: budget, folder: 'lru');

      final first = await limited.entryFor('a.mp4');
      await collect(first.readRange(0, 100));

      final second = await limited.entryFor('b.mp4');
      await collect(second.readRange(0, 100));

      // Two preallocated 256 KiB files exceed the 300 KiB budget.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      first.touch();

      await limited.enforceBudget(force: true);

      expect(limited.trackedBytes, lessThanOrEqualTo(budget));
      expect(limited.peekEntry('a.mp4'), isNotNull);
      expect(limited.peekEntry('b.mp4'), isNull);

      await limited.close();
    });

    test('clear(key) drops just that object', () async {
      final entry = await cache.entryFor('clips/a.mp4');
      await collect(entry.readRange(0, 100));
      expect(entry.dataFile.existsSync(), isTrue);

      await cache.clear(key: 'clips/a.mp4');

      expect(cache.peekEntry('clips/a.mp4'), isNull);
      expect(entry.dataFile.existsSync(), isFalse);
      expect((await cache.stats()).totalBytes, 0);
    });

    test('clear() wipes the whole cache directory', () async {
      final entry = await cache.entryFor('clips/a.mp4');
      await collect(entry.readRange(0, 100));

      await cache.clear();

      expect(cache.entryCount, 0);
      expect(cache.root.existsSync(), isTrue);
      expect((await cache.stats()).totalBytes, 0);
    });

    test('stats reports per-object progress', () async {
      final entry = await cache.entryFor('clips/a.mp4');
      await collect(entry.readRange(0, 100));

      final stats = await cache.stats();
      final subject = stats.entries.single;

      expect(stats.chunkSize, chunkSize);
      expect(stats.upstreamCapacity, 4);
      expect(subject.key, 'clips/a.mp4');
      expect(subject.chunkCount, 4);
      expect(subject.readyChunks, 1);
      expect(subject.cachedBytes, chunkSize);
      expect(subject.cachedFraction, closeTo(0.25, 0.0001));
      expect(subject.complete, isFalse);
      expect(decodeChunkBitmap(subject.chunkBitmap, 4), <int>{0});
    });
  });

  group('key safety', () {
    test('refuses keys that could escape the cache directory', () async {
      for (final key in <String>[
        '../escape.mp4',
        'a/../../b.mp4',
        'a//b.mp4',
        'clips/',
        '',
        r'..\..\evil.mp4',
      ]) {
        await expectLater(cache.entryFor(key), throwsA(isA<ArgumentError>()));
      }
    });
  });
}
