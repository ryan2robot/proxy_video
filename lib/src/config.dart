import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'logger.dart';
import 'util/byte_size.dart';

/// Default address both servers bind to. Loopback keeps the proxy and its
/// cache API off the network unless the operator opts out explicitly.
const String kDefaultBindAddress = '127.0.0.1';

/// Default port of the app server (proxy + web UI + API).
const int kDefaultPort = 8080;

/// Default address of the simulated origin/CDN server.
const String kDefaultOriginBindAddress = '127.0.0.1';

/// Default port of the simulated origin/CDN server.
const int kDefaultOriginPort = 8090;

/// Default cache chunk size: 1 MiB, a good compromise between seek latency
/// and request overhead.
const int kDefaultChunkSize = 1 << 20;

/// Default disk cache budget: 2 GiB.
const int kDefaultMaxCacheBytes = 2 << 30;

/// Default number of concurrent upstream range requests.
const int kDefaultMaxConcurrentUpstream = 4;

/// Sentinel letting [Config.copyWith] tell "not supplied" apart from `null`.
const Object _unset = Object();

/// Fully resolved runtime configuration shared by both CLI entry points and
/// every subsystem.
///
/// Instances are immutable and validated. Build one with [Config.fromArgs]
/// (production) or [Config.forTesting] (tests).
class Config {
  const Config._({
    required this.projectRoot,
    required this.bindAddress,
    required this.port,
    required this.originBindAddress,
    required this.originPort,
    required this.dataDirPath,
    required this.cacheDirPath,
    required this.tempDirPath,
    required this.originDirPath,
    required this.chunkSize,
    required this.maxCacheBytes,
    required this.maxConcurrentUpstream,
    required this.prefetchAhead,
    required this.originThrottleBytesPerSecond,
    required this.upstreamTimeout,
    required this.connectTimeout,
    required this.continueAfterDisconnect,
    required this.logLevel,
    required this.colorizeLogs,
    required this.ffmpegPath,
  });

  /// Directory containing `pubspec.yaml`; anchors all default paths.
  final String projectRoot;

  /// Address the app server (proxy + UI + API) listens on.
  final String bindAddress;

  /// Port the app server listens on. `0` requests an ephemeral port.
  final int port;

  /// Address the simulated origin/CDN listens on.
  final String originBindAddress;

  /// Port the origin listens on. `0` requests an ephemeral port.
  final int originPort;

  /// Root directory for all mutable runtime data.
  final String dataDirPath;

  /// Directory holding one cache entry (`.bin` + `.meta.json`) per media key.
  final String cacheDirPath;

  /// Scratch directory for transcode output before upload.
  final String tempDirPath;

  /// Directory backing the `LocalDirStorage` "remote bucket".
  final String originDirPath;

  /// Cache chunk granularity in bytes.
  final int chunkSize;

  /// Cache budget in bytes; `0` disables eviction.
  final int maxCacheBytes;

  /// Upper bound on in-flight upstream range requests.
  final int maxConcurrentUpstream;

  /// How many chunks to speculatively fetch after the one being read.
  final int prefetchAhead;

  /// Bandwidth cap applied by the simulated origin; `0` means unlimited.
  final int originThrottleBytesPerSecond;

  /// Timeout for a single upstream range request.
  final Duration upstreamTimeout;

  /// Timeout for establishing an upstream TCP connection.
  final Duration connectTimeout;

  /// Whether cache chunks keep filling after the browser disconnects.
  final bool continueAfterDisconnect;

  /// Minimum severity written to the console.
  final LogLevel logLevel;

  /// Whether log output may use ANSI colors.
  final bool colorizeLogs;

  /// Explicit ffmpeg path; `null` triggers auto-discovery.
  final String? ffmpegPath;

