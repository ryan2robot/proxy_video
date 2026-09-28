import 'dart:async';

import '../logger.dart';
import '../util/http_util.dart';
import 'storage.dart';

/// Object description returned by a COS-compatible client.
class CosObjectInfo {
  const CosObjectInfo({
    required this.key,
    required this.size,
    this.etag,
    this.lastModified,
    this.contentType,
  });

  /// Object key.
  final String key;

  /// Size in bytes.
  final int size;

  /// Entity tag, when the SDK exposes one.
  final String? etag;

  /// Last modification time, when the SDK exposes one.
  final DateTime? lastModified;

  /// Content type, when the SDK exposes one.
  final String? contentType;
}

/// The minimal COS / S3-compatible surface [CosStorage] needs.
///
/// Kept deliberately tiny so a real SDK (`cos-dart`, an S3 client, or a
/// signed-URL uploader) can be adapted in a handful of lines without this
/// package taking a dependency on any of them.
abstract class CosClient {
  /// Uploads [length] bytes from [data] under [key].
  Future<void> putObject({
    required String key,
    required Stream<List<int>> data,
    required int length,
    String? contentType,
  });

  /// Returns metadata for [key], or `null` when the object is absent.
  Future<CosObjectInfo?> headObject(String key);

  /// Deletes [key]; returns whether an object was removed.
  Future<bool> deleteObject(String key);

  /// Lists objects, optionally restricted to [prefix].
  Future<List<CosObjectInfo>> listObjects({String? prefix});

  /// Releases pooled connections.
  void close();
}

/// Builds a [CosClient] from [CosCredentials].
///
/// Registering one of these is the single extension point for a real SDK.
typedef CosClientFactory = CosClient Function(CosCredentials credentials);

/// Raised when COS is selected but no working client has been wired in.
class CosNotConfiguredException implements Exception {
  const CosNotConfiguredException(this.message);

  /// What the operator has to do to fix it.
  final String message;

  @override
  String toString() => 'CosNotConfiguredException: $message';
}

/// Credentials for a COS bucket, or any equivalent S3 endpoint.
///
/// Secrets are deliberately absent from [toString]; log records are easy to
/// leak, and a bucket key is not worth the risk.
class CosCredentials {
  const CosCredentials({
    required this.secretId,
    required this.secretKey,
    required this.bucket,
    required this.region,
    this.cdnDomain,
    this.useHttps = true,
  });

  /// Environment variable holding the COS secret id.
  static const String secretIdKey = 'COS_SECRET_ID';

  /// Environment variable holding the COS secret key.
  static const String secretKeyKey = 'COS_SECRET_KEY';

  /// Environment variable holding the bucket name.
  static const String bucketKey = 'COS_BUCKET';

  /// Environment variable holding the bucket region.
  static const String regionKey = 'COS_REGION';

  /// Environment variable holding the CDN host that fronts the bucket.
  static const String cdnDomainKey = 'COS_CDN_DOMAIN';

  /// Every variable a real COS deployment has to provide.
  static const List<String> requiredEnvironmentKeys = <String>[
    secretIdKey,
    secretKeyKey,
    bucketKey,
    regionKey,
  ];

  /// Secret id; never logged.
  final String secretId;

  /// Secret key; never logged.
  final String secretKey;

  /// Bucket name.
  final String bucket;

  /// Bucket region, e.g. `ap-guangzhou`.
  final String region;

  /// CDN host that fronts the bucket, e.g. `cdn.example.com`.
  final String? cdnDomain;

  /// Whether to build `https` URLs.
  final bool useHttps;

  /// Reads credentials from [environment], returning `null` when COS is not
  /// configured at all.
  ///
  /// Throws a [FormatException] when only some of the variables are present,
  /// because a half-configured bucket is a deployment bug worth surfacing.
  static CosCredentials? tryFromEnvironment(Map<String, String> environment) {
    final secretId = _read(environment, secretIdKey);
    final secretKey = _read(environment, secretKeyKey);
    final bucket = _read(environment, bucketKey);
    final region = _read(environment, regionKey);

    final provided = <String?>[secretId, secretKey, bucket, region];
    if (provided.every((String? value) => value == null)) return null;

    final missing = <String>[
      if (secretId == null) secretIdKey,
      if (secretKey == null) secretKeyKey,
      if (bucket == null) bucketKey,
      if (region == null) regionKey,
    ];
    if (missing.isNotEmpty) {
      throw FormatException(
        'COS is only partially configured; missing ${missing.join(', ')}. '
        'Set all of ${requiredEnvironmentKeys.join(', ')} or none of them.',
      );
    }

    return CosCredentials(
      secretId: secretId!,
      secretKey: secretKey!,
      bucket: bucket!,
      region: region!,
      cdnDomain: _read(environment, cdnDomainKey),
    );
  }

  /// Bucket endpoint, used when no CDN domain is configured.
  Uri get endpoint => Uri(
    scheme: useHttps ? 'https' : 'http',
    host: '$bucket.cos.$region.myqcloud.com',
  );

  /// Public URL for [key], through the CDN when one is configured.
  Uri urlFor(String key) {
    final base = cdnDomain == null
        ? endpoint
        : Uri(scheme: useHttps ? 'https' : 'http', host: cdnDomain);
    return base.replace(pathSegments: key.split('/'));
  }

