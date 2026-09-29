import 'dart:typed_data';

import 'package:proxy_video/proxy_video.dart';
import 'package:test/test.dart';

void main() {
  group('Semaphore', () {
    test('hands out permits up to capacity and blocks beyond it', () async {
      final semaphore = Semaphore(2);
      await semaphore.acquire();
      await semaphore.acquire();

      var extraAcquired = false;
      final extra = semaphore.acquire().then((_) => extraAcquired = true);
      await Future<void>.delayed(Duration.zero);
      expect(extraAcquired, isFalse, reason: 'no permit is left');

      semaphore.release();
      await extra;
      expect(extraAcquired, isTrue);
    });

    test('serves waiters in FIFO order', () async {
      final semaphore = Semaphore(1);
      await semaphore.acquire();

      final order = <int>[];
      final first = semaphore.acquire().then((_) => order.add(1));
      final second = semaphore.acquire().then((_) => order.add(2));

      semaphore.release();
      await first;
      semaphore.release();
      await second;

      expect(order, <int>[1, 2]);
    });

    test('withPermit releases the permit when the action throws', () async {
      final semaphore = Semaphore(1);

      await expectLater(
        semaphore.withPermit<void>(() async => throw StateError('boom')),
        throwsA(isA<StateError>()),
      );

      // The permit came back: a fresh acquisition does not wait for one.
      await semaphore.withPermit<void>(() async {});
    });

    test('release without a matching acquire throws', () {
      final semaphore = Semaphore(1);
      expect(semaphore.release, throwsA(isA<StateError>()));
    });
  });

  group('AsyncMutex', () {
    test('runs queued sections one at a time, in order', () async {
      final mutex = AsyncMutex();
      final order = <int>[];

      final first = mutex.run(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        order.add(1);
      });
      final second = mutex.run(() async => order.add(2));
      await Future.wait<void>(<Future<void>>[first, second]);

      expect(order, <int>[1, 2]);
    });

    test('a failing section does not stall the queue', () async {
      final mutex = AsyncMutex();

      final failing = mutex.run<void>(() async => throw StateError('boom'));
      final following = mutex.run(() async => 42);

      await expectLater(failing, throwsA(isA<StateError>()));
      expect(await following, 42);
    });
  });

  group('Logger', () {
    late List<String> lines;

    setUp(() {
      lines = <String>[];
      Logger.sink = lines.add;
      Logger.level = LogLevel.info;
    });

    tearDown(() {
      Logger.sink = null;
      Logger.level = LogLevel.info;
    });

    test('respects the level threshold and renders structured fields', () {
      Logger.level = LogLevel.warn;

      final logger = Logger('proxy');
      logger.info('hidden');
      logger.warn(
        'shown',
        fields: <String, Object?>{'key': 'a/b.mp4', 'ms': 12},
      );

      expect(lines, hasLength(1));
      expect(lines.single, contains('WARN'));
      expect(lines.single, contains('[proxy] shown'));
      expect(lines.single, contains('key=a/b.mp4'));
      expect(lines.single, contains('ms=12'));
    });

    test('redacts binary payloads and collapses newlines', () {
      Logger.level = LogLevel.debug;

      Logger('bin').debug(
        'payload',
        fields: <String, Object?>{
          'data': Uint8List.fromList(<int>[1, 2, 3]),
          'text': 'line1\nline2',
        },
      );

      expect(lines, hasLength(1));
      expect(lines.single, contains('data=<3B>'));
      expect(lines.single, contains(r'text=line1\nline2'));
    });

    test('derives namespaced children', () {
      Logger('a').child('b').info('hi');

      expect(lines.single, contains('[a.b] hi'));
    });

    test('appends the error message and stack trace lines', () {
      Logger.level = LogLevel.error;

      Logger('proxy').error(
        'upstream failed',
        error: StateError('connection reset'),
        stackTrace: StackTrace.fromString('#0 first\n#1 second'),
      );

      expect(lines, hasLength(4));
      expect(lines[0], contains('upstream failed'));
      expect(lines[1], contains('connection reset'));
      expect(lines[2], contains('#0 first'));
      expect(lines[3], contains('#1 second'));
    });
  });
}
