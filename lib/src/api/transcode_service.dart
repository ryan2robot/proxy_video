import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../logger.dart';
import '../media/ffmpeg_locator.dart';
import '../media/ffmpeg_probe.dart';
import '../media/transcoder.dart';
import '../storage/storage.dart';

/// Where a job is in its life cycle.
enum JobStatus {
  /// Waiting for the queue.
  queued,

  /// Currently probing, encoding or uploading.
  running,

  /// Published to storage.
  done,

  /// Stopped by an error; see [TranscodeJob.message].
  failed,
}

/// One transcode-and-publish request.
class TranscodeJob {
  TranscodeJob({
    required this.id,
    required this.key,
    this.input,
    this.isDemo = false,
    this.duration,
    this.options = const TranscodeOptions(),
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// Identifier used by `/api/jobs/<id>`.
  final String id;

  /// Destination object key.
  final String key;

  /// Local source file; absent for a synthesised clip.
  final String? input;

  /// Whether the clip is generated rather than read from disk.
  final bool isDemo;

  /// Duration requested for a synthesised clip.
  final Duration? duration;

  /// Encoding settings.
  final TranscodeOptions options;

  /// When the job was accepted.
  final DateTime createdAt;

  /// Current state.
  JobStatus status = JobStatus.queued;

  /// Coarse phase: `preparing`, `probing`, `encoding`, `uploading`, `done`.
  String phase = 'queued';

  /// Encoding completion in `[0, 1]`, when known.
  double? progress;

  /// Failure description, when [status] is [JobStatus.failed].
  String? message;

  /// Object published on success.
  ObjectStat? published;

  /// Size of the published object, when known.
  int? outputBytes;

  /// When the job left the queue.
  DateTime? finishedAt;

  /// Whether the job will not change state again.
  bool get isFinished => status == JobStatus.done || status == JobStatus.failed;

  /// JSON projection for the API.
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'key': key,
    'input': input,
    'demo': isDemo,
    'status': status.name,
    'phase': phase,
    'progress': progress,
    'outputBytes': outputBytes,
    'publishedUrl': published?.url?.toString(),
    'createdAt': createdAt.toUtc().toIso8601String(),
    if (finishedAt != null) 'finishedAt': finishedAt!.toUtc().toIso8601String(),
    if (message != null) 'message': message,
  };
}

/// Runs transcode-and-publish jobs, one at a time.
///
/// Serialising them is deliberate: several concurrent x264 encodes would starve
/// the CPU that the proxy needs to keep serving ranges, so the queue trades a
/// little latency for a service that stays responsive while it works.
class TranscodeService {
  TranscodeService({required this.config, required this.storage, Logger? log})
    : _log = (log ?? rootLogger).child('transcode');

  /// Resolved runtime settings.
  final Config config;

  /// Backend the finished file is published to.
  final Storage storage;

  final Logger _log;
  final Map<String, TranscodeJob> _jobs = <String, TranscodeJob>{};
  final List<String> _queue = <String>[];

  bool _draining = false;
  int _sequence = 0;

  /// Jobs in submission order, newest first.
  List<TranscodeJob> get jobs {
    final ordered = _jobs.values.toList(growable: false);
    return ordered.reversed.toList(growable: false);
  }

  /// Whether the worker is currently running a job.
  bool get isBusy => _draining;

  /// Number of jobs still queued (not counting the running one).
  int get queuedCount => _queue.length;

  /// Looks up a job by id.
  TranscodeJob? job(String id) => _jobs[id];

  /// Accepts a job and starts the worker if it is idle.
  TranscodeJob submit({
    required String key,
    String? input,
    bool isDemo = false,
    Duration? duration,
    TranscodeOptions options = const TranscodeOptions(),
  }) {
    final id = 'job-${++_sequence}';
    final job = TranscodeJob(
      id: id,
      key: key,
      input: input,
      isDemo: isDemo,
      duration: duration,
      options: options,
    );

    _jobs[id] = job;
    _queue.add(id);
    _log.info(
      'transcode queued',
      fields: <String, Object?>{'id': id, 'key': key, 'demo': isDemo},
    );

    unawaited(_drain());
    return job;
  }

  /// Waits until the queue is empty and the running job has finished.
  Future<void> whenIdle() async {
    while (_draining || _queue.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty) {
        final job = _jobs[_queue.removeAt(0)];
        if (job == null || job.isFinished) continue;
        await _run(job);
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _run(TranscodeJob job) async {
    job.status = JobStatus.running;
    try {
      await config.ensureDirectories();

      final executable = FfmpegLocator(
        explicitPath: config.ffmpegPath,
        projectRoot: config.projectRoot,
      ).resolve();
      final transcoder = Transcoder(executable: executable, log: _log);

      final Duration duration;
      if (job.isDemo) {
        duration = job.duration ?? const Duration(seconds: 12);
      } else {
        job.phase = 'probing';
        final info = await FfmpegProbe(
          executable: executable,
        ).probe(job.input!);
        duration = info.duration ?? Duration.zero;
        _log.info(
          'inspected input',
          fields: <String, Object?>{
            'id': job.id,
            'durationMs': info.duration?.inMilliseconds,
            'video': info.videoCodec,
            'audio': info.audioCodec,
          },
        );
      }

      job.phase = 'encoding';
      final outputPath = p.join(config.tempDirPath, p.basename(job.key));

      final result = job.isDemo
          ? await transcoder.synthesizeDemo(
              output: outputPath,
              duration: duration,
              options: job.options,
              onProgress: (TranscodeProgress progress) =>
                  job.progress = progress.fraction,
            )
          : await transcoder.transcode(
              input: job.input!,
              output: outputPath,
              options: job.options,
              totalDuration: duration,
              onProgress: (TranscodeProgress progress) =>
                  job.progress = progress.fraction,
            );

      job.phase = 'uploading';
      job.progress = 1;
      final stat = await storage.putFile(job.key, File(result.path));
      job.published = stat;
      job.outputBytes = stat.size;

      // The published copy is the one that matters; keeping the scratch file
      // would accumulate one duplicate of every upload.
      final scratch = File(result.path);
      if (scratch.existsSync()) await scratch.delete();

      job.status = JobStatus.done;
      job.phase = 'done';
      _log.info(
        'transcode finished',
        fields: <String, Object?>{
          'id': job.id,
          'key': job.key,
          'bytes': stat.size,
        },
      );
    } on Object catch (error, stackTrace) {
      job.status = JobStatus.failed;
      job.message = '$error';
      _log.error(
        'transcode failed',
        fields: <String, Object?>{'id': job.id, 'key': job.key, 'error': error},
        stackTrace: Logger.level == LogLevel.debug ? stackTrace : null,
      );
    } finally {
      job.finishedAt = DateTime.now();
    }
  }
}
