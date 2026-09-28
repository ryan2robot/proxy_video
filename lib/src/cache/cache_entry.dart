import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../logger.dart';
import '../util/async_mutex.dart';
import '../util/semaphore.dart';
import 'origin_client.dart';

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

/// Number of set bits in a base64 chunk bitmap.
int countChunkBitmapBits(String bitmap) {
  if (bitmap.isEmpty) return 0;
  var total = 0;
  for (final byte in base64Decode(bitmap.trim())) {
    var value = byte;
    while (value != 0) {
      total += value & 1;
      value >>= 1;
    }
  }
  return total;
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
    this.updatedAt,
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

  /// When this metadata was last written.
  final DateTime? updatedAt;

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
    if (updatedAt != null) 'updatedAt': updatedAt!.toUtc().toIso8601String(),
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
      final updatedAt = decoded['updatedAt'];
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
        updatedAt: updatedAt is String ? DateTime.tryParse(updatedAt) : null,
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
///   fetch (single flight), which is what keeps a browser's burst of range
///   requests from multiplying into a burst of origin traffic;
/// * the bytes of a freshly downloaded chunk are handed back to the caller, so
///   the first consumer never pays a second disk read for data already in
///   memory.
class CacheEntry {
  CacheEntry({
    required this.key,
    required this.chunkSize,
    required this.dataFile,
    required this.metaFile,
    required this.origin,
    required this.limiter,
    required this.log,
    this.prefetchAhead = 0,
    this.onChunkCached,
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

  /// How many chunks to speculatively fetch after the one being read.
  final int prefetchAhead;

  /// Invoked after a chunk lands on disk, used for budget enforcement.
  final void Function(CacheEntry entry)? onChunkCached;

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
  DateTime _lastAccessAt = DateTime.now();
  DateTime _lastMetaWrite = DateTime.utc(1970);
  int _chunksSinceMetaWrite = 0;
  int _activeReaders = 0;
  int _upstreamRequestCount = 0;
  int _cacheHits = 0;
  int _cacheMisses = 0;
  bool _backingPrepared = false;
  bool _metaDirty = false;

  /// Total object size, when it is already known.
  int? get knownTotalSize => _totalSize;

  /// Number of chunks that a full download of this object requires.
  int get chunkCount =>
      _totalSize == null ? 0 : chunkCountFor(_totalSize!, chunkSize);

  /// Number of chunks already on disk.
  int get readyChunkCount => _ready.length;

  /// Bytes actually available offline.
  int get cachedBytes {
    final total = _totalSize;
    if (total == null) return 0;
    return math.min(_ready.length * chunkSize, total);
  }

  /// Whether every chunk of the object is on disk.
  bool get isComplete => _totalSize != null && _ready.length == chunkCount;

  /// When this entry was last used, driving LRU eviction.
  DateTime get lastAccessAt => _lastAccessAt;

  /// Whether work is in progress that must not be interrupted by eviction.
  bool get isBusy =>
      _activeReaders > 0 ||
      _inflight.isNotEmpty ||
      _totalSizeRequest != null ||
      !_writeMutex.isIdle;

  /// Range requests this entry has issued to the origin.
  ///
  /// This is the number that proves a cache is working: it must stay flat while
  /// playback continues.
  int get upstreamRequestCount => _upstreamRequestCount;

  /// Served windows that were already complete on disk.
  int get cacheHits => _cacheHits;

  /// Served windows that needed at least one chunk from the origin.
  int get cacheMisses => _cacheMisses;

  /// Fraction of served windows answered without touching the origin, or
  /// `null` before anything has been served.
  double? get cacheHitRate {
    final total = _cacheHits + _cacheMisses;
    return total == 0 ? null : _cacheHits / total;
  }

  /// Records how one served window was answered.
  void recordServe({required bool wasCached}) {
    if (wasCached) {
      _cacheHits++;
    } else {
      _cacheMisses++;
    }
  }

  /// Origin content type, when known.
  String? get contentType => _contentType;

  /// Origin entity tag, when known.
  String? get etag => _etag;

  /// Origin modification time, when known.
  DateTime? get lastModified => _lastModified;

  /// Marks the entry as recently used.
  void touch() => _lastAccessAt = DateTime.now();

  /// Base64 bitmap of cached chunks, for the stats API and debug UI.
  String chunkBitmapBase64() =>
      encodeChunkBitmap(_ready, _totalSize == null ? 0 : chunkCount);

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

    touch();
    _activeReaders++;
    try {
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

        if (prefetchAhead > 0) _schedulePrefetch(index + 1);
      }
    } finally {
      _activeReaders--;
      _lastAccessAt = DateTime.now();
    }
  }

  /// Makes chunk [index] available, returning its bytes.
  ///
  /// Concurrent calls for the same chunk share one upstream request.
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

  /// Whether every byte of [start]..[end] is already on disk.
  bool isRangeCached(int start, int end) =>
      firstUncachedOffset(start, end) == null;

  /// Offset of the first byte in `[start, end]` that is not on disk yet, or
  /// `null` when the entire window is cached.
  ///
  /// Callers use this to resume filling after a client walked away: re-fetching
  /// the part that already landed would double the origin traffic for no gain.
  int? firstUncachedOffset(int start, int end) {
    final total = _totalSize;
    if (total == null) return math.max(0, start);

    final from = math.max(0, start);
    final to = math.min(end, total - 1);
    if (from > to) return null;

    for (var index = from ~/ chunkSize; index <= to ~/ chunkSize; index++) {
      if (!_ready.contains(index)) return math.max(from, index * chunkSize);
    }
    return null;
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
        updatedAt: _lastMetaWrite,
      );

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

  /// Deletes the backing and metadata files.
  Future<void> deleteFiles() async {
    await _closeWriteHandle();
    _ready.clear();
    _backingPrepared = false;
    if (dataFile.existsSync()) await dataFile.delete();
    if (metaFile.existsSync()) await metaFile.delete();
    final scratch = File('${metaFile.path}.tmp');
    if (scratch.existsSync()) await scratch.delete();
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
    _upstreamRequestCount++;
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
        'of': chunkCount,
      },
    );

    onChunkCached?.call(this);
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

  /// Speculatively fills the next few chunks so a sequential viewer stays ahead
  /// of playback without waiting for the browser to ask.
  void _schedulePrefetch(int fromIndex) {
    final totalSize = _totalSize;
    if (totalSize == null) return;

    final limit = math.min(
      fromIndex + prefetchAhead,
      chunkCountFor(totalSize, chunkSize),
    );
    if (fromIndex >= limit) return;

    // Leave headroom for demand traffic: a prefetch that occupies the last
    // permit would delay the next chunk the player actually needs.
    if (limiter.available <= 1) return;

    unawaited(() async {
      for (var index = fromIndex; index < limit; index++) {
        if (_ready.contains(index)) continue;
        try {
          await ensureChunk(index);
        } on Object catch (error) {
          log.debug(
            'prefetch stopped',
            fields: <String, Object?>{
              'key': key,
              'chunk': index,
              'error': error,
            },
          );
          return;
        }
      }
    }());
  }

  Set<int> _decodeBitmap(String bitmap, int totalSize) {
    try {
      return decodeChunkBitmap(bitmap, chunkCountFor(totalSize, chunkSize));
    } on FormatException {
      return <int>{};
    }
  }
}
