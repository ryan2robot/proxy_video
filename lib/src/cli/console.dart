import 'package:args/args.dart';

/// Process exit code for a clean run.
const int exitSuccess = 0;

/// Process exit code for a runtime failure.
const int exitFailure = 1;

/// Process exit code for a malformed command line (`EX_USAGE`).
const int exitUsage = 64;

/// Raised when a well-formed command line carries values that make no sense.
///
/// Distinct from `package:args`'s own `UsageException`, which is about syntax;
/// this one is about semantics, and both exit with [exitUsage].
class CliUsageException implements Exception {
  const CliUsageException(this.message);

  /// What is wrong, phrased for the operator.
  final String message;

  @override
  String toString() => message;
}

/// Reads a string option, treating blank values as absent.
String? cliString(ArgResults args, String name) {
  final value = args[name];
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Reads a boolean flag.
bool cliFlag(ArgResults args, String name) => args[name] == true;

/// Reads an integer option, falling back to [fallback] when absent.
///
/// `package:args` hands back strings for `addOption`, so the conversion and its
/// error reporting live here rather than in every command.
int cliInt(ArgResults args, String name, int fallback) {
  final raw = cliString(args, name);
  if (raw == null) return fallback;

  final parsed = int.tryParse(raw);
  if (parsed == null) {
    throw CliUsageException('--$name must be an integer, got "$raw".');
  }
  return parsed;
}

/// Reads a string option restricted to [allowed].
String? cliEnum(ArgResults args, String name, List<String> allowed) {
  final value = cliString(args, name);
  if (value == null) return null;
  if (!allowed.contains(value)) {
    throw CliUsageException(
      '--$name must be one of ${allowed.join(', ')}, got "$value".',
    );
  }
  return value;
}
