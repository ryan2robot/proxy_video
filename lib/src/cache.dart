import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'logger.dart';
import 'origin.dart';
import 'util.dart';

/// Number of [chunkSize] chunks needed to cover [totalSize] bytes.
int chunkCountFor(int totalSize, int chunkSize) =>
    totalSize <= 0 ? 0 : ((totalSize - 1) ~/ chunkSize) + 1;

/// Encodes the indices in [ready] as a base64 bitmap of [chunkCount] bits.
///
/// A bitmap keeps the metadata file tiny even for very large media (a 4 GiB
/// file at 1 MiB chunks is 512 bytes of base64 instead of a 20 KB JSON array),
/// which matters because the metadata is rewritten while playback is running.
String encodeChunkBitmap(Iterable<int> ready, int chunkCount) {
  final bytes = Uint8List((chunkCount + 7) >> 3);
  for (final index in ready) {
    if (index < 0 || index >= chunkCount) continue;
    bytes[index >> 3] |= 1 << (index & 7);
  }
  return base64Encode(bytes);
}

/// Decodes a base64 chunk bitmap, keeping only indices below [chunkCount].
Set<int> decodeChunkBitmap(String bitmap, int chunkCount) {
  if (bitmap.isEmpty || chunkCount <= 0) return <int>{};

  final bytes = base64Decode(bitmap.trim());
  final ready = <int>{};
  for (var index = 0; index < chunkCount; index++) {
    final byteIndex = index >> 3;
    if (byteIndex >= bytes.length) break;
    if ((bytes[byteIndex] & (1 << (index & 7))) != 0) ready.add(index);
  }
  return ready;
}

/// Persisted description of a cached object.
///
/// Only progress bookkeeping lives here: the bytes themselves are in the
/// sibling `.bin` file, which is preallocated to [totalSize] so any chunk can
/// be filled in any order.
class CacheEntryMeta {
  const CacheEntryMeta({
    required this.key,
    required this.totalSize,
    required this.chunkSize,
    required this.chunkBitmap,
    this.etag,
    this.contentType,
    this.lastModified,
  });

  /// Object key this entry belongs to.
  final String key;

  /// Total object size in bytes.
  final int totalSize;

  /// Chunk granularity used when the entry was written.
  final int chunkSize;

  /// Base64 bitmap of fully cached chunks.
  final String chunkBitmap;

  /// Origin entity tag at the time of caching.
  final String? etag;

  /// Origin content type.
  final String? contentType;

  /// Origin modification time.
  final DateTime? lastModified;

  /// Serialises to a JSON-compatible map.
  Map<String, Object?> toJson() => <String, Object?>{
    'key': key,
    'totalSize': totalSize,
    'chunkSize': chunkSize,
    'chunkBitmap': chunkBitmap,
    if (etag != null) 'etag': etag,
    if (contentType != null) 'contentType': contentType,
    if (lastModified != null)
      'lastModified': lastModified!.toUtc().toIso8601String(),
  };

  /// Parses [jsonText], returning `null` when it is unusable.
  static CacheEntryMeta? tryParse(String jsonText) {
    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is! Map<String, Object?>) return null;

      final key = decoded['key'];
      final totalSize = decoded['totalSize'];
      final chunkSize = decoded['chunkSize'];
      final bitmap = decoded['chunkBitmap'];
      if (key is! String || totalSize is! int || chunkSize is! int) return null;
      if (bitmap is! String || totalSize < 0 || chunkSize < 1) return null;

      final lastModified = decoded['lastModified'];
      return CacheEntryMeta(
        key: key,
        totalSize: totalSize,
        chunkSize: chunkSize,
        chunkBitmap: bitmap,
        etag: decoded['etag'] is String ? decoded['etag']! as String : null,
        contentType: decoded['contentType'] is String
            ? decoded['contentType']! as String
            : null,
        lastModified: lastModified is String
            ? DateTime.tryParse(lastModified)
            : null,
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }
}

/// One cached media object: a preallocated `.bin` file plus the state machine
/// that fills it with chunks pulled from the origin.
///
/// Three properties matter here:
///
/// * a chunk is published to [_ready] only after every one of its bytes has
///   been written and flushed, so a reader can never observe a torn chunk;
/// * concurrent requests for the same missing chunk share a single upstream
///   fetch, which keeps a browser's burst of range requests from multiplying
///   into a burst of origin traffic;
/// * a freshly downloaded chunk is handed back to the caller, so the first
///   consumer never pays a second disk read for data already in memory.
class CacheEntry {
  CacheEntry({
    required this.key,
    required this.chunkSize,
    required this.dataFile,
    required this.metaFile,
    required this.origin,
    required this.limiter,
    required this.log,
    CacheEntryMeta? meta,
  }) {
    if (meta != null && meta.chunkSize == chunkSize && meta.totalSize >= 0) {
      _totalSize = meta.totalSize;
      _etag = meta.etag;
      _contentType = meta.contentType;
      _lastModified = meta.lastModified;
      _ready = _decodeBitmap(meta.chunkBitmap, meta.totalSize);
    }
  }