  /// Builds a configuration from parsed CLI arguments.
  ///
  /// Precedence is CLI flag > environment variable > built-in default.
  factory Config.fromArgs(
    ArgResults args, {
    Map<String, String>? environment,
    String? projectRoot,
  }) {
    final env = environment ?? Platform.environment;

    final root = _resolveProjectRoot(
      explicit: projectRoot ?? _optString(args, 'project-root'),
      environment: env,
    );

    final dataDirPath = _abs(
      _optString(args, 'data-dir') ??
          _envString(env, 'PROXY_VIDEO_DATA_DIR') ??
          p.join(root, 'data'),
    );
    final cacheDirPath = _abs(
      _optString(args, 'cache-dir') ??
          _envString(env, 'PROXY_VIDEO_CACHE_DIR') ??
          p.join(dataDirPath, 'cache'),
    );

    final chunkSize = _sizeOption(
      args,
      'chunk-size',
      env,
      'PROXY_VIDEO_CHUNK_SIZE',
      kDefaultChunkSize,
    );
    final maxCacheBytes = _sizeOption(
      args,
      'max-cache-bytes',
      env,
      'PROXY_VIDEO_MAX_CACHE_BYTES',
      kDefaultMaxCacheBytes,
    );
    final originThrottle = _sizeOption(
      args,
      'origin-throttle',
      env,
      'PROXY_VIDEO_ORIGIN_THROTTLE',
      0,
    );

    final verbose = _optBool(args, 'verbose') ?? false;
    final rawLogLevel =
        _optString(args, 'log-level') ??
        _envString(env, 'PROXY_VIDEO_LOG_LEVEL');

    final LogLevel logLevel;
    if (verbose) {
      logLevel = LogLevel.debug;
    } else if (rawLogLevel == null) {
      logLevel = LogLevel.info;
    } else {
      final parsed = LogLevel.tryParse(rawLogLevel);
      if (parsed == null) {
        throw FormatException(
          'Unknown log level "$rawLogLevel" (expected debug, info, warn, error)',
        );
      }
      logLevel = parsed;
    }

    final config = Config._(
      projectRoot: root,
      bindAddress:
          _optString(args, 'bind') ??
          _envString(env, 'PROXY_VIDEO_BIND') ??
          kDefaultBindAddress,
      port:
          _optInt(args, 'port') ??
          _envInt(env, 'PROXY_VIDEO_PORT', kDefaultPort),
      originBindAddress:
          _optString(args, 'origin-bind') ??
          _envString(env, 'PROXY_VIDEO_ORIGIN_BIND') ??
          kDefaultOriginBindAddress,
      originPort:
          _optInt(args, 'origin-port') ??
          _envInt(env, 'PROXY_VIDEO_ORIGIN_PORT', kDefaultOriginPort),
      dataDirPath: dataDirPath,
      cacheDirPath: cacheDirPath,
      tempDirPath: _abs(p.join(dataDirPath, 'tmp')),
      originDirPath: _abs(p.join(dataDirPath, 'origin')),
      chunkSize: chunkSize,
      maxCacheBytes: maxCacheBytes,
      maxConcurrentUpstream:
          _optInt(args, 'max-concurrent-upstream') ??
          _envInt(
            env,
            'PROXY_VIDEO_MAX_CONCURRENT_UPSTREAM',
            kDefaultMaxConcurrentUpstream,
          ),
      prefetchAhead:
          _optInt(args, 'prefetch-ahead') ??
          _envInt(env, 'PROXY_VIDEO_PREFETCH_AHEAD', 0),
      originThrottleBytesPerSecond: originThrottle,
      upstreamTimeout: Duration(
        seconds:
            _optInt(args, 'upstream-timeout') ??
            _envInt(env, 'PROXY_VIDEO_UPSTREAM_TIMEOUT', 30),
      ),
      connectTimeout: const Duration(seconds: 10),
      continueAfterDisconnect:
          _optBool(args, 'continue-after-disconnect') ?? true,
      logLevel: logLevel,
      colorizeLogs:
          _optBool(args, 'color') ?? (_envString(env, 'NO_COLOR') == null),
      ffmpegPath: _optString(args, 'ffmpeg') ?? _envString(env, 'FFMPEG_PATH'),
    );

    config.validate();
    return config;
  }

