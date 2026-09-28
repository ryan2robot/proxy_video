import 'dart:io';

import 'package:path/path.dart' as p;

import '../logger.dart';
import '../util/http_util.dart';
import 'storage.dart';

/// [Storage] backed by a local directory, standing in for a COS bucket.
///
/// Bytes are written to `<root>/<key>` and [urlFor] points at the simulated
/// origin server, which publishes the same directory over HTTP with full Range
/// support. Because the proxy then fetches over HTTP, the whole pipeline
/// exercises the same code path a real CDN would rather than being handed a
/// shortcut file path.
class LocalDirStorage implements Storage {
  LocalDirStorage({
    required Directory root,
    required Uri originBaseUri,
    Logger? log,
  }) : _root = root,
       _originBaseUri = originBaseUri,
       _log = (log ?? rootLogger).child('storage.local');

  /// Suffix for the scratch file an upload is streamed into before it is
  /// renamed into place, so readers never observe a half-written object.
  static const String scratchSuffix = '.uploading';

  final Directory _root;
  final Uri _originBaseUri;
  final Logger _log;

  /// Directory holding the "bucket".
  Directory get root => _root;

  /// Filesystem location backing [key].
  File fileFor(String key) =>
      File(p.joinAll(<String>[_root.path, ..._requireSafeKey(key).split('/')]));

  @override
  Future<ObjectStat> put(
    String key,
    Stream<List<int>> data, {
    int? length,
    String? contentType,
  }) async {
    final safeKey = _requireSafeKey(key);
    final target = fileFor(safeKey);
    await target.parent.create(recursive: true);

    final scratch = File('${target.path}$scratchSuffix');
    if (scratch.existsSync()) await scratch.delete();

    var written = 0;
    var failed = false;
    final sink = scratch.openWrite();
    try {
      await for (final piece in data) {
        sink.add(piece);
        written += piece.length;
      }
      await sink.flush();
    } on Object {
      failed = true;
      rethrow;
    } finally {
      try {
        await sink.close();
      } on Object {
        failed = true;
      }
      if (failed) await _deleteQuietly(scratch);
    }

    if (length != null && written != length) {
      await _deleteQuietly(scratch);
      throw StorageException(
        'received $written bytes but $length were expected',
        key: safeKey,
      );
    }

    if (target.existsSync()) await target.delete();
    await scratch.rename(target.path);

    final stat = await this.stat(safeKey);
    if (stat == null) {
      throw StorageException(
        'the upload was reported as successful but the object is missing',
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
    final file = fileFor(safeKey);
    if (!file.existsSync()) return null;

    final size = await file.length();
    final modified = await file.lastModified();
    return ObjectStat(
      key: safeKey,
      size: size,
      etag: makeEtag(size, modified),
      lastModified: modified,
      contentType: contentTypeForPath(safeKey),
      url: urlFor(safeKey),
    );
  }

  @override
  Future<bool> delete(String key) async {
    final safeKey = _requireSafeKey(key);
    final file = fileFor(safeKey);
    if (!file.existsSync()) return false;

    await file.delete();
    _log.info('deleted object', fields: <String, Object?>{'key': safeKey});
    return true;
  }

  @override
  Future<List<ObjectStat>> list({String? prefix}) async {
    if (!_root.existsSync()) return const <ObjectStat>[];

    final results = <ObjectStat>[];
    await for (final entity in _root.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;

      final key = _keyFor(entity.path);
      // Uploads in progress and stray files are not objects.
      if (key == null || entity.path.endsWith(scratchSuffix)) continue;
      if (prefix != null && !key.startsWith(prefix)) continue;

      final stat = await this.stat(key);
      if (stat != null) results.add(stat);
    }

    results.sort((ObjectStat a, ObjectStat b) => a.key.compareTo(b.key));
    return results;
  }

  @override
  Uri urlFor(String key) {
    final safeKey = _requireSafeKey(key);
    return _originBaseUri.replace(
      pathSegments: <String>['origin', ...safeKey.split('/')],
    );
  }

  @override
  Future<void> close() async {}

  /// Inverts [fileFor], returning `null` for anything that is not a valid key.
  String? _keyFor(String filePath) {
    final relative = p.relative(filePath, from: _root.path);
    if (relative.startsWith('..') || p.isAbsolute(relative)) return null;

    final key = relative.replaceAll(r'\', '/');
    return isValidKey(key) ? key : null;
  }

  Future<void> _deleteQuietly(File file) async {
    if (!file.existsSync()) return;
    try {
      await file.delete();
    } on FileSystemException catch (error) {
      _log.warn(
        'could not remove scratch file',
        fields: <String, Object?>{
          'file': p.basename(file.path),
          'error': error,
        },
      );
    }
  }

  static String _requireSafeKey(String key) {
    final safeKey = sanitizeKey(key);
    if (safeKey == null) {
      throw StorageException('"$key" is not a safe object key', key: key);
    }
    return safeKey;
  }
}
