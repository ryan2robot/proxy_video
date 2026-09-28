import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../logger.dart';
import 'ffmpeg_locator.dart';

/// Progress reported while a transcode runs.
class TranscodeProgress {
  const TranscodeProgress({
    required this.position,
    this.total,
    this.speed,
    this.finished = false,
  });

  /// How far into the input ffmpeg has encoded.
  final Duration position;

  /// Input duration, when it is known.
  final Duration? total;

  /// Encoding speed relative to realtime, e.g. `2.5` for 2.5x.
  final double? speed;

  /// Whether ffmpeg reported `progress=end`.
  final bool finished;

  /// Completion in `[0, 1]`, or `null` when the duration is unknown.
  double? get fraction {
    final total = this.total;
    if (total == null || total.inMicroseconds <= 0) return null;
    final value = position.inMicroseconds / total.inMicroseconds;
    return value.clamp(0.0, 1.0).toDouble();
  }

  @override
  String toString() {
    final percent = fraction == null
        ? '?'
        : '${(fraction! * 100).toStringAsFixed(1)}%';
    return 'TranscodeProgress($percent, pos: $position, speed: ${speed ?? '?'}x)';
  }
}

/// Tuning options for one transcode run.
class TranscodeOptions {
  const TranscodeOptions({
    this.videoCodec = 'libx264',
    this.audioCodec = 'aac',
    this.preset = 'veryfast',
    this.crf = 23,
    this.audioBitrateKbps = 128,
    this.audioChannels = 2,
    this.pixelFormat = 'yuv420p',
    this.faststart = true,
    this.maxWidth,
    this.overwrite = true,
  });

  /// Video encoder.
  final String videoCodec;

  /// Audio encoder.
  final String audioCodec;

  /// x264 speed/size tradeoff.
  final String preset;

  /// Constant rate factor; lower means better quality and a bigger file.
  final int crf;

  /// Audio bitrate in kbit/s.
  final int audioBitrateKbps;

  /// Audio channel count.
  final int audioChannels;

  /// Pixel format; `yuv420p` is what every browser can decode.
  final String pixelFormat;

  /// Whether to move the MP4 index (`moov`) in front of the media data.
  ///
  /// This is the flag that makes progressive playback work at all. Without it
  /// the index sits at the end of the file, so a player cannot work out which
  /// byte range holds the part it needs until the whole file has arrived —
  /// exactly the failure mode this proxy exists to avoid.
  final bool faststart;

  /// Downscales so the width does not exceed this, keeping the aspect ratio.
  final int? maxWidth;

  /// Whether to overwrite an existing output file.
  final bool overwrite;

  /// Arguments describing the output encoding.
  List<String> get encodingArgs => <String>[
    '-c:v',
    videoCodec,
    if (videoCodec == 'libx264') ...<String>['-preset', preset, '-crf', '$crf'],
    '-pix_fmt',
    pixelFormat,
    if (maxWidth != null) ...<String>['-vf', 'scale=$maxWidth:-2'],
    '-c:a',
    audioCodec,
    '-b:a',
    '${audioBitrateKbps}k',
    '-ac',
    '$audioChannels',
    if (faststart) ...<String>['-movflags', '+faststart'],
  ];
}

/// Outcome of a completed transcode.
class TranscodeResult {
  const TranscodeResult({
    required this.path,
    required this.size,
    required this.elapsed,
    this.stderr = '',
  });

  /// Path of the produced file.
  final String path;

  /// Size of the produced file in bytes.
  final int size;

  /// Wall-clock time the encode took.
  final Duration elapsed;

  /// Everything ffmpeg wrote to stderr, kept for diagnostics.
  final String stderr;

  /// Output bytes produced per second of wall-clock time.
  double get throughputBytesPerSecond {
    final micros = elapsed.inMicroseconds;
    if (micros <= 0) return 0;
    return size / (micros / Duration.microsecondsPerSecond);
  }

  @override
  String toString() =>
      'TranscodeResult($path, $size bytes in ${elapsed.inMilliseconds}ms)';
}

/// Runs ffmpeg to produce a web-playable MP4.
class Transcoder {
  Transcoder({required this.executable, Logger? log})
    : _log = (log ?? rootLogger).child('ffmpeg');

  /// The ffmpeg binary to invoke.
  final String executable;

  final Logger _log;

  /// Builds the argument list used to transcode [input] into [output].
  ///
  /// `-progress pipe:1` makes ffmpeg emit machine-readable progress on stdout
  /// while diagnostics stay on stderr, so the two never get mixed up.
  static List<String> buildArgs({
    required String input,
    required String output,
    TranscodeOptions options = const TranscodeOptions(),
  }) => <String>[
    '-hide_banner',
    '-nostdin',
    if (options.overwrite) '-y',
    '-i',
    input,
    ...options.encodingArgs,
    '-progress',
    'pipe:1',
    '-nostats',
    '-loglevel',
    'error',
    output,
  ];

