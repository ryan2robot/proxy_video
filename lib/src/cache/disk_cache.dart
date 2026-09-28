import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../logger.dart';
import '../util/byte_size.dart';
import '../util/http_util.dart';
import '../util/semaphore.dart';
import 'cache_entry.dart';
import 'origin_client.dart';

/// Per-object cache statistics, used by the API and the debug UI.
class CacheEntryStats {
  const CacheEntryStats({
    required this.key,
    required this.totalSize,
    required this.chunkSize,
    required this.chunkCount,
    required this.readyChunks,
    required this.cachedBytes,
    required this.complete,
    required this.lastAccessAt,
    required this.chunkBitmap,
    this.etag,
    this.contentType,
    this.upstreamRequests = 0,
    this.cacheHits = 0,
    this.cacheMisses = 0,
  });

  /// Object key.
  final String key;

  /// Total object size in bytes.
  final int totalSize;

  /// Chunk granularity in bytes.
  final int chunkSize;

  /// Total number of chunks.
  final int chunkCount;

  /// Number of chunks already on disk.
  final int readyChunks;

  /// Bytes available offline.
  final int cachedBytes;

  /// Whether the object is fully cached.
  final bool complete;

  /// When the entry was last used.
  final DateTime lastAccessAt;

  /// Base64 bitmap of cached chunks.
  final String chunkBitmap;

  /// Origin entity tag, when known.
  final String? etag;

  /// Origin content type, when known.
  final String? contentType;

  /// Range requests sent to the origin for this object.
  final int upstreamRequests;

  /// Served windows answered entirely from disk.
  final int cacheHits;

  /// Served windows that had to fetch at least one chunk.
  final int cacheMisses;

  /// Fraction of the object available offline, in `[0, 1]`.
  double get cachedFraction => totalSize == 0 ? 1 : cachedBytes / totalSize;

  /// Fraction of served windows answered without touching the origin.
  double? get cacheHitRate {
    final total = cacheHits + cacheMisses;
    return total == 0 ? null : cacheHits / total;
  }

}

/// Aggregate cache statistics.
class CacheStats {
  const CacheStats({
    required this.entryCount,
    required this.totalBytes,
    required this.maxBytes,
    required this.chunkSize,
    required this.upstreamInUse,
    required this.upstreamCapacity,
    required this.entries,
  });

  /// Number of objects with an in-memory entry.
  final int entryCount;

  /// Bytes currently occupied on disk by cached objects.
  final int totalBytes;

  /// Configured budget; `0` means unlimited.
  final int maxBytes;

  /// Chunk granularity in bytes.
  final int chunkSize;

  /// Upstream requests currently in flight.
  final int upstreamInUse;

  /// Upstream concurrency limit.
  final int upstreamCapacity;

  /// Per-object statistics.
  final List<CacheEntryStats> entries;
}

/// Disk-backed chunk cache for proxied media.
///
/// Each object gets a preallocated `<key>.bin` file plus a `<key>.meta.json`
/// progress file, laid out so that the object key maps onto a mirrored
/// directory tree. Mirroring (rather than hashing) keeps the cache browsable
/// and makes key collisions structurally impossible; the key itself is
/// validated by [sanitizeKey] before it ever reaches the filesystem.
class DiskCache {
  /// Creates a cache rooted at [root].
  ///
  /// The cache does not take ownership of [origin]; whoever created the client
  /// is responsible for closing it.
  DiskCache({
    required Directory root,
    required this.chunkSize,
    required this.maxBytes,
    required this.origin,
    required Logger log,
    int maxConcurrentUpstream = 4,
    this.prefetchAhead = 0,
  }) : _root = root,
       _log = log.child('cache'),
       limiter = Semaphore(maxConcurrentUpstream);

  static const Duration _budgetCheckInterval = Duration(seconds: 5);
  static const Duration _statsScanInterval = Duration(seconds: 1);

  final Directory _root;
  final Logger _log;

  /// Chunk granularity applied to new entries.
  final int chunkSize;

  /// Budget in bytes; `0` disables eviction.
  final int maxBytes;

  /// Where missing bytes come from.
  final OriginClient origin;

  /// Caps concurrent upstream range requests across every entry.
  final Semaphore limiter;

  /// Speculative read-ahead depth passed to new entries.
  final int prefetchAhead;

  final Map<String, CacheEntry> _entries = <String, CacheEntry>{};

  Map<String, int> _fileBytes = <String, int>{};
  int _totalBytes = 0;
  DateTime? _scannedAt;

  /// Root directory holding the cached objects.
  Directory get root => _root;

  /// Number of objects currently tracked in memory.
  int get entryCount => _entries.length;

  /// Bytes occupied on disk as of the last directory scan.
  int get trackedBytes => _totalBytes;

