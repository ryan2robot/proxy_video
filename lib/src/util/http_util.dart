import 'package:path/path.dart' as p;

/// Characters allowed inside one path segment of an object key.
///
/// Keys arrive from URLs, so they are the untrusted boundary: allowing only
/// this set (and rejecting `.`/`..`) makes directory traversal impossible
/// without further escaping.
final RegExp _segmentPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');

/// Maximum accepted key length, short enough to stay within Windows path
/// limits once a cache directory prefix is added.
const int kMaxKeyLength = 400;

/// Names Windows refuses to use as a file name component, with or without an
/// extension.
///
/// Keys are mapped onto real files by the disk cache, so rejecting these up
/// front keeps the on-disk layout identical on every platform.
const Set<String> kReservedFileNames = <String>{
  'con', 'prn', 'aux', 'nul', //
  'com1', 'com2', 'com3', 'com4', 'com5', 'com6', 'com7', 'com8', 'com9',
  'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5', 'lpt6', 'lpt7', 'lpt8', 'lpt9',
};

/// Normalises and validates an object key, returning `null` when it is unsafe.
///
/// Accepts `clips/demo.mp4`, rejects `/abs/path`, `../escape`, `a//b` and
/// anything containing characters outside `[A-Za-z0-9._-]`.
String? sanitizeKey(String raw) {
  var key = raw.trim().replaceAll(r'\', '/');
  while (key.startsWith('/')) {
    key = key.substring(1);
  }
  if (key.isEmpty || key.length > kMaxKeyLength) return null;

  // An empty segment covers a trailing slash and a doubled separator, both of
  // which would otherwise collapse into a different key once joined.
  for (final segment in key.split('/')) {
    if (segment.isEmpty || segment == '.' || segment == '..') return null;
    if (!_segmentPattern.hasMatch(segment)) return null;
    // Windows silently strips a trailing dot, which would map two distinct keys
    // onto the same file.
    if (segment.endsWith('.')) return null;
    if (kReservedFileNames.contains(segment.split('.').first.toLowerCase())) {
      return null;
    }
  }

  return key;
}

/// Whether [key] is a safe object key.
bool isValidKey(String key) => sanitizeKey(key) != null;

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
/// Video is the point of this proxy; for anything unknown the browser is better
/// served by `application/octet-stream` than by a guess.
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
