import 'dart:io';

import '../cache/disk_cache.dart';
import '../config.dart';
import '../logger.dart';
import '../media/transcoder.dart';
import '../proxy/media_proxy.dart';
import '../server/router.dart';
import '../storage/storage.dart';
import '../util/http_util.dart';
import 'transcode_service.dart';

/// JSON API and the couple of routes that are not the proxy itself.
///
/// Kept deliberately small and read-only in spirit: the only mutating calls are
/// "publish this file" and "drop this cache", both of which the operator
/// triggers from the UI on their own machine.
class ApiRoutes {
  ApiRoutes({
    required this.config,
    required this.cache,
    required this.storage,
    required this.proxy,
    required this.transcodes,
    Logger? log,
  }) : _log = (log ?? rootLogger).child('api');

  /// Resolved runtime settings.
  final Config config;

  /// Disk cache backing the proxy.
  final DiskCache cache;

  /// Where published media lives.
  final Storage storage;

  /// The proxy, used for its background-fill counters.
  final MediaProxy proxy;

  /// Transcode queue.
  final TranscodeService transcodes;

  final Logger _log;

  /// Registers every API route on [router].
  void register(Router router) {
    router.get('/healthz', _health);
    router.get('/api/media', _listMedia);
    router.get('/api/stats', _stats);
    router.get('/api/jobs', _listJobs);
    router.get('/api/jobs/:id', _oneJob);
    router.post('/api/transcode', _submitTranscode);
    router.post('/api/cache', _clearCache);
  }

  Future<void> _health(RequestContext context) => writeJson(context.response, {
    'status': 'ok',
    'app': config.appBaseUri.toString(),
    'origin': config.originBaseUri.toString(),
    'storage': storage.runtimeType.toString(),
    'cacheBytes': cache.trackedBytes,
    'backgroundFills': proxy.backgroundFillTotal,
  });

  /// Lists published objects, enriched with whatever is already cached.
  Future<void> _listMedia(RequestContext context) async {
    final objects = await storage.list();
    final stats = await cache.stats();

    final cached = <String, CacheEntryStats>{
      for (final entry in stats.entries) entry.key: entry,
    };

    await writeJson(context.response, <String, Object?>{
      'contentBase': '/media/',
      'objects': objects
          .map(
            (ObjectStat object) => <String, Object?>{
              'key': object.key,
              'size': object.size,
              'contentType': object.contentType,
              'etag': object.etag,
              'modifiedAt': object.lastModified?.toUtc().toIso8601String(),
              'url': object.url?.toString(),
              'playUrl': '/play/${_encodeKey(object.key)}',
              'streamUrl': '/media/${_encodeKey(object.key)}',
              if (cached[object.key] case final CacheEntryStats entry)
                'cache': entry.toJson(),
            },
          )
          .toList(growable: false),
    });
  }

  Future<void> _stats(RequestContext context) async {
    final key = queryString(context.uri, 'key');
    final stats = await cache.stats();

    if (key == null) {
      await writeJson(context.response, <String, Object?>{
        ...stats.toJson(),
        'backgroundFills': proxy.backgroundFillTotal,
        'jobs': <String, Object?>{
          'busy': transcodes.isBusy,
          'queued': transcodes.queuedCount,
        },
      });
      return;
    }

    CacheEntryStats? entry;
    for (final candidate in stats.entries) {
      if (candidate.key == key) {
        entry = candidate;
        break;
      }
    }

    if (entry == null) {
      await writeJson(context.response, <String, Object?>{
        'key': key,
        'known': false,
      });
      return;
    }

    await writeJson(context.response, <String, Object?>{
      ...entry.toJson(),
      'known': true,
      'upstreamInUse': stats.upstreamInUse,
      'upstreamCapacity': stats.upstreamCapacity,
    });
  }

  Future<void> _listJobs(RequestContext context) =>
      writeJson(context.response, <String, Object?>{
        'busy': transcodes.isBusy,
        'queued': transcodes.queuedCount,
        'jobs': transcodes.jobs
            .map((TranscodeJob job) => job.toJson())
            .toList(),
      });

  Future<void> _oneJob(RequestContext context) async {
    final job = transcodes.job(context.param('id'));
    if (job == null) {
      await writeJson(context.response, <String, Object?>{
        'error': 'unknown job',
        'id': context.param('id'),
      }, statusCode: HttpStatus.notFound);
      return;
    }
    await writeJson(context.response, job.toJson());
  }