  /// Returns the entry for [key], creating it (and loading any metadata left by
  /// a previous process) on first use.
  Future<CacheEntry> entryFor(String key) async {
    final safeKey = sanitizeKey(key);
    if (safeKey == null) {
      throw ArgumentError.value(key, 'key', 'is not a safe object key');
    }

    final existing = _entries[safeKey];
    if (existing != null) {
      existing.touch();
      return existing;
    }

    final files = _filesFor(safeKey);
    final entry = CacheEntry(
      key: safeKey,
      chunkSize: chunkSize,
      dataFile: files.data,
      metaFile: files.meta,
      origin: origin,
      limiter: limiter,
      log: _log,
      prefetchAhead: prefetchAhead,
      onChunkCached: _onChunkCached,
      onChunkEvent: _onChunkEvent,
      meta: await _readMeta(files.meta, safeKey),
    );

    _entries[safeKey] = entry;
    return entry;
  }

  /// Returns the entry for [key] when it is already tracked, without creating
  /// one or touching the origin.
  CacheEntry? peekEntry(String key) {
    final safeKey = sanitizeKey(key);
    return safeKey == null ? null : _entries[safeKey];
  }

  /// Whether [key] is fully cached on disk.
  bool isFullyCached(String key) => peekEntry(key)?.isComplete ?? false;

  /// Collects cache statistics, rescanning the cache directory when the
  /// previous scan is older than [CacheStats] polling needs.
  Future<CacheStats> stats() async {
    await _scanFiles(minInterval: _statsScanInterval);

    final entries = _entries.values.toList(growable: false)
      ..sort((CacheEntry a, CacheEntry b) => a.key.compareTo(b.key));

    return CacheStats(
      entryCount: _entries.length,
      totalBytes: _totalBytes,
      maxBytes: maxBytes,
      chunkSize: chunkSize,
      upstreamInUse: limiter.inUse,
      upstreamCapacity: limiter.capacity,
      entries: entries.map(_statsFor).toList(growable: false),
    );
  }

  /// Statistics for a single tracked entry, or `null` when it is not known.
  ///
  /// Unlike [stats] this never rescans the cache directory, because an event
  /// stream calls it once per connection while playback is already running.
  CacheEntryStats? statsFor(String key) {
    final entry = peekEntry(key);
    return entry == null ? null : _statsFor(entry);
  }

  static CacheEntryStats _statsFor(CacheEntry entry) => CacheEntryStats(
    key: entry.key,
    totalSize: entry.knownTotalSize ?? 0,
    chunkSize: entry.chunkSize,
    chunkCount: entry.chunkCount,
    readyChunks: entry.readyChunkCount,
    cachedBytes: entry.cachedBytes,
    complete: entry.isComplete,
    lastAccessAt: entry.lastAccessAt,
    chunkBitmap: entry.chunkBitmapBase64(),
    etag: entry.etag,
    contentType: entry.contentType,
    upstreamRequests: entry.upstreamRequestCount,
    cacheHits: entry.cacheHits,
    cacheMisses: entry.cacheMisses,
  );

  /// Drops the whole cache, or just [key] when it is provided.
  Future<void> clear({String? key}) async {
    if (key != null) {
      final safeKey = sanitizeKey(key);
      if (safeKey == null) {
        throw ArgumentError.value(key, 'key', 'is not a safe object key');
      }

      final entry = _entries.remove(safeKey);
      if (entry != null) {
        await entry.deleteFiles();
      } else {
        final files = _filesFor(safeKey);
        await _deleteIfExists(files.data.path);
        await _deleteIfExists(files.meta.path);
        await _deleteIfExists('${files.meta.path}.tmp');
      }

      _scannedAt = null;
      _log.info(
        'cleared cached media',
        fields: <String, Object?>{'key': safeKey},
      );
      return;
    }

    for (final entry in _entries.values.toList(growable: false)) {
      await entry.deleteFiles();
    }
    _entries.clear();

    if (_root.existsSync()) {
      await _root.delete(recursive: true);
    }
    await _root.create(recursive: true);

    _fileBytes = <String, int>{};
    _totalBytes = 0;
    _scannedAt = DateTime.now();
    _log.info('cleared the whole cache');
  }

  /// Deletes least-recently-used objects until the cache fits its budget.
  ///
  /// Orphaned files (present on disk but not owned by a live entry) go first,
  /// then entries that are not currently serving data — evicting a file a
  /// reader is midway through would turn playback into an error.
  Future<void> enforceBudget({bool force = false}) async {
    if (maxBytes <= 0) return;

    await _scanFiles(minInterval: force ? Duration.zero : _budgetCheckInterval);
    if (_totalBytes <= maxBytes) return;

    _log.info(
      'cache is over budget, evicting',
      fields: <String, Object?>{
        'used': formatByteSize(_totalBytes),
        'budget': formatByteSize(maxBytes),
      },
    );

    final owned = <String>{
      for (final entry in _entries.values) p.normalize(entry.dataFile.path),
    };

    final orphans = <({String path, DateTime modified})>[];
    for (final path in _fileBytes.keys) {
      if (owned.contains(path)) continue;
      final modified = await _lastModifiedOf(path);
      orphans.add((path: path, modified: modified));
    }
    orphans.sort((a, b) => a.modified.compareTo(b.modified));

    for (final orphan in orphans) {
      if (_totalBytes <= maxBytes) break;
      await _deleteBackingFiles(orphan.path);
    }

    final active =
        _entries.values.where((CacheEntry entry) => !entry.isBusy).toList()
          ..sort(
            (CacheEntry a, CacheEntry b) =>
                a.lastAccessAt.compareTo(b.lastAccessAt),
          );

    for (final entry in active) {
      if (_totalBytes <= maxBytes) break;
      await _evict(entry);
    }
  }

