/// Parses a human readable byte size such as `1048576`, `512K`, `1M`, `2G`.
///
/// [label] is only used to build a helpful error message (for example
/// `--max-cache-bytes`).
int parseByteSize(String input, {String label = 'value'}) {
  final raw = input.trim();
  final match = RegExp(
    r'^(\d+)\s*([kmgt]?)b?$',
    caseSensitive: false,
  ).firstMatch(raw);

  if (match == null) {
    throw FormatException(
      'Invalid size for $label: "$input" '
      '(expected a number with an optional unit, e.g. 1048576, 512K, 1M, 2G)',
    );
  }

  final amount = int.parse(match.group(1)!);
  final unit = match.group(2)!.toLowerCase();
  final multiplier = switch (unit) {
    '' => 1,
    'k' => 1 << 10,
    'm' => 1 << 20,
    'g' => 1 << 30,
    't' => 1 << 40,
    _ => throw FormatException('Invalid size unit "$unit" for $label'),
  };

  return amount * multiplier;
}

const List<String> _sizeUnits = <String>['KiB', 'MiB', 'GiB', 'TiB'];

/// Renders [bytes] using binary units, e.g. `1.50 MiB`.
String formatByteSize(int bytes) {
  if (bytes < 0) return '$bytes B';
  if (bytes < 1024) return '$bytes B';

  var value = bytes / 1024;
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < _sizeUnits.length - 1) {
    value /= 1024;
    unitIndex++;
  }

  final text = value >= 100
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(2);
  return '$text ${_sizeUnits[unitIndex]}';
}