  /// Builds a configuration suitable for tests: ephemeral ports, small chunks
  /// and quiet logging by default.
  factory Config.forTesting({
    String? projectRoot,
    required String dataDirPath,
    int port = 0,
    int originPort = 0,
    int chunkSize = 4096,
    int maxCacheBytes = 4 << 20,
    int maxConcurrentUpstream = 4,
    int prefetchAhead = 0,
    int originThrottleBytesPerSecond = 0,
    Duration upstreamTimeout = const Duration(seconds: 20),
    bool continueAfterDisconnect = true,
    LogLevel logLevel = LogLevel.warn,
    String? ffmpegPath,
  }) {
    final root = _abs(projectRoot ?? Directory.current.path);
    final data = _abs(dataDirPath);
    final config = Config._(
      projectRoot: root,
      bindAddress: kDefaultBindAddress,
      port: port,
      originBindAddress: kDefaultOriginBindAddress,
      originPort: originPort,
      dataDirPath: data,
      cacheDirPath: _abs(p.join(data, 'cache')),
      tempDirPath: _abs(p.join(data, 'tmp')),
      originDirPath: _abs(p.join(data, 'origin')),
      chunkSize: chunkSize,
      maxCacheBytes: maxCacheBytes,
      maxConcurrentUpstream: maxConcurrentUpstream,
      prefetchAhead: prefetchAhead,
      originThrottleBytesPerSecond: originThrottleBytesPerSecond,
      upstreamTimeout: upstreamTimeout,
      connectTimeout: const Duration(seconds: 5),
      continueAfterDisconnect: continueAfterDisconnect,
      logLevel: logLevel,
      colorizeLogs: false,
      ffmpegPath: ffmpegPath,
    );
    config.validate();
    return config;
  }

  /// Directory holding all mutable runtime data.
  Directory get dataDirectory => Directory(dataDirPath);

  /// Directory holding cache entries.
  Directory get cacheDirectory => Directory(cacheDirPath);

  /// Scratch directory for transcode output.
  Directory get tempDirectory => Directory(tempDirPath);

  /// Directory backing the local "remote bucket".
  Directory get originDirectory => Directory(originDirPath);

  /// Base URI of the simulated origin/CDN.
  Uri get originBaseUri =>
      Uri(scheme: 'http', host: originBindAddress, port: originPort);

  /// Base URI of the app server.
  Uri get appBaseUri => Uri(scheme: 'http', host: bindAddress, port: port);

  /// Whether both listeners are restricted to loopback interfaces.
  bool get servesLoopbackOnly =>
      _isLoopback(bindAddress) && _isLoopback(originBindAddress);

  /// Resolves everything relative to [projectRoot] plus the running directory.
  static String locateProjectRoot([String? startFrom]) {
    final candidates = <String>[
      if (startFrom != null && startFrom.trim().isNotEmpty) startFrom,
      Directory.current.path,
    ];
    final scriptDirectory = _scriptDirectory();
    if (scriptDirectory != null) candidates.add(scriptDirectory);

    for (final candidate in candidates) {
      final found = _searchUpwards(candidate);
      if (found != null) return found;
    }

    return _abs(startFrom ?? Directory.current.path);
  }

  /// Creates [dataDirectory], [originDirectory], [cacheDirectory] and
  /// [tempDirectory] when missing.
  Future<void> ensureDirectories() async {
    for (final dir in <Directory>[
      dataDirectory,
      originDirectory,
      cacheDirectory,
      tempDirectory,
    ]) {
      if (!dir.existsSync()) {
        await dir.create(recursive: true);
      }
    }
  }

  /// Throws when the configuration is internally inconsistent.
  void validate() {
    _checkPort(port, 'port');
    _checkPort(originPort, 'origin-port');

    if (!isEphemeralPort(port) && port == originPort) {
      throw ArgumentError(
        'port and origin-port must differ, but both are $port. '
        'Pass --origin-port to change the simulated origin.',
      );
    }
    if (chunkSize < 4096) {
      throw ArgumentError(
        'chunk-size must be at least 4096 bytes (got $chunkSize).',
      );
    }
    if (maxCacheBytes != 0 && maxCacheBytes < chunkSize * 2) {
      throw ArgumentError(
        'max-cache-bytes ($maxCacheBytes) must be 0 (unlimited) or at least '
        'twice chunk-size (${chunkSize * 2}).',
      );
    }
    if (maxConcurrentUpstream < 1) {
      throw ArgumentError(
        'max-concurrent-upstream must be at least 1 '
        '(got $maxConcurrentUpstream).',
      );
    }
    if (prefetchAhead < 0) {
      throw ArgumentError('prefetch-ahead must not be negative.');
    }
    if (originThrottleBytesPerSecond < 0) {
      throw ArgumentError('origin-throttle must not be negative.');
    }
    if (upstreamTimeout <= Duration.zero) {
      throw ArgumentError('upstream-timeout must be positive.');
    }
  }