  /// Object key, as used against the origin and in URLs.
  final String key;

  /// Chunk granularity in bytes.
  final int chunkSize;

  /// Preallocated backing file holding the object's bytes.
  final File dataFile;

  /// Sibling metadata file holding [CacheEntryMeta].
  final File metaFile;

  /// Where missing bytes are fetched from.
  final OriginClient origin;

  /// Caps how many upstream range requests run at once.
  final Semaphore limiter;

  /// Logger, already namespaced by the cache.
  final Logger log;

  static const Duration _metaWriteInterval = Duration(seconds: 1);
  static const int _metaWriteChunkThreshold = 32;

  final AsyncMutex _writeMutex = AsyncMutex();
  final AsyncMutex _metaMutex = AsyncMutex();
  final Map<int, Future<Uint8List>> _inflight = <int, Future<Uint8List>>{};

  Set<int> _ready = <int>{};
  RandomAccessFile? _writeHandle;
  Future<int>? _totalSizeRequest;
  int? _totalSize;
  String? _etag;
  String? _contentType;
  DateTime? _lastModified;
  DateTime _lastMetaWrite = DateTime.utc(1970);
  int _chunksSinceMetaWrite = 0;
  bool _backingPrepared = false;
  bool _metaDirty = false;

  /// Total object size, when it is already known.
  int? get knownTotalSize => _totalSize;

  /// Number of chunks already on disk.
  int get readyChunkCount => _ready.length;

  /// Origin content type, when known.
  String? get contentType => _contentType;

  /// Origin entity tag, when known.
  String? get etag => _etag;

  /// Origin modification time, when known.
  DateTime? get lastModified => _lastModified;

  /// Resolves the object size, contacting the origin at most once.
  ///
  /// A change in total size or entity tag invalidates everything cached so far,
  /// which is the cheapest way to never serve bytes from a replaced object.
  Future<int> resolveTotalSize() {
    final request = _totalSizeRequest;
    if (request != null) return request;

    final known = _totalSize;
    if (known != null && _backingPrepared) return Future<int>.value(known);

    final pending = _loadTotalSize();
    _totalSizeRequest = pending;
    return pending.whenComplete(() => _totalSizeRequest = null);
  }

  /// Streams the inclusive byte range [start]-[end], filling the cache as it
  /// goes.
  ///
  /// Chunks already on disk are read straight from the file; the rest are
  /// fetched from the origin, written down, and yielded from the bytes that
  /// were just received. Bytes start flowing as soon as the first chunk lands,
  /// which is what makes playback progressive rather than all-or-nothing.
  Stream<List<int>> readRange(int start, int end) async* {
    final totalSize = await resolveTotalSize();
    final from = math.max(0, start);
    final to = math.min(end, totalSize - 1);
    if (from > to) return;

    final lastIndex = to ~/ chunkSize;
    for (var index = from ~/ chunkSize; index <= lastIndex; index++) {
      final chunkStart = index * chunkSize;
      final sliceFrom = math.max(from, chunkStart);
      final sliceTo = math.min(to, chunkStart + chunkSize - 1);
      if (sliceFrom > sliceTo) continue;

      if (_ready.contains(index)) {
        yield* dataFile.openRead(sliceFrom, sliceTo + 1);
      } else {
        final bytes = await ensureChunk(index);
        final begin = sliceFrom - chunkStart;
        final finish = math.min(sliceTo - chunkStart + 1, bytes.length);
        if (begin < finish) {
          yield Uint8List.sublistView(bytes, begin, finish);
        }
      }
    }
  }

  /// Makes chunk [index] available, returning its bytes.
  ///
  /// Concurrent calls for the same chunk share one upstream request. The
  /// request is likewise independent of any consumer: cancelling the caller
  /// does not abort it, so the chunk still lands in the cache.
  Future<Uint8List> ensureChunk(int index) {
    if (_ready.contains(index)) return _readChunkFromDisk(index);

    final pending = _inflight[index];
    if (pending != null) return pending;

    final future = _downloadChunk(index).whenComplete(() {
      _inflight.remove(index);
    });
    _inflight[index] = future;
    return future;
  }

