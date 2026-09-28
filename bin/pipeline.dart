import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:proxy_video/proxy_video.dart';

/// Transcodes a local video with ffmpeg and publishes it for the Range proxy.
///
/// The run is four steps: locate and verify ffmpeg, inspect the input so
/// progress can be reported as a percentage, encode a faststart MP4, then
/// upload it to the configured backend.
///
/// Publishing is deliberately separate from serving. `bin/server.dart` only
/// reads objects over HTTP, so the same upload works unchanged against a real
/// CDN, and the proxy never needs to know which backend sits behind the URL.
Future<void> main(List<String> arguments) async {
  final parser = Config.buildPipelineParser();

  final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (error) {
    stderr
      ..writeln('error: ${error.message}')
      ..writeln(_usage(parser));
    exitCode = exitUsage;
    return;
  }

  if (cliFlag(args, 'help')) {
    stdout.writeln(_usage(parser));
    return;
  }

  try {
    exitCode = await _execute(args);
  } on Object catch (error, stackTrace) {
    stderr.writeln('error: $error');
    if (Logger.level == LogLevel.debug) stderr.writeln(stackTrace);
    exitCode = exitFailure;
  }
}

Future<int> _execute(ArgResults args) async {
  final log = rootLogger;

  final Config config;
  try {
    config = Config.fromArgs(args);
  } on ArgumentError catch (error) {
    stderr.writeln('error: ${error.message}');
    return exitUsage;
  } on FormatException catch (error) {
    stderr.writeln('error: ${error.message}');
    return exitUsage;
  }

  Logger.configure(level: config.logLevel, colorEnabled: config.colorizeLogs);

  final Storage storage;
  try {
    storage = _buildStorage(config, args, log);
  } on FormatException catch (error) {
    stderr.writeln('error: ${error.message}');
    return exitUsage;
  }

  try {
    if (cliFlag(args, 'list')) {
      await _listObjects(storage);
      return exitSuccess;
    }
    return await _transcodeAndUpload(config, args, storage, log);
  } on CliUsageException catch (error) {
    stderr.writeln('error: ${error.message}');
    return exitUsage;
  } on FfmpegNotFoundException catch (error) {
    stderr.writeln(error);
    return exitFailure;
  } on FfmpegException catch (error) {
    stderr.writeln(error);
    return exitFailure;
  } on StorageException catch (error) {
    stderr.writeln('error: $error');
    return exitFailure;
  } on FileSystemException catch (error) {
    stderr.writeln('error: ${error.message} (${error.path ?? '-'})');
    return exitFailure;
  } finally {
    await storage.close();
  }
}

/// Picks the storage backend.
///
/// `auto` prefers COS when its credentials are present. Without a registered
/// [`CosClientFactory`] a COS backend fails loudly on first use rather than
/// silently dropping uploads, so `--storage local` is the escape hatch.
Storage _buildStorage(Config config, ArgResults args, Logger log) {
  final mode =
      cliEnum(args, 'storage', <String>['auto', 'local', 'cos']) ?? 'auto';

  if (mode != 'local') {
    final cos = CosStorage.tryFromEnvironment(Platform.environment, log: log);
    if (cos != null) {
      log.info('publishing to COS');
      return cos;
    }
    if (mode == 'cos') {
      throw FormatException(
        '--storage cos was requested but no COS credentials are present. Set '
        '${CosCredentials.requiredEnvironmentKeys.join(', ')}.',
      );
    }
  }

  return LocalDirStorage(
    root: config.originDirectory,
    originBaseUri: config.originBaseUri,
    log: log,
  );
}