  /// Returns a copy with individual fields replaced.
  ///
  /// Uses a sentinel so [ffmpegPath] can be explicitly cleared with `null`.
  Config copyWith({
    Object? port = _unset,
    Object? originPort = _unset,
    Object? logLevel = _unset,
    Object? colorizeLogs = _unset,
    Object? ffmpegPath = _unset,
  }) {
    final next = Config._(
      projectRoot: projectRoot,
      bindAddress: bindAddress,
      port: identical(port, _unset) ? this.port : port as int,
      originBindAddress: originBindAddress,
      originPort: identical(originPort, _unset)
          ? this.originPort
          : originPort as int,
      dataDirPath: dataDirPath,
      cacheDirPath: cacheDirPath,
      tempDirPath: tempDirPath,
      originDirPath: originDirPath,
      chunkSize: chunkSize,
      maxCacheBytes: maxCacheBytes,
      maxConcurrentUpstream: maxConcurrentUpstream,
      prefetchAhead: prefetchAhead,
      originThrottleBytesPerSecond: originThrottleBytesPerSecond,
      upstreamTimeout: upstreamTimeout,
      connectTimeout: connectTimeout,
      continueAfterDisconnect: continueAfterDisconnect,
      logLevel: identical(logLevel, _unset)
          ? this.logLevel
          : logLevel as LogLevel,
      colorizeLogs: identical(colorizeLogs, _unset)
          ? this.colorizeLogs
          : colorizeLogs as bool,
      ffmpegPath: identical(ffmpegPath, _unset)
          ? this.ffmpegPath
          : ffmpegPath as String?,
    );
    next.validate();
    return next;
  }

  /// Log-friendly snapshot of the effective settings.
  Map<String, Object?> describe() => <String, Object?>{
    'projectRoot': projectRoot,
    'app': '$bindAddress:$port',
    'origin': '$originBindAddress:$originPort',
    'dataDir': dataDirPath,
    'cacheDir': cacheDirPath,
    'chunkSize': formatByteSize(chunkSize),
    'maxCacheBytes': maxCacheBytes == 0
        ? 'unlimited'
        : formatByteSize(maxCacheBytes),
    'maxConcurrentUpstream': maxConcurrentUpstream,
    'prefetchAhead': prefetchAhead,
    'originThrottle': originThrottleBytesPerSecond == 0
        ? 'unlimited'
        : '${formatByteSize(originThrottleBytesPerSecond)}/s',
    'continueAfterDisconnect': continueAfterDisconnect,
    'logLevel': logLevel.name,
    'ffmpeg': ffmpegPath ?? '(auto)',
  };

  @override
  String toString() =>
      'Config(app: $bindAddress:$port, origin: $originBindAddress:$originPort, '
      'cache: $cacheDirPath)';

  /// Whether [value] requests an OS-assigned port.
  static bool isEphemeralPort(int value) => value == 0;

  // ---------------------------------------------------------------------------
  // CLI schema
  // ---------------------------------------------------------------------------

  /// Options shared by both entry points.
  static void addCommonOptions(ArgParser parser) {
    parser
      ..addOption(
        'project-root',
        valueHelp: 'DIR',
        help: 'Directory containing pubspec.yaml. Defaults to auto-detection.',
      )
      ..addOption(
        'data-dir',
        valueHelp: 'DIR',
        help: 'Root for origin/cache/tmp data (default: <project-root>/data).',
      )
      ..addOption(
        'cache-dir',
        valueHelp: 'DIR',
        help: 'Disk cache directory (default: <data-dir>/cache).',
      )
      ..addOption(
        'ffmpeg',
        valueHelp: 'PATH',
        help:
            'ffmpeg executable. Defaults to \$FFMPEG_PATH, then '
            'tools/ffmpeg/ffmpeg.exe.',
      )
      ..addOption(
        'log-level',
        valueHelp: 'LEVEL',
        allowed: <String>['debug', 'info', 'warn', 'error'],
        help: 'Minimum log severity (default: info).',
      )
      ..addFlag(
        'verbose',
        abbr: 'v',
        negatable: false,
        help: 'Shortcut for --log-level=debug.',
      )
      ..addFlag(
        'color',
        defaultsTo: true,
        help: 'Use ANSI colors in log output. Pass --no-color to disable.',
      )
      ..addFlag(
        'help',
        abbr: 'h',
        negatable: false,
        help: 'Print this usage information.',
      );
  }

