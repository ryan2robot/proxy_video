import 'dart:io';

import 'package:args/args.dart';
import 'package:proxy_video/proxy_video.dart';
import 'package:test/test.dart';

void main() {
  String projectRoot() => Directory.current.path;

  ArgResults serverArgs(List<String> argv) =>
      Config.buildServerParser().parse(argv);

  group('Config.fromArgs', () {
    test('applies built-in defaults', () {
      final config = Config.fromArgs(
        serverArgs(<String>[]),
        environment: const <String, String>{},
        projectRoot: projectRoot(),
      );

      expect(config.bindAddress, kDefaultBindAddress);
      expect(config.port, kDefaultPort);
      expect(config.originBindAddress, kDefaultOriginBindAddress);
      expect(config.originPort, kDefaultOriginPort);
      expect(config.chunkSize, kDefaultChunkSize);
      expect(config.maxCacheBytes, kDefaultMaxCacheBytes);
      expect(config.maxConcurrentUpstream, kDefaultMaxConcurrentUpstream);
      expect(config.prefetchAhead, 0);
      expect(config.originThrottleBytesPerSecond, 0);
      expect(config.continueAfterDisconnect, isTrue);
      expect(config.logLevel, LogLevel.info);
      expect(config.servesLoopbackOnly, isTrue);
      expect(config.cacheDirPath, startsWith(config.dataDirPath));
    });

    test('CLI flags take precedence over environment variables', () {
      final config = Config.fromArgs(
        serverArgs(<String>[
          '--port',
          '9999',
          '--chunk-size',
          '256K',
          '--max-cache-bytes',
          '8M',
          '--origin-throttle',
          '1M',
          '--prefetch-ahead',
          '3',
          '--verbose',
        ]),
        environment: const <String, String>{'PROXY_VIDEO_PORT': '1234'},
        projectRoot: projectRoot(),
      );

      expect(config.port, 9999);
      expect(config.chunkSize, 256 * 1024);
      expect(config.maxCacheBytes, 8 * 1024 * 1024);
      expect(config.originThrottleBytesPerSecond, 1024 * 1024);
      expect(config.prefetchAhead, 3);
      expect(config.logLevel, LogLevel.debug);
    });

    test('environment variables fill in when no flag is given', () {
      final config = Config.fromArgs(
        serverArgs(<String>[]),
        environment: const <String, String>{
          'PROXY_VIDEO_PORT': '4321',
          'PROXY_VIDEO_CHUNK_SIZE': '64K',
          'PROXY_VIDEO_LOG_LEVEL': 'warn',
          'PROXY_VIDEO_ORIGIN_THROTTLE': '512K',
        },
        projectRoot: projectRoot(),
      );

      expect(config.port, 4321);
      expect(config.chunkSize, 64 * 1024);
      expect(config.logLevel, LogLevel.warn);
      expect(config.originThrottleBytesPerSecond, 512 * 1024);
    });

    test('accepts an ephemeral port for tests', () {
      final config = Config.fromArgs(
        serverArgs(<String>['--port', '0', '--origin-port', '0']),
        environment: const <String, String>{},
        projectRoot: projectRoot(),
      );

      expect(Config.isEphemeralPort(config.port), isTrue);
      expect(Config.isEphemeralPort(config.originPort), isTrue);
    });

    test('rejects identical app and origin ports', () {
      expect(
        () => Config.fromArgs(
          serverArgs(<String>['--port', '9000', '--origin-port', '9000']),
          environment: const <String, String>{},
          projectRoot: projectRoot(),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects an unknown log level coming from the environment', () {
      expect(
        () => Config.fromArgs(
          serverArgs(<String>[]),
          environment: const <String, String>{'PROXY_VIDEO_LOG_LEVEL': 'loud'},
          projectRoot: projectRoot(),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects a non-numeric environment override', () {
      expect(
        () => Config.fromArgs(
          serverArgs(<String>[]),
          environment: const <String, String>{'PROXY_VIDEO_PORT': 'http'},
          projectRoot: projectRoot(),
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('Config.copyWith', () {
    test('replaces only the requested fields', () {
      final base = Config.forTesting(dataDirPath: 'build/scaffold-test-data');
      final updated = base.copyWith(port: 1234, logLevel: LogLevel.error);

      expect(updated.port, 1234);
      expect(updated.logLevel, LogLevel.error);
      expect(updated.originPort, base.originPort);
      expect(updated.chunkSize, base.chunkSize);
      expect(updated.maxCacheBytes, base.maxCacheBytes);
    });

    test('validates the result', () {
      final base = Config.forTesting(
        dataDirPath: 'build/scaffold-test-data',
        port: 8080,
        originPort: 8090,
      );

      expect(() => base.copyWith(port: 8090), throwsA(isA<ArgumentError>()));
    });
  });

  group('Config.describe', () {
    test('reports human readable sizes', () {
      final config = Config.forTesting(
        dataDirPath: 'build/scaffold-test-data',
        chunkSize: 1 << 20,
        maxCacheBytes: 0,
      );

      final description = config.describe();
      expect(description['chunkSize'], '1.00 MiB');
      expect(description['maxCacheBytes'], 'unlimited');
      expect(description['originThrottle'], 'unlimited');
    });
  });

  group('arg parser schema', () {
    test('server parser exposes the proxy tuning flags', () {
      expect(
        Config.buildServerParser().options.keys,
        containsAll(<String>[
          'port',
          'origin-port',
          'chunk-size',
          'max-cache-bytes',
          'max-concurrent-upstream',
          'prefetch-ahead',
          'origin-throttle',
          'continue-after-disconnect',
          'log-level',
        ]),
      );
    });

    test('pipeline parser exposes the transcode flags but no server port', () {
      final options = Config.buildPipelineParser().options.keys;
      expect(
        options,
        containsAll(<String>['input', 'key', 'demo', 'crf', 'preset']),
      );
      expect(options, isNot(contains('port')));
    });

    test('--no-color disables colored logs', () {
      final config = Config.fromArgs(
        serverArgs(<String>['--no-color']),
        environment: const <String, String>{},
        projectRoot: projectRoot(),
      );

      expect(config.colorizeLogs, isFalse);
    });
  });
}