  /// Transcodes [input] into [output].
  ///
  /// [totalDuration] is used only to turn ffmpeg's position reports into
  /// percentages; pass [FfmpegProbe]'s result for an accurate progress bar.
  Future<TranscodeResult> transcode({
    required String input,
    required String output,
    TranscodeOptions options = const TranscodeOptions(),
    Duration? totalDuration,
    void Function(TranscodeProgress progress)? onProgress,
  }) {
    return _run(
      buildArgs(input: input, output: output, options: options),
      outputPath: output,
      totalDuration: totalDuration,
      onProgress: onProgress,
    );
  }

  /// Produces a synthetic clip using ffmpeg's own generators.
  ///
  /// Lets the whole pipeline be exercised without a source file on the machine,
  /// which matters because "no media to try" is the usual reason a setup step
  /// goes unverified.
  Future<TranscodeResult> synthesizeDemo({
    required String output,
    Duration duration = const Duration(seconds: 12),
    TranscodeOptions options = const TranscodeOptions(),
    void Function(TranscodeProgress progress)? onProgress,
  }) {
    final seconds = (duration.inMicroseconds / Duration.microsecondsPerSecond)
        .toStringAsFixed(3);

    final args = <String>[
      '-hide_banner',
      '-nostdin',
      if (options.overwrite) '-y',
      '-f',
      'lavfi',
      '-i',
      'testsrc=duration=$seconds:size=640x360:rate=30',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440:duration=$seconds',
      ...options.encodingArgs,
      '-shortest',
      '-progress',
      'pipe:1',
      '-nostats',
      '-loglevel',
      'error',
      output,
    ];

    return _run(
      args,
      outputPath: output,
      totalDuration: duration,
      onProgress: onProgress,
    );
  }

  Future<TranscodeResult> _run(
    List<String> args, {
    required String outputPath,
    required Duration? totalDuration,
    required void Function(TranscodeProgress progress)? onProgress,
  }) async {
    _log.debug(
      'starting ffmpeg',
      fields: <String, Object?>{'output': outputPath},
    );

    final stopwatch = Stopwatch()..start();
    final Process process;
    try {
      process = await Process.start(executable, args);
    } on ProcessException catch (error) {
      throw FfmpegException(
        'could not start "$executable"',
        details: error.toString(),
      );
    }

    final diagnostics = StringBuffer();
    final stderrDone = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach((String line) => diagnostics.writeln(line));

    var position = Duration.zero;
    double? speed;

    final stdoutDone = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach((String line) {
          final separator = line.indexOf('=');
          if (separator <= 0) return;

          final key = line.substring(0, separator).trim();
          final value = line.substring(separator + 1).trim();

          switch (key) {
            case 'out_time':
              position = _parseClock(value) ?? position;
              onProgress?.call(
                TranscodeProgress(
                  position: position,
                  total: totalDuration,
                  speed: speed,
                ),
              );
            case 'speed':
              speed = _parseSpeed(value) ?? speed;
            case 'progress':
              if (value == 'end') {
                onProgress?.call(
                  TranscodeProgress(
                    position: position,
                    total: totalDuration,
                    speed: speed,
                    finished: true,
                  ),
                );
              }
          }
        });

    final exitCode = await process.exitCode;
    await Future.wait<void>(<Future<void>>[stderrDone, stdoutDone]);
    stopwatch.stop();

    final stderr = diagnostics.toString().trim();
    if (exitCode != 0) {
      throw FfmpegException(
        'ffmpeg exited with code $exitCode',
        details: stderr,
      );
    }

    final file = File(outputPath);
    if (!file.existsSync()) {
      throw FfmpegException(
        'ffmpeg reported success but $outputPath was not created',
        details: stderr,
      );
    }

    final result = TranscodeResult(
      path: outputPath,
      size: await file.length(),
      elapsed: stopwatch.elapsed,
      stderr: stderr,
    );

    _log.info(
      'transcode finished',
      fields: <String, Object?>{
        'output': outputPath,
        'bytes': result.size,
        'elapsedMs': result.elapsed.inMilliseconds,
      },
    );
    return result;
  }
}

final RegExp _clockPattern = RegExp(r'^(\d+):(\d{2}):(\d{2})(?:\.(\d+))?$');

/// Parses ffmpeg's `out_time=HH:MM:SS.ffffff` value.
Duration? _parseClock(String value) {
  final match = _clockPattern.firstMatch(value);
  if (match == null) return null;

  final fraction = match.group(4) ?? '0';
  return Duration(
    hours: int.parse(match.group(1)!),
    minutes: int.parse(match.group(2)!),
    seconds: int.parse(match.group(3)!),
    microseconds: int.parse(fraction.padRight(6, '0').substring(0, 6)),
  );
}

/// Parses ffmpeg's `speed=1.23x` value; `N/A` becomes `null`.
double? _parseSpeed(String value) {
  if (value.isEmpty || value == 'N/A') return null;
  final trimmed = value.endsWith('x')
      ? value.substring(0, value.length - 1)
      : value;
  return double.tryParse(trimmed);
}