  @override
  String toString() =>
      'CosCredentials(bucket: $bucket, region: $region, '
      'cdn: ${cdnDomain ?? '-'})';

  static String? _read(Map<String, String> environment, String key) {
    final value = environment[key]?.trim();
    return (value == null || value.isEmpty) ? null : value;
  }
}

/// Placeholder used when credentials exist but no SDK client is registered.
///
/// Every method throws instead of pretending an upload succeeded, which would
/// leave the pipeline reporting success for media that never left the machine.
class UnimplementedCosClient implements CosClient {
  const UnimplementedCosClient();

  static const String _message =
      'No COS client implementation is registered. Build CosStorage with a '
      'CosClient adapted from your SDK of choice, or call '
      'CosStorage.tryFromEnvironment(..., clientFactory: ...).';

  @override
  Future<void> putObject({
    required String key,
    required Stream<List<int>> data,
    required int length,
    String? contentType,
  }) async => throw const CosNotConfiguredException(_message);

  @override
  Future<CosObjectInfo?> headObject(String key) async =>
      throw const CosNotConfiguredException(_message);

  @override
  Future<bool> deleteObject(String key) async =>
      throw const CosNotConfiguredException(_message);

  @override
  Future<List<CosObjectInfo>> listObjects({String? prefix}) async =>
      throw const CosNotConfiguredException(_message);

  @override
  void close() {}
}

/// [Storage] adapter for a COS bucket.
///
/// Swap the backend by supplying a different [CosClient]; nothing else in the
/// pipeline changes, because the proxy reads through [urlFor] over HTTP.
class CosStorage implements Storage {
  CosStorage({
    required this.credentials,
    required CosClient client,
    Logger? log,
  }) : _client = client,
       _log = (log ?? rootLogger).child('storage.cos');

  /// Builds a COS backend when [environment] carries credentials.
  ///
  /// Returns `null` when COS is not configured, so callers can fall back to
  /// [LocalDirStorage]. When credentials exist but [clientFactory] is omitted,
  /// the result fails loudly on first use rather than dropping uploads.
  static Storage? tryFromEnvironment(
    Map<String, String> environment, {
    CosClientFactory? clientFactory,
    Logger? log,
  }) {
    final credentials = CosCredentials.tryFromEnvironment(environment);
    if (credentials == null) return null;
    return CosStorage(
      credentials: credentials,
      client:
          clientFactory?.call(credentials) ?? const UnimplementedCosClient(),
      log: log,
    );
  }

  /// Bucket credentials, also used to build public URLs.
  final CosCredentials credentials;

  final CosClient _client;
  final Logger _log;

  @override
  Future<ObjectStat> put(
    String key,
    Stream<List<int>> data, {
    int? length,
    String? contentType,
  }) async {
    final safeKey = _requireSafeKey(key);
    if (length == null) {
      throw StorageException(
        'COS requires the object length up front; pass `length` or use putFile',
        key: safeKey,
      );
    }

    await _client.putObject(
      key: safeKey,
      data: data,
      length: length,
      contentType: contentType ?? contentTypeForPath(safeKey),
    );

    final stat = await this.stat(safeKey);
    if (stat == null) {
      throw StorageException(
        'COS accepted the upload but headObject cannot see the object',
        key: safeKey,
      );
    }

    _log.info(
      'stored object',
      fields: <String, Object?>{'key': safeKey, 'bytes': stat.size},
    );
    return stat;
  }

  @override
  Future<ObjectStat?> stat(String key) async {
    final safeKey = _requireSafeKey(key);
    final info = await _client.headObject(safeKey);
    if (info == null) return null;

    return ObjectStat(
      key: safeKey,
      size: info.size,
      etag: info.etag,
      lastModified: info.lastModified,
      contentType: info.contentType ?? contentTypeForPath(safeKey),
      url: urlFor(safeKey),
    );
  }

  @override
  Future<bool> delete(String key) async {
    final safeKey = _requireSafeKey(key);
    final removed = await _client.deleteObject(safeKey);
    if (removed) {
      _log.info('deleted object', fields: <String, Object?>{'key': safeKey});
    }
    return removed;
  }

  @override
  Future<List<ObjectStat>> list({String? prefix}) async {
    final infos = await _client.listObjects(prefix: prefix);

    final results =
        infos
            .map(
              (CosObjectInfo info) => ObjectStat(
                key: info.key,
                size: info.size,
                etag: info.etag,
                lastModified: info.lastModified,
                contentType: info.contentType ?? contentTypeForPath(info.key),
                url: urlFor(info.key),
              ),
            )
            .toList(growable: false)
          ..sort((ObjectStat a, ObjectStat b) => a.key.compareTo(b.key));
    return results;
  }

  @override
  Uri urlFor(String key) => credentials.urlFor(_requireSafeKey(key));

  @override
  Future<void> close() async => _client.close();

  static String _requireSafeKey(String key) {
    final safeKey = sanitizeKey(key);
    if (safeKey == null) {
      throw StorageException('"$key" is not a safe object key', key: key);
    }
    return safeKey;
  }
}