  /// Options only meaningful for `bin/server.dart`.
  static void addServerOptions(ArgParser parser) {
    parser
      ..addOption(
        'bind',
        valueHelp: 'ADDR',
        help: 'App server address (default: $kDefaultBindAddress).',
      )
      ..addOption(
        'port',
        abbr: 'p',
        valueHelp: 'PORT',
        help: 'App server port (default: $kDefaultPort, 0 = ephemeral).',
      )
      ..addOption(
        'origin-bind',
        valueHelp: 'ADDR',
        help: 'Simulated origin address (default: $kDefaultOriginBindAddress).',
      )
      ..addOption(
        'origin-port',
        valueHelp: 'PORT',
        help:
            'Simulated origin port (default: $kDefaultOriginPort, '
            '0 = ephemeral).',
      )
      ..addOption(
        'chunk-size',
        valueHelp: 'SIZE',
        help:
            'Cache chunk size, e.g. 256K or 1M '
            '(default: ${kDefaultChunkSize ~/ (1 << 20)}M).',
      )
      ..addOption(
        'max-cache-bytes',
        valueHelp: 'SIZE',
        help: 'Cache budget before LRU eviction, 0 = unlimited (default: 2G).',
      )
      ..addOption(
        'max-concurrent-upstream',
        valueHelp: 'N',
        help:
            'Parallel upstream range requests '
            '(default: $kDefaultMaxConcurrentUpstream).',
      )
      ..addOption(
        'prefetch-ahead',
        valueHelp: 'N',
        help:
            'Speculatively fetch N chunks ahead of the current read '
            '(default: 0).',
      )
      ..addOption(
        'origin-throttle',
        valueHelp: 'SIZE',
        help:
            'Throttle the simulated origin, e.g. 2M. '
            '0 = unlimited (default: 0).',
      )
      ..addOption(
        'storage',
        valueHelp: 'BACKEND',
        allowed: <String>['auto', 'local', 'cos'],
        help:
            'Where media is read from. auto uses COS when its credentials are '
            'present, otherwise the local directory plus the simulated origin '
            '(default: auto).',
      )
      ..addOption(
        'upstream-timeout',
        valueHelp: 'SECONDS',
        help: 'Timeout for a single upstream range request (default: 30).',
      )
      ..addFlag(
        'continue-after-disconnect',
        defaultsTo: true,
        help: 'Keep filling cache chunks after the browser disconnects.',
      );
  }

  /// Options only meaningful for `bin/pipeline.dart`.
  static void addPipelineOptions(ArgParser parser) {
    parser
      ..addOption(
        'input',
        abbr: 'i',
        valueHelp: 'FILE',
        help: 'Source video to transcode.',
      )
      ..addOption(
        'key',
        abbr: 'k',
        valueHelp: 'KEY',
        help: 'Destination object key, e.g. clips/demo.mp4.',
      )
      ..addFlag(
        'demo',
        negatable: false,
        help: 'Synthesize a test clip with ffmpeg instead of reading --input.',
      )
      ..addOption(
        'demo-duration',
        valueHelp: 'SECONDS',
        help: 'Duration of the synthesized clip (default: 12).',
      )
      ..addOption(
        'crf',
        valueHelp: 'N',
        help: 'libx264 CRF, lower is better quality (default: 23).',
      )
      ..addOption(
        'preset',
        valueHelp: 'NAME',
        allowed: const <String>[
          'ultrafast',
          'superfast',
          'veryfast',
          'faster',
          'fast',
          'medium',
          'slow',
          'slower',
          'veryslow',
          'placebo',
        ],
        help: 'libx264 preset (default: veryfast).',
      )
      ..addOption(
        'storage',
        valueHelp: 'BACKEND',
        allowed: <String>['auto', 'local', 'cos'],
        help:
            'Where to publish. auto picks COS when its credentials are '
            'present, otherwise the local directory (default: auto).',
      )
      ..addOption(
        'out-dir',
        valueHelp: 'DIR',
        help: 'Where the transcoded file is written (default: <data-dir>/tmp).',
      )
      ..addFlag(
        'keep-transcoded',
        defaultsTo: false,
        help: 'Keep the local transcoded file after upload.',
      )
      ..addFlag(
        'list',
        negatable: false,
        help: 'List objects in the storage backend and exit.',
      );
  }

