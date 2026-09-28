import 'dart:async';
import 'dart:typed_data';

import 'package:proxy_video/proxy_video.dart';
import 'package:test/test.dart';

void main() {
  group('parseByteSize', () {
    test('accepts plain byte counts', () {
      expect(parseByteSize('4096'), 4096);
      expect(parseByteSize(' 1048576 '), 1048576);
    });

    test('accepts binary suffixes case-insensitively', () {
      expect(parseByteSize('1K'), 1024);
      expect(parseByteSize('1k'), 1024);
      expect(parseByteSize('512KB'), 512 * 1024);
      expect(parseByteSize('2M'), 2 << 20);
      expect(parseByteSize('1G'), 1 << 30);
    });

    test('rejects garbage and negative values', () {
      expect(() => parseByteSize('abc'), throwsA(isA<FormatException>()));
      expect(() => parseByteSize('-1'), throwsA(isA<FormatException>()));
      expect(() => parseByteSize('1.5M'), throwsA(isA<FormatException>()));
      expect(() => parseByteSize(''), throwsA(isA<FormatException>()));
    });

    test('names the offending option in the error message', () {
      expect(
        () => parseByteSize('nope', label: '--max-cache-bytes'),
        throwsA(
          isA<FormatException>().having(
            (FormatException e) => e.message,
            'message',
            contains('--max-cache-bytes'),
          ),
        ),
      );
    });
  });

  group('formatByteSize', () {
    test('renders binary units', () {
      expect(formatByteSize(0), '0 B');
      expect(formatByteSize(512), '512 B');
      expect(formatByteSize(1024), '1.00 KiB');
      expect(formatByteSize(100 * 1024), '100 KiB');
      expect(formatByteSize(1 << 20), '1.00 MiB');
      expect(formatByteSize(2 << 30), '2.00 GiB');
    });
  });

  group('Semaphore', () {
    test('hands out permits up to capacity', () async {
      final semaphore = Semaphore(2);

      await semaphore.acquire();
      await semaphore.acquire();

      expect(semaphore.inUse, 2);
      expect(semaphore.available, 0);
      expect(semaphore.tryAcquire(), isFalse);

      semaphore.release();
      expect(semaphore.available, 1);
      expect(semaphore.tryAcquire(), isTrue);
      expect(semaphore.waiting, 0);
    });

    test('serves waiters in FIFO order', () async {
      final semaphore = Semaphore(1);
      await semaphore.acquire();

      final order = <int>[];
      final first = semaphore.acquire().then((_) => order.add(1));
      final second = semaphore.acquire().then((_) => order.add(2));

      expect(semaphore.waiting, 2);

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

      expect(semaphore.inUse, 0);
      expect(semaphore.tryAcquire(), isTrue);
    });

    test('times out instead of queueing forever', () async {
      final semaphore = Semaphore(1);
      await semaphore.acquire();

      await expectLater(
        semaphore.acquire(timeout: const Duration(milliseconds: 20)),
        throwsA(isA<TimeoutException>()),
      );

      expect(semaphore.waiting, 0);
      semaphore.release();
      expect(semaphore.available, 1);
    });

    test('release without a matching acquire throws', () {
      final semaphore = Semaphore(1);
      expect(semaphore.release, throwsA(isA<StateError>()));
    });
  });

  group('Logger', () {
    tearDown(Logger.reset);

    test('respects the level threshold and renders structured fields', () {
      final lines = <String>[];
      Logger.configure(
        level: LogLevel.warn,
        colorEnabled: false,
        output: lines.add,
      );

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
      final lines = <String>[];
      Logger.configure(
        level: LogLevel.debug,
        colorEnabled: false,
        output: lines.add,
      );

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
      final lines = <String>[];
      Logger.configure(
        level: LogLevel.info,
        colorEnabled: false,
        output: lines.add,
      );

      Logger('a').child('b').info('hi');

      expect(lines.single, contains('[a.b] hi'));
    });

    test('appends the error message and stack trace lines', () {
      final lines = <String>[];
      Logger.configure(
        level: LogLevel.error,
        colorEnabled: false,
        output: lines.add,
      );

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
