import 'dart:async';

/// Serialises asynchronous critical sections in FIFO order.
///
/// A [CacheEntry] keeps a single write handle on its backing file, and
/// `RandomAccessFile` shares one file position across callers. Interleaving a
/// `setPosition` with another coroutine's `writeFrom` would corrupt the cache,
/// so every offset write goes through a mutex.
class AsyncMutex {
  Future<void> _tail = Future<void>.value();
  int _pending = 0;

  /// Whether nothing is running and nothing is queued.
  bool get isIdle => _pending == 0;

  /// Number of running plus queued sections.
  int get pending => _pending;

  /// Runs [action] after every previously queued section has finished.
  ///
  /// Errors propagate to the caller of this invocation only; the queue itself
  /// always keeps moving.
  Future<T> run<T>(Future<T> Function() action) {
    _pending++;
    final previous = _tail;
    final completer = Completer<void>();
    _tail = completer.future;

    return previous.then((_) => action()).whenComplete(() {
      _pending--;
      completer.complete();
    });
  }
}
