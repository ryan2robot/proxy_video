import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:proxy_video/proxy_video.dart';
import 'package:test/test.dart';

import 'helpers/test_origin.dart';

/// In-memory [CosClient] that records what it was asked to do.
class FakeCosClient implements CosClient {
  final Map<String, Uint8List> objects = <String, Uint8List>{};
  int putCount = 0;
  bool closed = false;

  @override
  Future<void> putObject({
    required String key,
    required Stream<List<int>> data,
    required int length,
    String? contentType,
  }) async {
    putCount++;

    final builder = BytesBuilder(copy: false);
    await for (final piece in data) {
      builder.add(piece);
    }
    final bytes = builder.takeBytes();
    if (bytes.length != length) {
      throw StateError('declared $length bytes but sent ${bytes.length}');
    }
    objects[key] = bytes;
  }

  @override
  Future<CosObjectInfo?> headObject(String key) async {
    final bytes = objects[key];
    if (bytes == null) return null;
    return CosObjectInfo(
      key: key,
      size: bytes.length,
      etag: '"${bytes.length}"',
      lastModified: DateTime.utc(2026, 1, 1),
      contentType: 'video/mp4',
    );
  }

  @override
  Future<bool> deleteObject(String key) async => objects.remove(key) != null;

  @override
  Future<List<CosObjectInfo>> listObjects({String? prefix}) async => objects
      .entries
      .where(
        (MapEntry<String, Uint8List> e) =>
            prefix == null || e.key.startsWith(prefix),
      )
      .map(
        (MapEntry<String, Uint8List> e) =>
            CosObjectInfo(key: e.key, size: e.value.length),
      )
      .toList();

  @override
  void close() => closed = true;
}

