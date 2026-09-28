import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:proxy_video/proxy_video.dart';

/// [OriginClient] that serves its first range request immediately and blocks
/// every one after that until [gate] is completed.
///
/// This is how progressive playback is proven without relying on timing: the
/// first chunk resolves, so bytes can reach the client, while every later chunk
/// is still parked. A proxy that buffered the whole window before replying
/// would never produce a first byte at all.
class GatedOrigin implements OriginClient {
  GatedOrigin(
    this.bytes, {
    this.contentType = 'video/mp4',
    this.pieceSize = 16 * 1024,
  });

  /// Bytes served for every key.
  final Uint8List bytes;

  /// Content type advertised by [head].
  final String contentType;

  /// Largest piece emitted per stream event.
  final int pieceSize;

  /// Completed by the test to release the blocked requests.
  final Completer<void> gate = Completer<void>();

  /// Ranges that were requested while the gate was closed.
  final List<ByteRange> blocked = <ByteRange>[];

  /// Number of `head` calls served.
  int headCount = 0;

  /// Number of `openRange` calls served.
  int rangeRequestCount = 0;

  @override
  Future<OriginMetadata?> head(String key) async {
    headCount++;
    return OriginMetadata(
      totalSize: bytes.length,
      etag: '"gated"',
      contentType: contentType,
    );
  }

  @override
  Stream<List<int>> openRange(String key, int start, int end) async* {
    rangeRequestCount++;
    if (rangeRequestCount > 1) {
      blocked.add(ByteRange(start, end));
      await gate.future;
    }

    var offset = start;
    while (offset <= end) {
      final size = math.min(pieceSize, end - offset + 1);
      yield Uint8List.sublistView(bytes, offset, offset + size);
      offset += size;
    }
  }

  @override
  void close() {}
}

/// Builds a deterministic payload where every byte depends on its offset, so a
/// mis-sliced range shows up as a mismatch instead of silently matching.
///
/// [seed] shifts every byte, which lets a test publish "the same object with
/// new content" without changing its size.
Uint8List makePayload(int size, {int seed = 0}) {
  final data = Uint8List(size);
  for (var index = 0; index < size; index++) {
    data[index] = (index * 31 + (index >> 8) + seed) & 0xFF;
  }
  return data;
}

/// In-memory [OriginClient] for tests.
///
/// Counts the requests it serves so cache-hit assertions can be exact, and can
/// be made slow enough to expose concurrency bugs.
class FakeOrigin implements OriginClient {
  FakeOrigin(
    this.bytes, {
    this.etag,
    this.contentType = 'video/mp4',
    this.missing = false,
    this.latency = Duration.zero,
    this.maxPieceSize = 64 * 1024,
  });

  /// Bytes served for every key.
  Uint8List bytes;

  /// Entity tag advertised by [head]; `null` means the origin exposes none.
  String? etag;

  /// Content type advertised by [head].
  String contentType;

  /// When true every request reports the object as missing.
  bool missing;

  /// Delay applied before each emitted piece.
  Duration latency;

  /// Largest piece emitted per stream event.
  int maxPieceSize;

  /// Number of `head` calls served.
  int headCount = 0;

  /// Number of `openRange` calls served.
  int rangeRequestCount = 0;

  /// Inclusive ranges requested, in call order.
  final List<ByteRange> requestedRanges = <ByteRange>[];

  @override
  Future<OriginMetadata?> head(String key) async {
    headCount++;
    if (missing) return null;
    return OriginMetadata(
      totalSize: bytes.length,
      etag: etag,
      contentType: contentType,
      lastModified: DateTime.utc(2026, 1, 1),
    );
  }

  @override
  Stream<List<int>> openRange(String key, int start, int end) async* {
    rangeRequestCount++;
    requestedRanges.add(ByteRange(start, end));

    if (missing) throw OriginNotFoundException(key);

    var offset = start;
    while (offset <= end) {
      if (latency > Duration.zero) {
        await Future<void>.delayed(latency);
      }
      final size = math.min(maxPieceSize, end - offset + 1);
      yield Uint8List.sublistView(bytes, offset, offset + size);
      offset += size;
    }
  }

  @override
  void close() {}
}
