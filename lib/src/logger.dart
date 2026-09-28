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

  /// Parses a case-insensitive level name, returning `null` for unknown input.
  static LogLevel? tryParse(String? raw) {
    if (raw == null) return null;
    switch (raw.trim().toLowerCase()) {
      case 'debug':
        return LogLevel.debug;
      case 'info':
        return LogLevel.info;
      case 'warn':
      case 'warning':
        return LogLevel.warn;
      case 'error':
        return LogLevel.error;
      default:
        return null;
    }
  }
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

  /// Whether ANSI escape sequences are added to the rendered level.
  static bool colorEnabled = _detectColor();

  static LogOutput? _outputOverride;

  /// Replaces the output sink. Used by tests; pass `null` to restore stdout.
  static void captureOutput(LogOutput? sink) => _outputOverride = sink;

  /// Applies process-wide logging settings in one call.
  static void configure({
    LogLevel? level,
    bool? colorEnabled,
    LogOutput? output,
  }) {
    if (level != null) Logger.level = level;
    if (colorEnabled != null) Logger.colorEnabled = colorEnabled;
    if (output != null) _outputOverride = output;
  }

  /// Restores the defaults. Intended for `tearDown` in tests.
  static void reset() {
    level = LogLevel.info;
    colorEnabled = _detectColor();
    _outputOverride = null;
  }

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
      ..write(_paint(level.label, level))
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

  static void _emit(String line) => (_outputOverride ?? _writeToStdout)(line);

  static void _writeToStdout(String line) => stdout.writeln(line);

  static String _timestamp() {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-'
        '${_pad2(now.month)}-${_pad2(now.day)} '
        '${_pad2(now.hour)}:${_pad2(now.minute)}:${_pad2(now.second)}.'
        '${now.millisecond.toString().padLeft(3, '0')}';
  }

  static String _pad2(int value) => value.toString().padLeft(2, '0');

  static String _paint(String text, LogLevel level) {
    if (!colorEnabled) return text;
    final code = switch (level) {
      LogLevel.debug => '\x1B[90m',
      LogLevel.info => '\x1B[36m',
      LogLevel.warn => '\x1B[33m',
      LogLevel.error => '\x1B[31m',
    };
    return '$code$text\x1B[0m';
  }

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

  static bool _detectColor() {
    final env = Platform.environment;
    if (env['NO_COLOR'] != null) return false;
    if (env['FORCE_COLOR'] != null) return true;
    try {
      return stdout.supportsAnsiEscapes;
    } on Object {
      return false;
    }
  }
}

/// Process-wide logger used by CLI entry points and shared subsystems.
final Logger rootLogger = Logger('proxy-video');
