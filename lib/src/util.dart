import 'dart:async';
import 'dart:collection';

import 'package:path/path.dart' as p;

// ---------------------------------------------------------------------------
// Range headers
// ---------------------------------------------------------------------------

/// How an incoming `Range` header should be answered.
enum RangeParseKind {
  /// No `Range` header: answer `200` with the whole representation.
  none,

  /// Malformed or multi-range: RFC 9110 allows ignoring it and answering `200`.
  ignore,

  /// A single satisfiable range: answer `206` with that slice.
  satisfiable,

  /// Entirely past the end of the resource: answer `416`.
  unsatisfiable,
}

/// Inclusive byte interval `[start, end]`.
class ByteRange {
  const ByteRange(this.start, this.end);

  /// First byte, inclusive.
  final int start;

  /// Last byte, inclusive.
  final int end;

  /// Number of bytes covered by this interval.
  int get length => end - start + 1;

  /// Value for the `Content-Range` header of a `206` response.
  String contentRange(int totalSize) => 'bytes $start-$end/$totalSize';

  @override
  bool operator ==(Object other) =>
      other is ByteRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => '$start-$end';
}

/// Outcome of interpreting a `Range` header against a known resource size.
class RangeParseResult {
  const RangeParseResult._(this.kind, this.range, this.note);

  /// What the caller should do.
  final RangeParseKind kind;

  /// Slice to serve, present only when [kind] is [RangeParseKind.satisfiable].
  final ByteRange? range;

  /// Why a header was ignored or rejected, surfaced in logs.
  final String? note;

  /// Value for the `Content-Range` header of a `416` response.
  static String unsatisfiedContentRange(int totalSize) => 'bytes */$totalSize';

  /// Interprets [header] against a resource of [totalSize] bytes.
  ///
  /// Supports `bytes=0-`, `bytes=s-e` and the suffix form `bytes=-N`; anything
  /// else degrades to `200` with the full body, which a `Range` header always
  /// permits.
  static RangeParseResult parse(String? header, int totalSize) {
    final size = totalSize < 0 ? 0 : totalSize;
    final raw = header?.trim();

    if (raw == null || raw.isEmpty) {
      return const RangeParseResult._(
        RangeParseKind.none,
        null,
        'no Range header',
      );
    }

    if (!raw.toLowerCase().startsWith('bytes=')) {
      return RangeParseResult._(
        RangeParseKind.ignore,
        null,
        'unsupported range unit in "$raw"',
      );
    }

    final spec = raw.substring('bytes='.length).trim();
    if (spec.isEmpty) {
      return const RangeParseResult._(
        RangeParseKind.ignore,
        null,
        'empty range spec',
      );
    }

    final segments = spec
        .split(',')
        .map((String segment) => segment.trim())
        .where((String segment) => segment.isNotEmpty)
        .toList(growable: false);

    if (segments.length != 1) {
      return RangeParseResult._(
        RangeParseKind.ignore,
        null,
        'multi-range request (${segments.length} ranges)',
      );
    }

    final segment = segments.single;
    final dash = segment.indexOf('-');
    if (dash < 0) {
      return RangeParseResult._(
        RangeParseKind.ignore,
        null,
        'missing "-" in "$segment"',
      );
    }

    final firstText = segment.substring(0, dash).trim();
    final lastText = segment.substring(dash + 1).trim();

    if (firstText.isEmpty && lastText.isEmpty) {
      return RangeParseResult._(
        RangeParseKind.ignore,
        null,
        'empty range "$segment"',
      );
    }

    if (firstText.isEmpty) {
      // Suffix form `bytes=-N`: the trailing N bytes.
      final suffixLength = int.tryParse(lastText);
      if (suffixLength == null) {
        return RangeParseResult._(
          RangeParseKind.ignore,
          null,
          'non-numeric suffix "$lastText"',
        );
      }
      if (suffixLength == 0) {
        return const RangeParseResult._(
          RangeParseKind.unsatisfiable,
          null,
          'suffix-length 0 matches no byte',
        );
      }
      if (size == 0) {
        return const RangeParseResult._(
          RangeParseKind.unsatisfiable,
          null,
          'no bytes to satisfy a suffix range',
        );
      }
      final start = suffixLength >= size ? 0 : size - suffixLength;
      return RangeParseResult._(
        RangeParseKind.satisfiable,
        ByteRange(start, size - 1),
        null,
      );
    }

    final start = int.tryParse(firstText);
    if (start == null) {
      return RangeParseResult._(
        RangeParseKind.ignore,
        null,
        'non-numeric start "$firstText"',
      );
    }

    if (lastText.isEmpty) {
      // Open ended form `bytes=N-`.
      if (start >= size) {
        return RangeParseResult._(
          RangeParseKind.unsatisfiable,
          null,
          'start $start is past the end of a $size byte resource',
        );
      }
      return RangeParseResult._(
        RangeParseKind.satisfiable,
        ByteRange(start, size - 1),
        null,
      );
    }

    final end = int.tryParse(lastText);
    if (end == null) {
      return RangeParseResult._(
        RangeParseKind.ignore,
        null,
        'non-numeric end "$lastText"',
      );
    }
    if (end < start) {
      return RangeParseResult._(
        RangeParseKind.ignore,
        null,
        'inverted range "$segment"',
      );
    }
    if (start >= size) {
      return RangeParseResult._(
        RangeParseKind.unsatisfiable,
        null,
        'start $start is past the end of a $size byte resource',
      );
    }
    return RangeParseResult._(
      RangeParseKind.satisfiable,
      ByteRange(start, end >= size ? size - 1 : end),
      null,
    );
  }