  /// Parser for `bin/server.dart`.
  static ArgParser buildServerParser() {
    final parser = ArgParser(usageLineLength: 92);
    addCommonOptions(parser);
    addServerOptions(parser);
    return parser;
  }

  /// Parser for `bin/pipeline.dart`.
  static ArgParser buildPipelineParser() {
    final parser = ArgParser(usageLineLength: 92);
    addCommonOptions(parser);
    addPipelineOptions(parser);
    return parser;
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  static String _resolveProjectRoot({
    required String? explicit,
    required Map<String, String> environment,
  }) {
    final requested =
        explicit ?? _envString(environment, 'PROXY_VIDEO_PROJECT_ROOT');
    if (requested == null) return locateProjectRoot();

    final candidate = Directory(_abs(requested));
    if (!candidate.existsSync()) {
      throw ArgumentError('project-root does not exist: ${candidate.path}');
    }
    return p.normalize(candidate.path);
  }

  static String? _searchUpwards(String start) {
    var dir = _abs(start);
    while (true) {
      if (File(p.join(dir, 'pubspec.yaml')).existsSync()) return dir;
      final parent = p.dirname(dir);
      if (parent == dir) return null;
      dir = parent;
    }
  }

  static String? _scriptDirectory() {
    try {
      final script = Platform.script;
      if (script.scheme != 'file') return null;
      final path = script.toFilePath();
      return path.isEmpty ? null : p.dirname(path);
    } on Object {
      return null;
    }
  }

  static String _abs(String path) => p.normalize(p.absolute(path));

  static void _checkPort(int value, String name) {
    if (value < 0 || value > 65535) {
      throw ArgumentError('$name must be between 0 and 65535 (got $value).');
    }
  }

  static bool _isLoopback(String address) {
    final normalized = address.trim().toLowerCase();
    if (normalized == 'localhost' || normalized == '::1') return true;
    final parsed = InternetAddress.tryParse(normalized);
    return parsed != null && parsed.isLoopback;
  }

  /// Reads an option only when the active parser declares it.
  static String? _optString(ArgResults args, String name) {
    if (!args.options.contains(name)) return null;
    final value = args[name];
    return value is String && value.trim().isNotEmpty ? value.trim() : null;
  }

  /// Reads an integer option. `package:args` hands back strings for
  /// `addOption`, so both representations are accepted.
  static int? _optInt(ArgResults args, String name) {
    if (!args.options.contains(name)) return null;
    final value = args[name];
    if (value is int) return value;
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed == null) {
        throw FormatException('--$name must be an integer, got "$value".');
      }
      return parsed;
    }
    return null;
  }

  static bool? _optBool(ArgResults args, String name) {
    if (!args.options.contains(name)) return null;
    final value = args[name];
    return value is bool ? value : null;
  }

  static int _sizeOption(
    ArgResults args,
    String name,
    Map<String, String> environment,
    String envKey,
    int fallback,
  ) {
    final fromArgs = _optString(args, name);
    if (fromArgs != null) return parseByteSize(fromArgs, label: '--$name');
    final fromEnv = _envString(environment, envKey);
    if (fromEnv != null) return parseByteSize(fromEnv, label: envKey);
    return fallback;
  }

  static String? _envString(Map<String, String> environment, String key) {
    final value = environment[key]?.trim();
    return (value == null || value.isEmpty) ? null : value;
  }

  static int _envInt(
    Map<String, String> environment,
    String key,
    int fallback,
  ) {
    final raw = _envString(environment, key);
    if (raw == null) return fallback;
    final parsed = int.tryParse(raw);
    if (parsed == null) {
      throw FormatException(
        'Environment variable $key must be an integer, got "$raw".',
      );
    }
    return parsed;
  }
}
