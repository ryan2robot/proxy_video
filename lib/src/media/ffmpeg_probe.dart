import 'dart:convert';
import 'dart:io';

import 'ffmpeg_locator.dart';

/// What ffmpeg reports about an input file.
class MediaInfo {
  const MediaInfo({
    required this.path,
    this.duration,
    this.videoCodec,
    this.audioCodec,
    this.resolution,
  });

  /// The inspected path.
  final String path;

  /// Total duration, when ffmpeg reported one.
  ///
  /// `null` for live or malformed inputs, where `Duration: N/A` is printed.
  final Duration? duration;

  /// Video codec name, e.g. `h264`.
  final String? videoCodec;

  /// Audio codec name, e.g. `aac`.
  final String? audioCodec;

  /// Frame size, e.g. `1920x1080`.
  final String? resolution;

  /// Whether the file carries a video stream.
  bool get hasVideo => videoCodec != null;

  /// Whether the file carries an audio stream.
  bool get hasAudio => audioCodec != null;

  @override
  String toString() =>
      'MediaInfo($path, duration: ${duration ?? 'unknown'}, '
      'video: ${videoCodec ?? '-'} $resolution, audio: ${audioCodec ?? '-'})';
}

/// Reads media metadata using the ffmpeg binary itself.
///
/// The bundle ships ffmpeg but no ffprobe, so this runs `ffmpeg -i <file>` with
/// no output target and parses the summary ffmpeg writes to stderr before
/// bailing out with "At least one output file must be specified". That non-zero
/// exit code is expected and therefore deliberately ignored: the summary is
/// printed either way.
class FfmpegProbe {
  const FfmpegProbe({required this.executable});

  /// The ffmpeg binary to invoke.
  final String executable;

  static final RegExp _durationPattern = RegExp(
    r'Duration:\s*(\d+):(\d{2}):(\d{2})\.(\d+)',
  );
  static final RegExp _videoPattern = RegExp(
    r'Stream #\d+:\d+.*?: Video:\s*([A-Za-z0-9_]+)',
  );
  static final RegExp _audioPattern = RegExp(
    r'Stream #\d+:\d+.*?: Audio:\s*([A-Za-z0-9_]+)',
  );
  static final RegExp _resolutionPattern = RegExp(r'(\d{2,5})x(\d{2,5})');

  /// Inspects [inputPath].
  ///
  /// Throws [FfmpegException] when ffmpeg cannot read the file as media, which
  /// is a hard error for the pipeline: transcoding an unreadable input would
  /// otherwise produce an empty file and a confusing failure much later.
  Future<MediaInfo> probe(String inputPath) async {
    final ProcessResult result;
    try {
      result = await Process.run(
        executable,
        <String>['-hide_banner', '-i', inputPath],
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
    final videoCodec = _videoPattern.firstMatch(output)?.group(1);
    final audioCodec = _audioPattern.firstMatch(output)?.group(1);

    if (videoCodec == null && audioCodec == null) {
      throw FfmpegException(
        'ffmpeg does not recognise "$inputPath" as media',
        details: output.trim(),
      );
    }

    return MediaInfo(
      path: inputPath,
      duration: _parseDuration(output),
      videoCodec: videoCodec,
      audioCodec: audioCodec,
      resolution: videoCodec == null
          ? null
          : _resolutionPattern.firstMatch(output)?.group(0),
    );
  }

  static Duration? _parseDuration(String output) {
    final match = _durationPattern.firstMatch(output);
    if (match == null) return null;

    // ffmpeg prints centiseconds ("00:00:12.03"); widening to microseconds
    // keeps sub-second accuracy for progress reporting.
    final fraction = match.group(4)!;
    return Duration(
      hours: int.parse(match.group(1)!),
      minutes: int.parse(match.group(2)!),
      seconds: int.parse(match.group(3)!),
      microseconds: int.parse(fraction.padRight(6, '0').substring(0, 6)),
    );
  }

  static String _decode(ProcessResult result) {
    String read(Object? stream) {
      if (stream is List<int>) return utf8.decode(stream, allowMalformed: true);
      return stream?.toString() ?? '';
    }

    return '${read(result.stdout)}\n${read(result.stderr)}';
  }
}