  /// Accepts `{input, key, demo, duration, crf, preset}` and queues a job.
  Future<void> _submitTranscode(RequestContext context) async {
    final Map<String, Object?> body;
    try {
      body = await readJsonObject(context.request) ?? <String, Object?>{};
    } on FormatException catch (error) {
      await writeJson(context.response, <String, Object?>{
        'error': error.message,
      }, statusCode: HttpStatus.badRequest);
      return;
    }

    final rawInput = _string(body, 'input');
    final isDemo = body['demo'] == true || queryFlag(context.uri, 'demo');
    final demoOnly = rawInput == null;

    if (!isDemo && demoOnly) {
      await writeJson(context.response, <String, Object?>{
        'error':
            'provide "input" (an absolute path on this machine) or set "demo": true',
      }, statusCode: HttpStatus.badRequest);
      return;
    }

    if (rawInput != null && !File(rawInput).existsSync()) {
      await writeJson(context.response, <String, Object?>{
        'error': 'input file does not exist: $rawInput',
      }, statusCode: HttpStatus.badRequest);
      return;
    }

    final candidateKey =
        _string(body, 'key') ?? _defaultKeyFor(isDemo ? 'demo' : rawInput!);
    final key = sanitizeKey(candidateKey);
    if (key == null) {
      await writeJson(context.response, <String, Object?>{
        'error':
            'key "$candidateKey" is unusable; use letters, digits, ".", "_" '
            'and "-" separated by "/"',
      }, statusCode: HttpStatus.badRequest);
      return;
    }

    final crf = _int(body, 'crf') ?? 23;
    if (crf < 0 || crf > 51) {
      await writeJson(context.response, <String, Object?>{
        'error': 'crf must be between 0 and 51',
      }, statusCode: HttpStatus.badRequest);
      return;
    }

    final durationSeconds = _int(body, 'duration') ?? 12;
    if (durationSeconds < 1) {
      await writeJson(context.response, <String, Object?>{
        'error': 'duration must be at least 1 second',
      }, statusCode: HttpStatus.badRequest);
      return;
    }

    final job = transcodes.submit(
      key: key,
      input: rawInput,
      isDemo: isDemo,
      duration: isDemo ? Duration(seconds: durationSeconds) : null,
      options: TranscodeOptions(
        crf: crf,
        preset: _string(body, 'preset') ?? 'veryfast',
      ),
    );

    _log.info(
      'accepted transcode request',
      fields: <String, Object?>{'id': job.id, 'key': key},
    );
    await writeJson(
      context.response,
      job.toJson(),
      statusCode: HttpStatus.accepted,
    );
  }

  /// Drops the whole cache, or a single key when `key` is given.
  Future<void> _clearCache(RequestContext context) async {
    Map<String, Object?> body = <String, Object?>{};
    try {
      body = await readJsonObject(context.request) ?? body;
    } on FormatException catch (error) {
      await writeJson(context.response, <String, Object?>{
        'error': error.message,
      }, statusCode: HttpStatus.badRequest);
      return;
    }

    final key = _string(body, 'key') ?? queryString(context.uri, 'key');
    try {
      await cache.clear(key: key);
    } on ArgumentError catch (error) {
      await writeJson(context.response, <String, Object?>{
        'error': error.message,
      }, statusCode: HttpStatus.badRequest);
      return;
    }

    final stats = await cache.stats();
    await writeJson(context.response, <String, Object?>{
      'cleared': key ?? '*',
      'totalBytes': stats.totalBytes,
      'entries': stats.entryCount,
    });
  }

  /// Percent-encodes each segment of a key for use inside a URL path.
  static String _encodeKey(String key) =>
      key.split('/').map(Uri.encodeComponent).join('/');

  static String _defaultKeyFor(String source) {
    final base = source
        .split(RegExp(r'[\\/]'))
        .last
        .split('.')
        .first
        .replaceAll(RegExp('[^A-Za-z0-9._-]'), '_')
        .replaceFirst(RegExp('^[^A-Za-z0-9]+'), '');
    return '${base.isEmpty ? 'video' : base}.mp4';
  }

  static String? _string(Map<String, Object?> body, String name) {
    final value = body[name];
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static int? _int(Map<String, Object?> body, String name) {
    final value = body[name];
    if (value is int) return value;
    if (value is String) return int.tryParse(value.trim());
    return null;
  }
}