  /// Flushes metadata for every tracked entry without closing anything.
  Future<void> flush() async {
    for (final entry in _entries.values.toList(growable: false)) {
      await entry.persistMeta(force: true);
    }
  }

  /// Flushes metadata and releases every open file handle.
  Future<void> close() async {
    for (final entry in _entries.values.toList(growable: false)) {
      await entry.dispose();
    }
    _entries.clear();
    await _events.close();
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  void _onChunkCached(CacheEntry _) {
    // New bytes may have pushed the cache over budget. `enforceBudget` is
    // internally throttled, so calling it on every chunk is cheap.
    unawaited(enforceBudget());
  }

  void _onChunkEvent(ChunkEvent event) {
    // A download in flight during shutdown would otherwise throw on a closed
    // controller; dropping the event costs nothing, because `close()` means
    // nobody is going to read it.
    if (_events.isClosed) return;
    _events.add(event);
  }

  Future<void> _evict(CacheEntry entry) async {
    final path = p.normalize(entry.dataFile.path);
    final size = _fileBytes[path] ?? entry.knownTotalSize ?? 0;

    await entry.deleteFiles();
    _entries.remove(entry.key);
    _fileBytes.remove(path);
    _totalBytes -= size;

    _log.info(
      'evicted cached media',
      fields: <String, Object?>{'key': entry.key, 'bytes': size},
    );
  }

  Future<void> _deleteBackingFiles(String dataPath) async {
    final size = _fileBytes.remove(dataPath) ?? 0;
    final metaPath = _metaPathFor(dataPath);

    await _deleteIfExists(dataPath);
    await _deleteIfExists(metaPath);
    await _deleteIfExists('$metaPath.tmp');

    _totalBytes -= size;
    _log.debug(
      'evicted orphaned cache file',
      fields: <String, Object?>{'file': p.basename(dataPath), 'bytes': size},
    );
  }

  Future<CacheEntryMeta?> _readMeta(File metaFile, String key) async {
    if (!metaFile.existsSync()) return null;

    try {
      final meta = CacheEntryMeta.tryParse(await metaFile.readAsString());
      if (meta == null || meta.key != key) {
        _log.warn(
          'discarding unusable cache metadata',
          fields: <String, Object?>{'key': key},
        );
        return null;
      }
      return meta;
    } on FileSystemException catch (error) {
      _log.warn(
        'could not read cache metadata',
        fields: <String, Object?>{'key': key, 'error': error},
      );
      return null;
    }
  }

  Future<void> _scanFiles({required Duration minInterval}) async {
    final now = DateTime.now();
    final scannedAt = _scannedAt;
    if (scannedAt != null && now.difference(scannedAt) < minInterval) return;
    _scannedAt = now;

    final files = <String, int>{};
    if (_root.existsSync()) {
      await for (final entity in _root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final path = p.normalize(entity.path);
        if (!path.endsWith('.bin')) continue;
        try {
          files[path] = await entity.length();
        } on FileSystemException {
          continue;
        }
      }
    }

    _fileBytes = files;
    _totalBytes = files.values.fold<int>(
      0,
      (int sum, int value) => sum + value,
    );
  }

  Future<DateTime> _lastModifiedOf(String path) async {
    try {
      return await File(path).lastModified();
    } on FileSystemException {
      return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }
  }

  Future<void> _deleteIfExists(String path) async {
    final file = File(path);
    if (!file.existsSync()) return;
    try {
      await file.delete();
    } on FileSystemException catch (error) {
      _log.warn(
        'could not delete cache file',
        fields: <String, Object?>{'file': p.basename(path), 'error': error},
      );
    }
  }

  /// Maps [key] onto the `.bin` and `.meta.json` files backing it.
  ///
  /// Every segment is used verbatim: [sanitizeKey] has already rejected
  /// separators, traversal and names the host filesystem cannot represent, so
  /// the key and the on-disk path stay in one-to-one correspondence.
  ({File data, File meta}) _filesFor(String key) {
    final segments = key.split('/');
    final leaf = segments.last;
    final directory = p.joinAll(<String>[
      _root.path,
      ...segments.sublist(0, segments.length - 1),
    ]);

    return (
      data: File(p.join(directory, '$leaf.bin')),
      meta: File(p.join(directory, '$leaf.meta.json')),
    );
  }

  /// `<dir>/<leaf>.bin` maps to `<dir>/<leaf>.meta.json`.
  static String _metaPathFor(String dataPath) =>
      '${dataPath.substring(0, dataPath.length - '.bin'.length)}.meta.json';
}
