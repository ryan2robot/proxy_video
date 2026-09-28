import 'dart:io';

/// Metadata describing one published object.
class ObjectStat {
  const ObjectStat({
    required this.key,
    required this.size,
    this.etag,
    this.lastModified,
    this.contentType,
    this.url,
  });

  /// Object key.
  final String key;

  /// Size in bytes.
  final int size;

  /// Entity tag, when the backend exposes one.
  final String? etag;

  /// Last modification time, when known.
  final DateTime? lastModified;

  /// Content type, when known.
  final String? contentType;

  /// URL the proxy reads this object from.
  final Uri? url;

  @override
  String toString() => 'ObjectStat($key, $size bytes)';
}

/// Raised when a storage backend rejects an operation.
class StorageException implements Exception {
  const StorageException(this.message, {this.key, this.cause});

  /// What went wrong.
  final String message;

  /// Object the failure relates to, when known.
  final String? key;

  /// Underlying error, when there is one.
  final Object? cause;

  @override
  String toString() {
    final prefix = key == null ? 'StorageException' : 'StorageException($key)';
    final suffix = cause == null ? '' : ' (caused by: $cause)';
    return '$prefix: $message$suffix';
  }
}

/// Where transcoded media is published.
///
/// The proxy never reads through this interface: it fetches over HTTP from
/// [urlFor]. Keeping those two roles apart is what lets a real CDN sit in the
/// middle — signing, URL rewriting and edge caching all happen behind a URL,
/// and the proxy stays unaware of them.
abstract class Storage {
  /// Publishes [data] under [key], replacing any existing object.
  ///
  /// [length] is the expected byte count. Backends that must sign a request up
  /// front (COS) require it, so callers that already know the size should pass
  /// it rather than forcing the backend to buffer the whole stream.
  Future<ObjectStat> put(
    String key,
    Stream<List<int>> data, {
    int? length,
    String? contentType,
  });

  /// Returns metadata for [key], or `null` when it does not exist.
  Future<ObjectStat?> stat(String key);

  /// Deletes [key]; returns whether an object was actually removed.
  Future<bool> delete(String key);

  /// Lists stored objects, optionally restricted to [prefix].
  Future<List<ObjectStat>> list({String? prefix});

  /// URL the proxy reads [key] from.
  Uri urlFor(String key);

  /// Releases pooled resources.
  Future<void> close();
}

/// Convenience helpers shared by every backend.
extension StorageUploads on Storage {
  /// Publishes a file from disk.
  ///
  /// Sizes the upload up front, which backends that must sign a request before
  /// sending it (COS) depend on.
  Future<ObjectStat> putFile(
    String key,
    File file, {
    String? contentType,
  }) async {
    final length = await file.length();
    return put(key, file.openRead(), length: length, contentType: contentType);
  }
}
