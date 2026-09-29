import 'dart:io';

/// Severity of a log record.
///
/// Declaration order is meaningful: a logger configured at [LogLevel.info]
/// suppresses every record whose level compares lower ([LogLevel.debug]).
enum LogLevel {
  debug('DEBUG'),
  info('INFO '),
  warn('WARN '),
  error('ERROR');

  const LogLevel(this.label);

  /// Fixed-width label used when rendering a log line.
  final String label;
}

/// Sink for fully rendered log lines. Swappable so tests can capture output.
typedef LogOutput = void Function(String line);

/// Small structured logger.
///
/// Every line is `timestamp LEVEL [name] message key=value key=value`, which
/// keeps logs greppable without pulling in a logging framework. Binary payloads
/// and very long strings are redacted/shortened so a byte dump can never flood
/// the terminal.
class Logger {
  /// Creates a logger tagged with [name].
  Logger([String name = 'app']) : _name = name;

  final String _name;

  /// Minimum severity that gets printed.
  static LogLevel level = LogLevel.info;

  /// Where rendered lines go; `null` writes to stdout.
  static LogOutput? sink;

  /// Derives a namespaced logger, e.g. `Logger('proxy').child('cache')`.
  Logger child(String name) => Logger(_name.isEmpty ? name : '$_name.$name');

  /// Whether a record at [candidate] would be printed.
  bool isEnabled(LogLevel candidate) => candidate.index >= level.index;

  /// Logs at [LogLevel.debug].
  void debug(
    Object? message, {
    Map<String, Object?>? fields,
    Object? error,
    StackTrace? stackTrace,
  }) => _log(LogLevel.debug, message, fields, error, stackTrace);

  /// Logs at [LogLevel.info].
  void info(
    Object? message, {
    Map<String, Object?>? fields,
    Object? error,
    StackTrace? stackTrace,
  }) => _log(LogLevel.info, message, fields, error, stackTrace);

  /// Logs at [LogLevel.warn].
  void warn(
    Object? message, {
    Map<String, Object?>? fields,
    Object? error,
    StackTrace? stackTrace,
  }) => _log(LogLevel.warn, message, fields, error, stackTrace);

  /// Logs at [LogLevel.error].
  void error(
    Object? message, {
    Map<String, Object?>? fields,
    Object? error,
    StackTrace? stackTrace,
  }) => _log(LogLevel.error, message, fields, error, stackTrace);

  void _log(
    LogLevel level,
    Object? message,
    Map<String, Object?>? fields,
    Object? error,
    StackTrace? stackTrace,
  ) {
    if (!isEnabled(level)) return;

    final buffer = StringBuffer()
      ..write(_timestamp())
      ..write(' ')
      ..write(level.label)
      ..write(' [')
      ..write(_name)
      ..write('] ')
      ..write(message ?? '');

    if (fields != null) {
      for (final entry in fields.entries) {
        buffer
          ..write(' ')
          ..write(entry.key)
          ..write('=')
          ..write(_renderValue(entry.value));
      }
    }

    _emit(buffer.toString());

    if (error != null) {
      _emit('$_indent└─ $error');
    }
    if (stackTrace != null) {
      for (final line in stackTrace.toString().trimRight().split('\n')) {
        _emit('$_indent│ ${line.trimRight()}');
      }
    }
  }

  static const String _indent = '                        ';

  static void _emit(String line) => (sink ?? _writeToStdout)(line);

  static void _writeToStdout(String line) => stdout.writeln(line);

  static String _timestamp() {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-'
        '${_pad2(now.month)}-${_pad2(now.day)} '
        '${_pad2(now.hour)}:${_pad2(now.minute)}:${_pad2(now.second)}.'
        '${now.millisecond.toString().padLeft(3, '0')}';
  }

  static String _pad2(int value) => value.toString().padLeft(2, '0');

  static String _renderValue(Object? value) {
    if (value == null) return 'null';
    if (value is bool || value is num) return '$value';
    if (value is Duration) return '${value.inMilliseconds}ms';
    if (value is List<int>) return '<${value.length}B>';
    if (value is String) return _shorten(value);
    if (value is Iterable<Object?>) {
      final parts = value.map(_renderValue).join(',');
      return '[$parts]';
    }
    return _shorten(value.toString());
  }

  static String _shorten(String text) {
    final flat = text.replaceAll('\r', '').replaceAll('\n', r'\n');
    if (flat.length <= 512) return flat;
    return '${flat.substring(0, 512)}…(${flat.length} chars)';
  }
}

/// Process-wide logger used by CLI entry points and shared subsystems.
final Logger rootLogger = Logger('proxy-video');
