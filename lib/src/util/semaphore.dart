import 'dart:async';
import 'dart:collection';

/// Counting semaphore with FIFO fairness.
///
/// Used to cap how many upstream range requests are in flight at once, so that
/// a browser seeking through a timeline cannot open unbounded sockets.
class Semaphore {
  /// Creates a semaphore holding [capacity] permits.
  Semaphore(this.capacity)
    : assert(capacity >= 1, 'capacity must be >= 1'),
      _held = 0;

  /// Maximum number of concurrently held permits.
  final int capacity;

  final Queue<_Waiter> _waiters = Queue<_Waiter>();

  int _held;

  /// Number of permits currently held.
  int get inUse => _held;

  /// Number of permits that can be acquired without waiting.
  int get available => capacity - _held;

  /// Number of callers queued for a permit.
  int get waiting => _waiters.length;

  /// Whether no permit is currently held.
  bool get isIdle => _held == 0;

  /// Acquires a permit without waiting. Returns `false` when none is free.
  bool tryAcquire() {
    if (_waiters.isEmpty && _held < capacity) {
      _held++;
      return true;
    }
    return false;
  }

  /// Acquires a permit, waiting for one when the semaphore is saturated.
  ///
  /// Waiters are served in FIFO order. When [timeout] elapses first, the
  /// returned future completes with a [TimeoutException]; callers must handle
  /// that error (or use [withPermit], which does).
  Future<void> acquire({Duration? timeout}) {
    if (tryAcquire()) return Future<void>.value();

    final waiter = _Waiter();
    _waiters.add(waiter);

    if (timeout != null) {
      waiter.timer = Timer(timeout, () {
        if (_waiters.remove(waiter)) {
          waiter.completer.completeError(
            TimeoutException(
              'Waited ${timeout.inMilliseconds}ms for a semaphore permit '
              '(capacity: $capacity)',
              timeout,
            ),
          );
        }
      });
    }

    return waiter.completer.future;
  }

  /// Returns a permit, handing it directly to the next waiter when present.
  ///
  /// Throws a [StateError] when called more often than [acquire] succeeded,
  /// which would otherwise silently inflate the permit count.
  void release() {
    if (_held == 0) {
      throw StateError(
        'Semaphore.release() called more times than acquire() on a '
        'semaphore with capacity $capacity',
      );
    }

    while (_waiters.isNotEmpty) {
      final waiter = _waiters.removeFirst();
      waiter.timer?.cancel();
      if (!waiter.completer.isCompleted) {
        // The permit is transferred rather than returned, so `_held` stays put.
        waiter.completer.complete();
        return;
      }
    }

    _held--;
  }

  /// Runs [action] while holding a permit, releasing it in all cases.
  Future<T> withPermit<T>(
    Future<T> Function() action, {
    Duration? timeout,
  }) async {
    await acquire(timeout: timeout);
    try {
      return await action();
    } finally {
      release();
    }
  }
}

class _Waiter {
  final Completer<void> completer = Completer<void>();
  Timer? timer;
}
