/// How an incoming `Range` request header should be answered.
enum RangeParseKind {
  /// No `Range` header at all: answer `200` with the whole representation.
  none,

  /// The header is malformed or asks for several ranges: ignore it and answer
  /// `200` with the whole representation, which RFC 9110 explicitly allows.
  ignore,

  /// A single satisfiable range: answer `206` with that slice.
  satisfiable,

  /// The requested range lies entirely past the end: answer `416`.
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

  /// The slice to serve, present only when [kind] is
  /// [RangeParseKind.satisfiable].
  final ByteRange? range;

  /// Human readable explanation, surfaced in logs and the debug UI.
  final String? note;

  /// Whether a `416` response must be produced.
  bool get isUnsatisfiable => kind == RangeParseKind.unsatisfiable;

  /// Whether the whole representation should be sent with `200`.
  bool get wantsFullBody =>
      kind == RangeParseKind.none || kind == RangeParseKind.ignore;

  /// Value for the `Content-Range` header of a `416` response.
  static String unsatisfiedContentRange(int totalSize) => 'bytes */$totalSize';

  /// Interprets [header] against a resource of [totalSize] bytes.
  ///
  /// Supports the three shapes browsers actually send — `bytes=0-`,
  /// `bytes=s-e` and the suffix form `bytes=-N` — and degrades gracefully on
  /// everything else, because a `Range` header is advisory: answering `200`
  /// with the full body is always a valid response.
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
