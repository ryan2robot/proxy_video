import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Base class for ffmpeg failures.
class FfmpegException implements Exception {
  const FfmpegException(this.message, {this.details});

  /// What went wrong.
  final String message;

  /// Captured ffmpeg diagnostics, when there are any.
  final String? details;

  @override
  String toString() {
    final details = this.details;
    if (details == null || details.isEmpty) {
      return 'FfmpegException: $message';
    }
    return 'FfmpegException: $message\n$details';
  }
}

/// Raised when no usable ffmpeg executable can be found.
class FfmpegNotFoundException extends FfmpegException {
  const FfmpegNotFoundException(this.searched)
    : super('No ffmpeg executable could be found.');

  /// Every location that was tried, in order.
  final List<String> searched;

  @override
  String toString() {
    final buffer = StringBuffer()
      ..writeln('FfmpegNotFoundException: no ffmpeg executable found.')
      ..writeln('Searched:');
    for (final candidate in searched) {
      buffer.writeln('  - $candidate');
    }
    buffer.write(
      'Pass --ffmpeg <path>, set ${FfmpegLocator.environmentVariable}, or put '
      'an ffmpeg build in <project-root>/${FfmpegLocator.bundleDirectory}.',
    );
    return buffer.toString();
  }
}

/// Locates the ffmpeg binary this machine should use.
///
/// Resolution order, highest priority first:
///
/// 1. an explicit path (the `--ffmpeg` flag),
/// 2. `$FFMPEG_PATH`,
/// 3. `<project-root>/tools/ffmpeg/ffmpeg[.exe]`, where the bundle lives,
/// 4. `ffmpeg` on `PATH`.
///
/// Nothing is guessed silently: when every option fails the raised error lists
/// exactly what was tried, which is the difference between a fixable setup
/// problem and a mysterious crash.
class FfmpegLocator {
  const FfmpegLocator({
    required this.projectRoot,
    this.explicitPath,
    this.environment,
  });

  /// Environment variable that overrides the bundled binary.
  static const String environmentVariable = 'FFMPEG_PATH';

  /// Directory, relative to the project root, holding the bundled binary.
  static const String bundleDirectory = 'tools/ffmpeg';

  /// Platform-specific executable name.
  static String get executableName =>
      Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';

  /// Directory containing `pubspec.yaml`.
  final String projectRoot;

  /// Path supplied by the operator, if any.
  final String? explicitPath;

  /// Environment to read from; defaults to [Platform.environment].
  final Map<String, String>? environment;

  Map<String, String> get _environment => environment ?? Platform.environment;

  /// Where the bundled binary is expected to live.
  String get bundledPath =>
      p.join(projectRoot, 'tools', 'ffmpeg', executableName);

  /// Filesystem paths tried, in priority order.
  List<String> get fileCandidates => <String>[
    if (_nonEmpty(explicitPath) case final String explicit) _absolute(explicit),
    if (_nonEmpty(_environment[environmentVariable]) case final String fromEnv)
      _absolute(fromEnv),
    bundledPath,
    // Accept an extension-less copy next to the Windows binary, which is what a
    // cross-platform checkout tends to produce.
    p.join(projectRoot, 'tools', 'ffmpeg', 'ffmpeg'),
  ];

  /// Returns the ffmpeg path to run.
  ///
  /// Throws [FfmpegNotFoundException] listing every candidate when none exists.
  String resolve() {
    final searched = <String>[];

    for (final candidate in fileCandidates) {
      searched.add(candidate);
      if (File(candidate).existsSync()) return candidate;
    }

    for (final command in <String>[executableName, 'ffmpeg']) {
      searched.add('$command (on PATH)');
      final found = _searchPath(command);
      if (found != null) return found;
    }

    throw FfmpegNotFoundException(searched);
  }

  /// Runs `<executable> -version` and returns its first output line.
  ///
  /// Verifying the binary is worth the extra process: a truncated download or a
  /// wrong architecture otherwise shows up much later as an opaque transcode
  /// failure.
  Future<String> version(String executable) async {
    final ProcessResult result;
    try {
      result = await Process.run(
        executable,
        <String>['-version'],
        stdoutEncoding: null,
        stderrEncoding: null,
      );
    } on ProcessException catch (error) {
      throw FfmpegException(
        'could not run "$executable"',
        details: error.toString(),
      );
    }

    final output = _decode(result);
    if (result.exitCode != 0 || output.trim().isEmpty) {
      throw FfmpegException(
        '"$executable -version" exited with code ${result.exitCode}',
        details: output.trim(),
      );
    }

    return output.split('\n').first.trim();
  }

  String? _searchPath(String command) {
    final raw = _pathVariable();
    if (raw == null) return null;

    final separator = Platform.isWindows ? ';' : ':';
    for (final entry in raw.split(separator)) {
      // Windows PATH entries are sometimes quoted.
      final directory = entry.trim().replaceAll('"', '');
      if (directory.isEmpty) continue;

      final candidate = p.join(directory, command);
      if (File(candidate).existsSync()) return p.normalize(candidate);
    }
    return null;
  }

  /// Reads `PATH` case-insensitively; Windows reports it as `Path`.
  String? _pathVariable() {
    for (final entry in _environment.entries) {
      if (entry.key.toUpperCase() == 'PATH') return entry.value;
    }
    return null;
  }

  static String _absolute(String path) => p.normalize(p.absolute(path));

  static String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  static String _decode(ProcessResult result) {
    String read(Object? stream) {
      if (stream is List<int>) return utf8.decode(stream, allowMalformed: true);
      return stream?.toString() ?? '';
    }

    return '${read(result.stdout)}\n${read(result.stderr)}';
  }
}
