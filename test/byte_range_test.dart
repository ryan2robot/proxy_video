import 'package:proxy_video/proxy_video.dart';
import 'package:test/test.dart';

RangeParseResult parse(String? header, int totalSize) =>
    RangeParseResult.parse(header, totalSize);

void main() {
  group('RangeParseResult.parse — no range', () {
    test('treats a missing header as a full-body request', () {
      final result = parse(null, 1000);

      expect(result.kind, RangeParseKind.none);
      expect(result.range, isNull);
    });

    test('treats a blank header as a full-body request', () {
      expect(parse('   ', 1000).kind, RangeParseKind.none);
    });
  });

  group('RangeParseResult.parse — satisfiable', () {
    test('bytes=0- asks for everything', () {
      final result = parse('bytes=0-', 1000);

      expect(result.kind, RangeParseKind.satisfiable);
      expect(result.range, const ByteRange(0, 999));
      expect(result.range!.length, 1000);
    });

    test('bytes=s-e is inclusive on both ends', () {
      expect(parse('bytes=0-99', 1000).range, const ByteRange(0, 99));
      expect(parse('bytes=900-999', 1000).range, const ByteRange(900, 999));
      expect(parse('bytes=10-10', 1000).range, const ByteRange(10, 10));
    });

    test('bytes=s- runs to the end of the resource', () {
      expect(parse('bytes=500-', 1000).range, const ByteRange(500, 999));
      expect(parse('bytes=999-', 1000).range, const ByteRange(999, 999));
    });

    test('bytes=-N returns the trailing N bytes', () {
      expect(parse('bytes=-100', 1000).range, const ByteRange(900, 999));
      expect(parse('bytes=-1', 1000).range, const ByteRange(999, 999));
    });

    test('a suffix longer than the resource yields the whole resource', () {
      expect(parse('bytes=-5000', 1000).range, const ByteRange(0, 999));
    });

    test('an end past the last byte is clamped', () {
      expect(parse('bytes=990-5000', 1000).range, const ByteRange(990, 999));
    });

    test('is case-insensitive and tolerates surrounding whitespace', () {
      expect(parse('  BYTES=0-9  ', 1000).range, const ByteRange(0, 9));
      expect(parse('Bytes=0-9', 1000).range, const ByteRange(0, 9));
    });
  });

  group('RangeParseResult.parse — unsatisfiable (416)', () {
    test('a start past the end is unsatisfiable', () {
      expect(parse('bytes=1000-', 1000).kind, RangeParseKind.unsatisfiable);
      expect(parse('bytes=1000-2000', 1000).kind, RangeParseKind.unsatisfiable);
      expect(parse('bytes=5000-6000', 1000).kind, RangeParseKind.unsatisfiable);
    });

    test('a suffix-length of zero matches no byte', () {
      expect(parse('bytes=-0', 1000).kind, RangeParseKind.unsatisfiable);
    });

    test('a zero-length resource cannot satisfy any range', () {
      expect(parse('bytes=0-', 0).kind, RangeParseKind.unsatisfiable);
      expect(parse('bytes=-10', 0).kind, RangeParseKind.unsatisfiable);
      expect(parse('bytes=-0', 0).kind, RangeParseKind.unsatisfiable);
    });

    test('reports the unsatisfied range as bytes */total', () {
      expect(RangeParseResult.unsatisfiedContentRange(1000), 'bytes */1000');
      expect(RangeParseResult.unsatisfiedContentRange(0), 'bytes */0');
    });
  });

  group('RangeParseResult.parse — degrade to a full 200 body', () {
    test('ignores an unknown range unit', () {
      final result = parse('items=0-10', 1000);

      expect(result.kind, RangeParseKind.ignore);
      expect(result.range, isNull);
      expect(result.note, contains('unsupported range unit'));
    });

    test('ignores multiple ranges', () {
      final result = parse('bytes=0-99,200-299', 1000);

      expect(result.kind, RangeParseKind.ignore);
      expect(result.note, contains('multi-range'));
    });

    test('ignores an inverted range', () {
      expect(parse('bytes=100-50', 1000).kind, RangeParseKind.ignore);
    });

    test('ignores non-numeric bounds', () {
      expect(parse('bytes=abc-def', 1000).kind, RangeParseKind.ignore);
      expect(parse('bytes=0-abc', 1000).kind, RangeParseKind.ignore);
      expect(parse('bytes=abc-', 1000).kind, RangeParseKind.ignore);
    });

    test('ignores a structurally broken header', () {
      expect(parse('bytes=', 1000).kind, RangeParseKind.ignore);
      expect(parse('bytes=0100', 1000).kind, RangeParseKind.ignore);
      expect(parse('bytes=-', 1000).kind, RangeParseKind.ignore);
      expect(parse('bytes=,', 1000).kind, RangeParseKind.ignore);
    });
  });

  group('ByteRange', () {
    test('renders a Content-Range header', () {
      expect(const ByteRange(0, 99).contentRange(1000), 'bytes 0-99/1000');
      expect(const ByteRange(0, 999).contentRange(1000), 'bytes 0-999/1000');
    });

    test('reports its length', () {
      expect(const ByteRange(0, 0).length, 1);
      expect(const ByteRange(0, 99).length, 100);
    });

    test('compares by value', () {
      expect(const ByteRange(1, 2), const ByteRange(1, 2));
      expect(const ByteRange(1, 2), isNot(const ByteRange(1, 3)));
    });
  });
}