  /// Writes the metadata file, honouring the throttling policy.
  Future<void> persistMeta({bool force = false}) async {
    final totalSize = _totalSize;
    if (totalSize == null || !_backingPrepared) return;

    if (!force) {
      if (!_metaDirty) return;
      final dueByTime =
          DateTime.now().difference(_lastMetaWrite) >= _metaWriteInterval;
      final dueByChunks = _chunksSinceMetaWrite >= _metaWriteChunkThreshold;
      if (!dueByTime && !dueByChunks) return;
    }

    await _metaMutex.run(() async {
      final size = _totalSize;
      if (size == null || !_backingPrepared) return;

      _metaDirty = false;
      _chunksSinceMetaWrite = 0;
      _lastMetaWrite = DateTime.now();

      final meta = CacheEntryMeta(
        key: key,
        totalSize: size,
        chunkSize: chunkSize,
        chunkBitmap: encodeChunkBitmap(_ready, chunkCountFor(size, chunkSize)),
        etag: _etag,
        contentType: _contentType,
        lastModified: _lastModified,
      );

      // Write beside the target and rename, so a crash never leaves a
      // half-written metadata file where a reader could pick it up.
      await metaFile.parent.create(recursive: true);
      final scratch = File('${metaFile.path}.tmp');
      await scratch.writeAsString(jsonEncode(meta.toJson()), flush: true);
      if (metaFile.existsSync()) await metaFile.delete();
      await scratch.rename(metaFile.path);
    });
  }