  @override
  String toString() => switch (kind) {
    RangeParseKind.none => 'no-range',
    RangeParseKind.ignore => 'ignored($note)',
    RangeParseKind.satisfiable => 'satisfiable($range)',
    RangeParseKind.unsatisfiable => 'unsatisfiable($note)',
  };
}

// ---------------------------------------------------------------------------
// Object keys, content types, HTTP dates
// ---------------------------------------------------------------------------

/// Characters allowed inside one path segment of an object key.
final RegExp _segmentPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');

/// Maximum accepted key length, keeping cache paths within Windows limits.
const int kMaxKeyLength = 400;

/// File names Windows refuses to use, with or without an extension.
const Set<String> kReservedFileNames = <String>{
  'con', 'prn', 'aux', 'nul', //
  'com1', 'com2', 'com3', 'com4', 'com5', 'com6', 'com7', 'com8', 'com9',
  'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5', 'lpt6', 'lpt7', 'lpt8', 'lpt9',
};

/// Normalises and validates an object key, returning `null` when it is unsafe.
///
/// Keys are the untrusted boundary: every segment must be non-empty, avoid
/// `.`/`..`, use only `[A-Za-z0-9._-]`, not end in a dot and not be a name the
/// host filesystem silently reinterprets. That keeps the key and the on-disk
/// path in one-to-one correspondence.
String? sanitizeKey(String raw) {
  var key = raw.trim().replaceAll(r'\', '/');
  while (key.startsWith('/')) {
    key = key.substring(1);
  }
  if (key.isEmpty || key.length > kMaxKeyLength) return null;

  for (final segment in key.split('/')) {
    if (segment.isEmpty || segment == '.' || segment == '..') return null;
    if (!_segmentPattern.hasMatch(segment)) return null;
    if (segment.endsWith('.')) return null;
    if (kReservedFileNames.contains(segment.split('.').first.toLowerCase())) {
      return null;
    }
  }

  return key;
}

const Map<String, String> _contentTypes = <String, String>{
  '.mp4': 'video/mp4',
  '.m4v': 'video/x-m4v',
  '.mov': 'video/quicktime',
  '.webm': 'video/webm',
  '.mkv': 'video/x-matroska',
  '.avi': 'video/x-msvideo',
  '.mp3': 'audio/mpeg',
  '.m4a': 'audio/mp4',
  '.aac': 'audio/aac',
  '.wav': 'audio/wav',
  '.ogg': 'audio/ogg',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.png': 'image/png',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
  '.vtt': 'text/vtt; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
};

/// Content type for [pathOrKey], defaulting to a binary stream.
///
/// For unknown extensions a guess is worse than `application/octet-stream`.
String contentTypeForPath(String pathOrKey) {
  final extension = p.extension(pathOrKey).toLowerCase();
  return _contentTypes[extension] ?? 'application/octet-stream';
}

const List<String> _weekdays = <String>[
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];

const List<String> _months = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// Formats [time] as an IMF-fixdate, e.g. `Sun, 28 Sep 2026 12:00:00 GMT`.
String formatHttpDate(DateTime time) {
  final utc = time.toUtc();
  final weekday = _weekdays[utc.weekday - 1];
  final month = _months[utc.month - 1];
  final day = utc.day.toString().padLeft(2, '0');
  final year = utc.year.toString().padLeft(4, '0');
  final clock =
      '${utc.hour.toString().padLeft(2, '0')}:'
      '${utc.minute.toString().padLeft(2, '0')}:'
      '${utc.second.toString().padLeft(2, '0')}';
  return '$weekday, $day $month $year $clock GMT';
}

final RegExp _httpDatePattern = RegExp(
  r'^[A-Za-z]{3}, (\d{2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$',
);

/// Parses an IMF-fixdate header value, returning `null` when malformed.
DateTime? parseHttpDate(String? header) {
  if (header == null) return null;
  final match = _httpDatePattern.firstMatch(header.trim());
  if (match == null) return null;

  final monthIndex = _months.indexOf(match.group(2)!);
  if (monthIndex < 0) return null;

  return DateTime.utc(
    int.parse(match.group(3)!),
    monthIndex + 1,
    int.parse(match.group(1)!),
    int.parse(match.group(4)!),
    int.parse(match.group(5)!),
    int.parse(match.group(6)!),
  );
}

// ---------------------------------------------------------------------------
// Concurrency primitives
// ---------------------------------------------------------------------------

/// Counting semaphore with FIFO fairness.
///
/// Caps how many upstream range requests are in flight at once, so a browser
/// seeking through a timeline cannot open unbounded sockets.
class Semaphore {
  /// Creates a semaphore holding [capacity] permits.
  Semaphore(this.capacity)
    : assert(capacity >= 1, 'capacity must be >= 1'),
      _held = 0;

  /// Maximum number of concurrently held permits.
  final int capacity;

  final Queue<_Waiter> _waiters = Queue<_Waiter>();

  int _held;

  /// Acquires a permit, waiting in FIFO order when the semaphore is saturated.
  Future<void> acquire() {
    if (_waiters.isEmpty && _held < capacity) {
      _held++;
      return Future<void>.value();
    }

    final waiter = _Waiter();
    _waiters.add(waiter);
    return waiter.completer.future;
  }

  /// Returns a permit, handing it directly to the next waiter when present.
  ///
  /// Throws a [StateError] when called more often than [acquire] succeeded.
  void release() {
    if (_held == 0) {
      throw StateError(
        'Semaphore.release() called more times than acquire() on a '
        'semaphore with capacity $capacity',
      );
    }

    while (_waiters.isNotEmpty) {
      final waiter = _waiters.removeFirst();
      if (!waiter.completer.isCompleted) {
        // The permit is transferred rather than returned, so `_held` stays put.
        waiter.completer.complete();
        return;
      }
    }

    _held--;
  }

  /// Runs [action] while holding a permit, releasing it in all cases.
  Future<T> withPermit<T>(Future<T> Function() action) async {
    await acquire();
    try {
      return await action();
    } finally {
      release();
    }
  }
}

class _Waiter {
  final Completer<void> completer = Completer<void>();
}

/// Serialises asynchronous critical sections in FIFO order.
///
/// `RandomAccessFile` shares one file position across callers, so interleaving
/// a `setPosition` with another coroutine's `writeFrom` would corrupt the cache;
/// every offset write goes through a mutex.
class AsyncMutex {
  Future<void> _tail = Future<void>.value();

  /// Runs [action] after every previously queued section has finished.
  ///
  /// Errors propagate to the caller of this invocation only; the queue itself
  /// always keeps moving.
  Future<T> run<T>(Future<T> Function() action) {
    final previous = _tail;
    final completer = Completer<void>();
    _tail = completer.future;

    return previous
        .then((_) => action())
        .whenComplete(() => completer.complete());
  }
}
