import 'package:proxy_video/proxy_video.dart';
import 'package:test/test.dart';

void main() {
  group('sanitizeKey', () {
    test('accepts ordinary object keys', () {
      expect(sanitizeKey('demo.mp4'), 'demo.mp4');
      expect(sanitizeKey('clips/demo.mp4'), 'clips/demo.mp4');
      expect(sanitizeKey('a/b/c/take_01.MP4'), 'a/b/c/take_01.MP4');
      expect(sanitizeKey('  clips/demo.mp4  '), 'clips/demo.mp4');
    });

    test('normalises separators and leading slashes', () {
      expect(sanitizeKey(r'clips\demo.mp4'), 'clips/demo.mp4');
      expect(sanitizeKey('/clips/demo.mp4'), 'clips/demo.mp4');
      expect(sanitizeKey('///clips/demo.mp4'), 'clips/demo.mp4');
    });

    test('rejects directory traversal', () {
      expect(sanitizeKey('../escape.mp4'), isNull);
      expect(sanitizeKey('a/../../b.mp4'), isNull);
      expect(sanitizeKey('a/..'), isNull);
      expect(sanitizeKey('a/.'), isNull);
      expect(sanitizeKey(r'..\..\windows\system32\config'), isNull);
    });

    test('rejects absolute and drive-qualified paths', () {
      expect(sanitizeKey(r'C:\windows\system32\evil.mp4'), isNull);
      expect(sanitizeKey('C:/windows/evil.mp4'), isNull);
    });

    test('rejects empty segments, empty keys and odd characters', () {
      expect(sanitizeKey(''), isNull);
      expect(sanitizeKey('   '), isNull);
      expect(sanitizeKey('a//b.mp4'), isNull);
      expect(sanitizeKey('clips/'), isNull);
      expect(sanitizeKey('a b.mp4'), isNull);
      expect(sanitizeKey('a%20b.mp4'), isNull);
      expect(sanitizeKey('a?b.mp4'), isNull);
      expect(sanitizeKey('.hidden.mp4'), isNull);
      expect(sanitizeKey('-leading-dash.mp4'), isNull);
    });

    test('rejects names the host filesystem cannot represent', () {
      expect(sanitizeKey('con.mp4'), isNull);
      expect(sanitizeKey('clips/nul'), isNull);
      expect(sanitizeKey('clips/com1.mp4'), isNull);
      expect(sanitizeKey('clips/lpt9.mp4'), isNull);
      expect(sanitizeKey('demo.'), isNull);
      expect(sanitizeKey('clips/trailing.'), isNull);
    });

    test('accepts names that merely contain a reserved name', () {
      expect(sanitizeKey('console.mp4'), 'console.mp4');
      expect(sanitizeKey('null-and-void.mp4'), 'null-and-void.mp4');
      expect(sanitizeKey('clips/aux_2.mp4'), 'clips/aux_2.mp4');
      expect(sanitizeKey('clips/demo.v2.mp4'), 'clips/demo.v2.mp4');
    });

    test('rejects keys longer than the limit', () {
      expect(sanitizeKey('a' * kMaxKeyLength), isNotNull);
      expect(sanitizeKey('a' * (kMaxKeyLength + 1)), isNull);
    });

    test('isValidKey mirrors sanitizeKey', () {
      expect(isValidKey('clips/demo.mp4'), isTrue);
      expect(isValidKey('../demo.mp4'), isFalse);
    });
  });

  group('contentTypeForPath', () {
    test('maps the media extensions this proxy serves', () {
      expect(contentTypeForPath('clips/demo.mp4'), 'video/mp4');
      expect(contentTypeForPath('clips/demo.MP4'), 'video/mp4');
      expect(contentTypeForPath('clips/demo.m4v'), 'video/x-m4v');
      expect(contentTypeForPath('clips/demo.webm'), 'video/webm');
      expect(contentTypeForPath('audio/track.m4a'), 'audio/mp4');
      expect(contentTypeForPath('subs/demo.vtt'), 'text/vtt; charset=utf-8');
    });

    test('falls back to a binary stream for unknown extensions', () {
      expect(
        contentTypeForPath('clips/demo.unknown'),
        'application/octet-stream',
      );
      expect(contentTypeForPath('clips/demo'), 'application/octet-stream');
    });
  });

  group('makeEtag', () {
    test('is quoted and stable for the same size and time', () {
      final modified = DateTime.utc(2026, 9, 28, 12);
      final first = makeEtag(1024, modified);

      expect(first, startsWith('"'));
      expect(first, endsWith('"'));
      expect(makeEtag(1024, modified), first);
      expect(makeEtag(2048, modified), isNot(first));
      expect(makeEtag(1024, DateTime.utc(2026, 9, 28, 13)), isNot(first));
    });
  });

  group('HTTP dates', () {
    test('formats an IMF-fixdate', () {
      expect(
        formatHttpDate(DateTime.utc(2026, 9, 28, 12, 0, 0)),
        'Mon, 28 Sep 2026 12:00:00 GMT',
      );
      expect(
        formatHttpDate(DateTime.utc(2026, 1, 3, 4, 5, 6)),
        'Sat, 03 Jan 2026 04:05:06 GMT',
      );
    });

    test('converts non-UTC input to GMT', () {
      final local = DateTime.utc(2026, 9, 28, 12).toLocal();
      expect(formatHttpDate(local), 'Mon, 28 Sep 2026 12:00:00 GMT');
    });

    test('round-trips through parseHttpDate', () {
      final parsed = parseHttpDate('Mon, 28 Sep 2026 12:00:00 GMT');

      expect(parsed, DateTime.utc(2026, 9, 28, 12));
      expect(formatHttpDate(parsed!), 'Mon, 28 Sep 2026 12:00:00 GMT');
    });

    test('returns null for malformed dates', () {
      expect(parseHttpDate(null), isNull);
      expect(parseHttpDate('yesterday'), isNull);
      expect(parseHttpDate('Mon, 28 Foo 2026 12:00:00 GMT'), isNull);
      expect(parseHttpDate('2026-09-28T12:00:00Z'), isNull);
    });
  });
}