void main() {
  late Directory temp;

  setUp(() {
    Logger.level = LogLevel.error;
    temp = Directory.systemTemp.createTempSync('proxy_video_storage_test_');
  });

  tearDown(() {
    Logger.reset();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  group('LocalDirStorage', () {
    late LocalDirStorage storage;

    setUp(() {
      storage = LocalDirStorage(
        root: Directory(p.join(temp.path, 'origin')),
        originBaseUri: Uri.parse('http://127.0.0.1:8090'),
        log: Logger('test'),
      );
    });

    test('streams bytes to the mirrored path and reports a stat', () async {
      final payload = makePayload(4096);

      final stat = await storage.put(
        'clips/a.mp4',
        Stream<List<int>>.value(payload),
        length: payload.length,
        contentType: 'video/mp4',
      );

      expect(stat.key, 'clips/a.mp4');
      expect(stat.size, payload.length);
      expect(stat.contentType, 'video/mp4');
      expect(stat.etag, isNotNull);
      expect(stat.url.toString(), 'http://127.0.0.1:8090/origin/clips/a.mp4');

      final onDisk = File(p.join(storage.root.path, 'clips', 'a.mp4'));
      expect(onDisk.existsSync(), isTrue);
      expect(await onDisk.readAsBytes(), payload);
    });

    test('derives the content type from the key', () async {
      final stat = await storage.put(
        'clips/a.mp4',
        Stream<List<int>>.value(makePayload(8)),
        length: 8,
      );

      expect(stat.contentType, 'video/mp4');
      expect(await storage.stat('unknown.bin'), isNull);
    });

    test('leaves no scratch file behind', () async {
      await storage.put(
        'a.mp4',
        Stream<List<int>>.value(makePayload(16)),
        length: 16,
      );

      final names = storage.root
          .listSync(recursive: true)
          .map((FileSystemEntity entity) => p.basename(entity.path));
      expect(
        names.where(
          (String name) => name.endsWith(LocalDirStorage.scratchSuffix),
        ),
        isEmpty,
      );
    });

    test('rejects a stream shorter than the declared length', () async {
      await expectLater(
        storage.put(
          'short.mp4',
          Stream<List<int>>.value(makePayload(8)),
          length: 64,
        ),
        throwsA(isA<StorageException>()),
      );

      expect(await storage.stat('short.mp4'), isNull);
      expect(storage.root.listSync(recursive: true).whereType<File>(), isEmpty);
    });

    test('putFile publishes a file from disk', () async {
      final source = File(p.join(temp.path, 'source.mp4'));
      await source.writeAsBytes(makePayload(2048));

      final stat = await storage.putFile('clips/source.mp4', source);

      expect(stat.size, 2048);
      expect((await storage.stat('clips/source.mp4'))!.size, 2048);
    });

    test('delete reports whether anything was removed', () async {
      await storage.put(
        'a.mp4',
        Stream<List<int>>.value(makePayload(16)),
        length: 16,
      );

      expect(await storage.delete('a.mp4'), isTrue);
      expect(await storage.delete('a.mp4'), isFalse);
      expect(await storage.stat('a.mp4'), isNull);
    });

    test(
      'list walks the bucket, skips scratch files and honours a prefix',
      () async {
        await storage.put(
          'a.mp4',
          Stream<List<int>>.value(makePayload(16)),
          length: 16,
        );
        await storage.put(
          'clips/b.mp4',
          Stream<List<int>>.value(makePayload(32)),
          length: 32,
        );
        await File(
          p.join(
            storage.root.path,
            'clips',
            'leftover.mp4${LocalDirStorage.scratchSuffix}',
          ),
        ).writeAsBytes(<int>[1, 2, 3]);

        expect((await storage.list()).map((ObjectStat o) => o.key), <String>[
          'a.mp4',
          'clips/b.mp4',
        ]);
        expect(
          (await storage.list(prefix: 'clips/')).map((ObjectStat o) => o.key),
          <String>['clips/b.mp4'],
        );
        expect(await storage.list(prefix: 'zzz/'), isEmpty);
      },
    );

    test('refuses keys that could escape the bucket', () async {
      await expectLater(
        storage.put(
          '../evil.mp4',
          Stream<List<int>>.value(<int>[1]),
          length: 1,
        ),
        throwsA(isA<StorageException>()),
      );
      await expectLater(
        storage.stat('../../etc/passwd'),
        throwsA(isA<StorageException>()),
      );
      expect(
        () => storage.urlFor('a//b.mp4'),
        throwsA(isA<StorageException>()),
      );
    });

    test('urlFor keeps the key structure', () {
      expect(
        storage.urlFor('clips/take_01.mp4').toString(),
        'http://127.0.0.1:8090/origin/clips/take_01.mp4',
      );
    });
  });

  group('CosStorage', () {
    const credentials = CosCredentials(
      secretId: 'id',
      secretKey: 'secret',
      bucket: 'media-123',
      region: 'ap-guangzhou',
      cdnDomain: 'cdn.example.com',
    );

    test('uploads through the injected client', () async {
      final client = FakeCosClient();
      final storage = CosStorage(
        credentials: credentials,
        client: client,
        log: Logger('test'),
      );

      final stat = await storage.put(
        'clips/a.mp4',
        Stream<List<int>>.value(makePayload(64)),
        length: 64,
      );

      expect(client.putCount, 1);
      expect(client.objects['clips/a.mp4']!.length, 64);
      expect(stat.size, 64);
      expect(stat.url.toString(), 'https://cdn.example.com/clips/a.mp4');

      await storage.close();
      expect(client.closed, isTrue);
    });

    test('falls back to the bucket endpoint without a CDN domain', () {
      final storage = CosStorage(
        credentials: const CosCredentials(
          secretId: 'id',
          secretKey: 'secret',
          bucket: 'media-123',
          region: 'ap-guangzhou',
        ),
        client: FakeCosClient(),
        log: Logger('test'),
      );

      expect(
        storage.urlFor('a.mp4').toString(),
        'https://media-123.cos.ap-guangzhou.myqcloud.com/a.mp4',
      );
    });

    test(
      'requires the length up front because the request is signed',
      () async {
        final storage = CosStorage(
          credentials: credentials,
          client: FakeCosClient(),
          log: Logger('test'),
        );

        await expectLater(
          storage.put('a.mp4', Stream<List<int>>.value(<int>[1])),
          throwsA(isA<StorageException>()),
        );
      },
    );

    test('lists and deletes through the client', () async {
      final client = FakeCosClient();
      final storage = CosStorage(
        credentials: credentials,
        client: client,
        log: Logger('test'),
      );

      await storage.put(
        'a.mp4',
        Stream<List<int>>.value(makePayload(16)),
        length: 16,
      );
      await storage.put(
        'clips/b.mp4',
        Stream<List<int>>.value(makePayload(32)),
        length: 32,
      );

      expect((await storage.list()).map((ObjectStat o) => o.key), <String>[
        'a.mp4',
        'clips/b.mp4',
      ]);
      expect((await storage.list(prefix: 'clips/')).length, 1);
      expect(await storage.delete('a.mp4'), isTrue);
      expect(await storage.stat('a.mp4'), isNull);
    });
  });

  group('CosCredentials', () {
    test('returns null when nothing is configured', () {
      expect(
        CosCredentials.tryFromEnvironment(const <String, String>{}),
        isNull,
      );
    });

    test('parses a complete configuration', () {
      final parsed = CosCredentials.tryFromEnvironment(const <String, String>{
        CosCredentials.secretIdKey: 'id',
        CosCredentials.secretKeyKey: 'secret',
        CosCredentials.bucketKey: 'media-123',
        CosCredentials.regionKey: 'ap-guangzhou',
        CosCredentials.cdnDomainKey: 'cdn.example.com',
      })!;

      expect(parsed.bucket, 'media-123');
      expect(parsed.region, 'ap-guangzhou');
      expect(parsed.cdnDomain, 'cdn.example.com');
      expect(
        parsed.urlFor('a/b.mp4').toString(),
        'https://cdn.example.com/a/b.mp4',
      );
    });

    test('rejects a partial configuration', () {
      expect(
        () => CosCredentials.tryFromEnvironment(const <String, String>{
          CosCredentials.bucketKey: 'media-123',
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('never exposes secrets through toString', () {
      const credentials = CosCredentials(
        secretId: 'AKIDshouldnotappear',
        secretKey: 'SECRETshouldnotappear',
        bucket: 'media-123',
        region: 'ap-guangzhou',
      );

      expect(credentials.toString(), isNot(contains('AKIDshouldnotappear')));
      expect(credentials.toString(), isNot(contains('SECRETshouldnotappear')));
    });
  });

  group('CosStorage.tryFromEnvironment', () {
    test('returns null when COS is not configured', () {
      expect(CosStorage.tryFromEnvironment(const <String, String>{}), isNull);
    });

    test(
      'fails loudly when credentials exist but no client is wired in',
      () async {
        final storage = CosStorage.tryFromEnvironment(const <String, String>{
          CosCredentials.secretIdKey: 'id',
          CosCredentials.secretKeyKey: 'secret',
          CosCredentials.bucketKey: 'media-123',
          CosCredentials.regionKey: 'ap-guangzhou',
        }, log: Logger('test'))!;

        await expectLater(
          storage.put('a.mp4', Stream<List<int>>.value(<int>[1]), length: 1),
          throwsA(isA<CosNotConfiguredException>()),
        );
        await expectLater(
          storage.stat('a.mp4'),
          throwsA(isA<CosNotConfiguredException>()),
        );
      },
    );
  });
}