  /// Flushes metadata and releases the write handle.
  Future<void> dispose() async {
    await persistMeta(force: true);
    await _closeWriteHandle();
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  Future<int> _loadTotalSize() async {
    final metadata = await origin.head(key);
    if (metadata == null) throw OriginNotFoundException(key);

    final previousSize = _totalSize;
    var invalidated =
        previousSize != null && previousSize != metadata.totalSize;
    if (!invalidated &&
        _etag != null &&
        metadata.etag != null &&
        _etag != metadata.etag) {
      invalidated = true;
    }

    _totalSize = metadata.totalSize;
    _etag = metadata.etag ?? _etag;
    _contentType = metadata.contentType ?? _contentType;
    _lastModified = metadata.lastModified ?? _lastModified;

    await _prepareBackingFile(metadata.totalSize, reset: invalidated);
    _metaDirty = true;
    await persistMeta();
    return metadata.totalSize;
  }

  /// Creates or validates the preallocated `.bin` file.
  Future<void> _prepareBackingFile(int totalSize, {required bool reset}) async {
    if (_backingPrepared && !reset) return;

    final exists = dataFile.existsSync();
    if (!reset && exists && await dataFile.length() == totalSize) {
      _backingPrepared = true;
      return;
    }

    await _closeWriteHandle();
    await dataFile.parent.create(recursive: true);
    if (exists) await dataFile.delete();

    // `FileMode.write` truncates; `truncate` then extends the file to the full
    // object size so any chunk can be written at its final offset later.
    final handle = await dataFile.open(mode: FileMode.write);
    try {
      await handle.truncate(totalSize);
    } finally {
      await handle.close();
    }

    _ready.clear();
    _backingPrepared = true;
    _metaDirty = true;
    log.debug(
      'prepared cache file',
      fields: <String, Object?>{'key': key, 'bytes': totalSize},
    );
  }

  Future<RandomAccessFile> _writableHandle() async {
    final existing = _writeHandle;
    if (existing != null) return existing;

    await dataFile.parent.create(recursive: true);
    // `FileMode.append` is the only Dart mode that opens an existing file for
    // writing without truncating it. Dart seeds the position at the end, but an
    // explicit `setPosition` is still honoured, so chunks cached by an earlier
    // process are preserved.
    final handle = await dataFile.open(mode: FileMode.append);
    _writeHandle = handle;
    return handle;
  }

  Future<void> _closeWriteHandle() => _writeMutex.run(() async {
    final handle = _writeHandle;
    _writeHandle = null;
    if (handle == null) return;
    try {
      await handle.close();
    } on Object catch (error) {
      log.debug(
        'closing write handle failed',
        fields: <String, Object?>{'key': key, 'error': error},
      );
    }
  });

  Future<void> _writeAt(int offset, Uint8List bytes) =>
      _writeMutex.run(() async {
        final handle = await _writableHandle();
        await handle.setPosition(offset);
        await handle.writeFrom(bytes);
        await handle.flush();
      });

  Future<Uint8List> _downloadChunk(int index) async {
    final totalSize = await resolveTotalSize();
    final start = index * chunkSize;
    final end = math.min(start + chunkSize, totalSize) - 1;
    if (start > end) {
      throw RangeError(
        'Chunk $index of "$key" starts past the end of a $totalSize byte object',
      );
    }
    final expected = end - start + 1;

    final builder = BytesBuilder(copy: false);
    await limiter.withPermit(() async {
      await for (final piece in origin.openRange(key, start, end)) {
        if (piece.isNotEmpty) builder.add(piece);
      }
    });

    final bytes = builder.takeBytes();
    if (bytes.length != expected) {
      throw OriginTruncatedException(
        key: key,
        expected: expected,
        received: bytes.length,
      );
    }

    // Publish only once the bytes are on disk: a reader must never see a chunk
    // marked ready whose contents are still buffered.
    await _writeAt(start, bytes);
    _ready.add(index);
    _metaDirty = true;
    _chunksSinceMetaWrite++;
    await persistMeta();

    log.debug(
      'chunk cached',
      fields: <String, Object?>{
        'key': key,
        'chunk': index,
        'bytes': bytes.length,
        'ready': _ready.length,
        'of': chunkCountFor(totalSize, chunkSize),
      },
    );

    return bytes;
  }

  Future<Uint8List> _readChunkFromDisk(int index) async {
    final totalSize = _totalSize ?? await resolveTotalSize();
    final start = index * chunkSize;
    final end = math.min(start + chunkSize, totalSize);

    final builder = BytesBuilder(copy: false);
    await for (final piece in dataFile.openRead(start, end)) {
      builder.add(piece);
    }
    return builder.takeBytes();
  }

  Set<int> _decodeBitmap(String bitmap, int totalSize) {
    try {
      return decodeChunkBitmap(bitmap, chunkCountFor(totalSize, chunkSize));
    } on FormatException {
      return <int>{};
    }
  }
}

/// Disk-backed chunk cache for proxied media.
///
/// Each object gets a preallocated `<key>.bin` file plus a `<key>.meta.json`
/// progress file, laid out so the object key mirrors onto the cache directory.
/// Mirroring (rather than hashing) keeps the cache browsable and makes key
/// collisions structurally impossible; [sanitizeKey] validates the key before
/// it ever reaches the filesystem.
class DiskCache {
  /// Creates a cache rooted at [root].
  ///
  /// The cache does not take ownership of [origin]; whoever created the client
  /// is responsible for closing it.
  DiskCache({
    required Directory root,
    required this.chunkSize,
    required this.origin,
    int maxConcurrentUpstream = 4,
    Logger? log,
  }) : _root = root,
       _log = (log ?? rootLogger).child('cache'),
       limiter = Semaphore(maxConcurrentUpstream);

  final Directory _root;
  final Logger _log;

  /// Chunk granularity applied to new entries.
  final int chunkSize;

  /// Where missing bytes come from.
  final OriginClient origin;

  /// Caps concurrent upstream range requests across every entry.
  final Semaphore limiter;

  final Map<String, CacheEntry> _entries = <String, CacheEntry>{};

  /// Root directory holding the cached objects.
  Directory get root => _root;

  /// Returns the entry for [key], creating it (and loading any metadata left by
  /// a previous process) on first use.
  Future<CacheEntry> entryFor(String key) async {
    final safeKey = sanitizeKey(key);
    if (safeKey == null) {
      throw ArgumentError.value(key, 'key', 'is not a safe object key');
    }

    final existing = _entries[safeKey];
    if (existing != null) return existing;

    final files = _filesFor(safeKey);
    final entry = CacheEntry(
      key: safeKey,
      chunkSize: chunkSize,
      dataFile: files.data,
      metaFile: files.meta,
      origin: origin,
      limiter: limiter,
      log: _log,
      meta: await _readMeta(files.meta, safeKey),
    );

    _entries[safeKey] = entry;
    return entry;
  }

  /// Flushes metadata and releases every open file handle.
  Future<void> close() async {
    for (final entry in _entries.values.toList(growable: false)) {
      await entry.dispose();
    }
    _entries.clear();
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

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
    final dataPath = p.join(directory, '$leaf.bin');

    return (
      data: File(dataPath),
      meta: File(
        '${dataPath.substring(0, dataPath.length - '.bin'.length)}.meta.json',
      ),
    );
  }
}