Future<int> _transcodeAndUpload(
  Config config,
  ArgResults args,
  Storage storage,
  Logger log,
) async {
  final demo = cliFlag(args, 'demo');
  final input = cliString(args, 'input');

  if (demo && input != null) {
    throw const CliUsageException('--demo and --input are mutually exclusive.');
  }
  if (!demo && input == null) {
    throw const CliUsageException(
      'Pass --input <file> or --demo to synthesize a clip.',
    );
  }
  if (input != null && !File(input).existsSync()) {
    throw CliUsageException('--input "$input" does not exist.');
  }

  final crf = cliInt(args, 'crf', 23);
  if (crf < 0 || crf > 51) {
    throw CliUsageException('--crf must be between 0 and 51, got $crf.');
  }

  final demoSeconds = cliInt(args, 'demo-duration', 12);
  if (demoSeconds < 1) {
    throw const CliUsageException('--demo-duration must be at least 1 second.');
  }

  final options = TranscodeOptions(
    crf: crf,
    preset: cliString(args, 'preset') ?? 'veryfast',
  );

  final key = _resolveKey(cliString(args, 'key'), demo ? 'demo' : input!);

  await config.ensureDirectories();

  final locator = FfmpegLocator(
    explicitPath: config.ffmpegPath,
    projectRoot: config.projectRoot,
  );
  final executable = locator.resolve();
  log.info(
    'using ffmpeg',
    fields: <String, Object?>{
      'executable': executable,
      'version': await locator.version(executable),
    },
  );

  final outDir = cliString(args, 'out-dir') ?? config.tempDirPath;
  await Directory(outDir).create(recursive: true);
  final outputPath = p.join(outDir, p.basename(key));

  final Duration total;
  if (demo) {
    total = Duration(seconds: demoSeconds);
  } else {
    final info = await FfmpegProbe(executable: executable).probe(input!);
    total = info.duration ?? Duration.zero;
    log.info(
      'inspected input',
      fields: <String, Object?>{
        'input': info.path,
        'durationMs': info.duration?.inMilliseconds,
        'video': info.videoCodec,
        'audio': info.audioCodec,
        'resolution': info.resolution,
      },
    );
  }

  final progress = _ProgressPrinter(out: stdout, enabled: stdout.hasTerminal);
  final transcoder = Transcoder(executable: executable, log: log);

  final result = demo
      ? await transcoder.synthesizeDemo(
          output: outputPath,
          duration: total,
          options: options,
          onProgress: progress.report,
        )
      : await transcoder.transcode(
          input: input!,
          output: outputPath,
          options: options,
          totalDuration: total,
          onProgress: progress.report,
        );
  progress.finish();

  final uploaded = await storage.putFile(key, File(result.path));

  stdout
    ..writeln()
    ..writeln(
      'Published ${uploaded.key} (${formatByteSize(uploaded.size)}, encoded in '
      '${(result.elapsed.inMilliseconds / 1000).toStringAsFixed(1)}s)',
    )
    ..writeln('  origin : ${uploaded.url}')
    ..writeln(
      '  play   : ${config.appBaseUri.replace(pathSegments: <String>['play', ...key.split('/')])}',
    );

  if (!cliFlag(args, 'keep-transcoded')) {
    await File(result.path).delete();
  }

  return exitSuccess;
}

Future<void> _listObjects(Storage storage) async {
  final objects = await storage.list();
  if (objects.isEmpty) {
    stdout.writeln('No objects are published yet.');
    return;
  }

  for (final object in objects) {
    stdout.writeln('${formatByteSize(object.size).padLeft(12)}  ${object.key}');
  }
  stdout.writeln('${objects.length} object(s).');
}

/// Derives the destination key, falling back to the source file name.
String _resolveKey(String? requested, String source) {
  final candidate = requested ?? _defaultKeyFor(source);
  final safeKey = sanitizeKey(candidate);
  if (safeKey == null) {
    throw CliUsageException(
      '--key "$candidate" is not a usable key. Use letters, digits, ".", "_" '
      'and "-", separated by "/", for example clips/demo.mp4.',
    );
  }
  return safeKey;
}

String _defaultKeyFor(String sourcePath) {
  final base = p.basenameWithoutExtension(sourcePath);
  final cleaned = base
      .replaceAll(RegExp('[^A-Za-z0-9._-]'), '_')
      .replaceFirst(RegExp('^[^A-Za-z0-9]+'), '');
  return '${cleaned.isEmpty ? 'video' : cleaned}.mp4';
}

String _usage(ArgParser parser) =>
    '''
Transcode a local video with ffmpeg and publish it for the Range proxy.

Usage: dart run bin/pipeline.dart [options]

${parser.usage}

Examples:
  dart run bin/pipeline.dart --demo --key demo.mp4
  dart run bin/pipeline.dart --input movie.mov --key clips/movie.mp4
  dart run bin/pipeline.dart --list

Then start the proxy with: dart run bin/server.dart''';

/// Renders transcode progress on a single, rewritten terminal line.
///
/// Skipped when stdout is redirected, so piping the CLI into a file or a CI log
/// does not fill up with carriage returns.
class _ProgressPrinter {
  _ProgressPrinter({required IOSink out, required this.enabled}) : _out = out;

  static const Duration _minimumInterval = Duration(milliseconds: 250);
  static const int _lineWidth = 42;

  final IOSink _out;
  final bool enabled;

  Duration _lastShown = Duration.zero;
  bool _wroteAnything = false;

  void report(TranscodeProgress progress) {
    if (!enabled) return;
    if (!progress.finished &&
        progress.position - _lastShown < _minimumInterval) {
      return;
    }

    _lastShown = progress.position;
    final fraction = progress.fraction;
    final percent = fraction == null
        ? '  --  '
        : (fraction * 100).toStringAsFixed(1).padLeft(5);
    final speed = progress.speed == null
        ? ''
        : '  ${progress.speed!.toStringAsFixed(2)}x';

    _out.write('\r  encoding $percent%$speed   ');
    _wroteAnything = true;
  }

  /// Clears the progress line so following output starts on a clean row.
  void finish() {
    if (!enabled || !_wroteAnything) return;
    _out.write('\r${' ' * _lineWidth}\r');
  }
}
