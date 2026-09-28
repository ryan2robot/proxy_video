import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:proxy_video/proxy_video.dart';
import 'package:test/test.dart';

void main() {
  Logger.level = LogLevel.error;
  tearDownAll(Logger.reset);

  final projectRoot = Directory.current.path;
  final locator = FfmpegLocator(projectRoot: projectRoot);

  final String ffmpeg;
  try {
    ffmpeg = locator.resolve();
  } on FfmpegNotFoundException catch (error) {
    // A missing binary is a setup problem, not a test bug: report it plainly
    // instead of failing with something that looks like a code defect.
    test('ffmpeg binary is available', () => fail('$error'));
    return;
  }

  late Directory temp;
  setUp(
    () => temp = Directory.systemTemp.createTempSync('proxy_video_ffmpeg_'),
  );
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  group('FfmpegLocator', () {
    test('finds the bundled binary', () {
      expect(File(ffmpeg).existsSync(), isTrue);
      expect(ffmpeg, locator.bundledPath);
    });

    test('prefers an explicit path', () {
      final explicit = FfmpegLocator(
        projectRoot: p.join(projectRoot, 'does-not-exist'),
        explicitPath: ffmpeg,
        environment: const <String, String>{},
      );

      expect(explicit.resolve(), ffmpeg);
    });

    test('honours \$FFMPEG_PATH', () {
      final fromEnvironment = FfmpegLocator(
        projectRoot: p.join(projectRoot, 'does-not-exist'),
        environment: <String, String>{
          FfmpegLocator.environmentVariable: ffmpeg,
        },
      );

      expect(fromEnvironment.resolve(), ffmpeg);
    });

    test('lists every candidate when nothing is found', () {
      final missing = FfmpegLocator(
        projectRoot: p.join(projectRoot, 'no-such-project'),
        explicitPath: p.join(projectRoot, 'no-such-ffmpeg'),
        environment: const <String, String>{ffmpegPathAbsentVariable: ''},
      );

      expect(
        () => missing.resolve(),
        throwsA(
          isA<FfmpegNotFoundException>().having(
            (FfmpegNotFoundException e) => e.searched,
            'searched',
            contains(p.join(projectRoot, 'no-such-ffmpeg')),
          ),
        ),
      );
    });

    test('reports the version of the resolved binary', () async {
      expect(await locator.version(ffmpeg), contains('ffmpeg version'));
    });

    test('reports a clear error for a binary that cannot run', () async {
      final bogus = File(p.join(temp.path, 'not-ffmpeg.exe'))
        ..writeAsBytesSync(<int>[0, 1, 2, 3]);

      await expectLater(
        locator.version(bogus.path),
        throwsA(isA<FfmpegException>()),
      );
    });
  });

  group('Transcoder argument building', () {
    test('requests a faststart MP4 with machine readable progress', () {
      final args = Transcoder.buildArgs(input: 'in.mov', output: 'out.mp4');

      expect(args, containsAllInOrder(<String>['-i', 'in.mov']));
      expect(args, containsAllInOrder(<String>['-c:v', 'libx264']));
      expect(args, containsAllInOrder(<String>['-c:a', 'aac']));
      expect(args, containsAllInOrder(<String>['-movflags', '+faststart']));
      expect(args, containsAllInOrder(<String>['-progress', 'pipe:1']));
      expect(args, containsAllInOrder(<String>['-loglevel', 'error']));
      expect(args.last, 'out.mp4');
    });

    test('omits faststart when it is disabled', () {
      final args = Transcoder.buildArgs(
        input: 'in.mov',
        output: 'out.mp4',
        options: const TranscodeOptions(faststart: false),
      );

      expect(args, isNot(contains('+faststart')));
      expect(args, isNot(contains('-movflags')));
    });

    test('honours crf, preset and a width cap', () {
      final args = Transcoder.buildArgs(
        input: 'in.mov',
        output: 'out.mp4',
        options: const TranscodeOptions(
          crf: 30,
          preset: 'slow',
          maxWidth: 1280,
        ),
      );

      expect(args, containsAllInOrder(<String>['-crf', '30']));
      expect(args, containsAllInOrder(<String>['-preset', 'slow']));
      expect(args, containsAllInOrder(<String>['-vf', 'scale=1280:-2']));
    });
  });

  group('Transcoder', () {
    test('synthesizes a clip with the index ahead of the media data', () async {
      final output = p.join(temp.path, 'demo.mp4');
      final progress = <TranscodeProgress>[];

      final result = await Transcoder(executable: ffmpeg).synthesizeDemo(
        output: output,
        duration: const Duration(seconds: 3),
        onProgress: progress.add,
      );

      expect(File(output).existsSync(), isTrue);
      expect(result.size, greaterThan(0));
      expect(result.throughputBytesPerSecond, greaterThan(0));
      expect(progress, isNotEmpty);
      expect(progress.last.finished, isTrue);

      final bytes = await File(output).readAsBytes();
      final head = String.fromCharCodes(bytes.take(64 * 1024));
      final moov = head.indexOf('moov');
      final mdat = head.indexOf('mdat');

      expect(moov, isNonNegative);
      expect(mdat, isNonNegative);
      // The index must precede the payload: that is what lets a player compute
      // byte ranges without downloading the whole file first.
      expect(
        moov,
        lessThan(mdat),
        reason: 'faststart should move the moov atom in front of mdat',
      );
    });

    test('reports progress against the requested duration', () async {
      final output = p.join(temp.path, 'progress.mp4');
      final progress = <TranscodeProgress>[];

      await Transcoder(executable: ffmpeg).synthesizeDemo(
        output: output,
        duration: const Duration(seconds: 2),
        onProgress: progress.add,
      );

      final timed = progress.where((TranscodeProgress p) => p.total != null);
      expect(timed, isNotEmpty);
      expect(timed.last.fraction, closeTo(1.0, 0.1));
      expect(timed.every((TranscodeProgress p) => p.fraction! >= 0), isTrue);
      expect(timed.every((TranscodeProgress p) => p.fraction! <= 1), isTrue);
    });

    test('fails clearly when the input cannot be read', () async {
      await expectLater(
        Transcoder(executable: ffmpeg).transcode(
          input: p.join(temp.path, 'missing.mov'),
          output: p.join(temp.path, 'out.mp4'),
        ),
        throwsA(isA<FfmpegException>()),
      );
      expect(File(p.join(temp.path, 'out.mp4')).existsSync(), isFalse);
    });
  });

  group('FfmpegProbe', () {
    test('reads duration, codecs and resolution from a real file', () async {
      final output = p.join(temp.path, 'clip.mp4');
      await Transcoder(
        executable: ffmpeg,
      ).synthesizeDemo(output: output, duration: const Duration(seconds: 2));

      final info = await FfmpegProbe(executable: ffmpeg).probe(output);

      expect(info.hasVideo, isTrue);
      expect(info.hasAudio, isTrue);
      expect(info.videoCodec, 'h264');
      expect(info.audioCodec, 'aac');
      expect(info.resolution, '640x360');
      expect(info.duration, isNotNull);
      expect(info.duration!.inMilliseconds, closeTo(2000, 200));
    });

    test('fails clearly when the file does not exist', () async {
      await expectLater(
        FfmpegProbe(executable: ffmpeg).probe(p.join(temp.path, 'missing.mp4')),
        throwsA(isA<FfmpegException>()),
      );
    });

    test('fails clearly for a file that is not media', () async {
      final empty = File(p.join(temp.path, 'empty.mp4'))
        ..writeAsBytesSync(<int>[]);

      await expectLater(
        FfmpegProbe(executable: ffmpeg).probe(empty.path),
        throwsA(isA<FfmpegException>()),
      );
    });
  });
}

/// A variable name that is deliberately never set, used to prove the locator
/// falls through to "not found" instead of picking up the ambient environment.
const String ffmpegPathAbsentVariable = 'PROXY_VIDEO_TEST_UNSET_FFMPEG_PATH';
