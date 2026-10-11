import 'dart:async';

import '../thumbnail_exception.dart';
import '../thumbnail_result.dart';

/// The unit of work a job runs when it gets a native slot.
typedef SchedulerWorker<T> = Future<T> Function();

/// Called when a detached (cancelled or timed-out) worker later succeeds.
/// The engine uses this to still commit the sunk-cost result to the cache.
typedef OrphanResultCallback = void Function(String key, Object? result);

/// One scheduled unit of work.
abstract class ScheduledJob<T> {
  /// Completes with the worker result, or a [ThumbnailException] on
  /// failure, cancellation, or timeout.
  Future<T> get future;

  /// Cancels the job. Queued jobs are dequeued and never run; running jobs
  /// are detached (the future fails now, the worker's late success surfaces
  /// through the scheduler's orphan callback).
  void cancel();

  /// Moves a queued job to the front of [priority]'s band if that band is
  /// higher than the current one. No-op for running or finished jobs.
  void bump(ThumbnailPriority priority);

  /// Whether the worker currently occupies a native slot.
  bool get isRunning;

  /// Whether the future has settled.
  bool get isDone;
}

/// Priority scheduler with bounded concurrency, newest-first dispatch, and
/// detach-style cancellation.
///
/// Dispatch rules:
/// - Higher bands always win ([ThumbnailPriority.visible] first).
/// - Within a band the newest submission dispatches first: during a fling
///   the cells the user is looking at now beat the ones from two flings ago.
/// - At most [maxConcurrent] workers run at once.
///
/// Timeouts count from dispatch, not from enqueue: queue wait is governed by
/// priorities and cancellation, and must not eat into extraction time.
class RequestScheduler {
  /// Creates a scheduler running at most [maxConcurrent] workers.
  RequestScheduler({required this._maxConcurrent, this.onOrphanResult});

  /// Receives late successes of detached workers.
  final OrphanResultCallback? onOrphanResult;

  final List<_Job<Object?>> _visible = [];
  final List<_Job<Object?>> _normal = [];
  final List<_Job<Object?>> _prefetch = [];
  final Map<String, _Job<Object?>> _byKey = {};
  int _active = 0;
  int _maxConcurrent;

  /// Maximum simultaneously running workers. Raising it dispatches queued
  /// work immediately; lowering it takes effect as running workers finish.
  int get maxConcurrent => _maxConcurrent;
  set maxConcurrent(int value) {
    _maxConcurrent = value;
    _pump();
  }

  /// Jobs waiting for a slot.
  int get queueDepth => _visible.length + _normal.length + _prefetch.length;

  /// Workers currently running.
  int get activeCount => _active;

  /// Submits a worker under [key]. The caller must ensure [key] is not
  /// already live (see [existing]); the engine coalesces before submitting.
  ScheduledJob<T> submit<T>(
    String key,
    ThumbnailPriority priority,
    Duration timeout,
    SchedulerWorker<T> worker,
  ) {
    final job = _Job<T>(this, key, priority, timeout, worker);
    _byKey[key] = job as _Job<Object?>;
    _bandOf(priority).add(job as _Job<Object?>);
    scheduleMicrotask(_pump);
    return job;
  }

  /// Returns the live (queued or running, non-detached) job for [key].
  ScheduledJob<T>? existing<T>(String key) => _byKey[key] as ScheduledJob<T>?;

  /// Completes when no work is queued or running. Test helper.
  Future<void> drain() async {
    while (queueDepth > 0 || _active > 0) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  List<_Job<Object?>> _bandOf(ThumbnailPriority priority) => switch (priority) {
    ThumbnailPriority.visible => _visible,
    ThumbnailPriority.normal => _normal,
    ThumbnailPriority.prefetch => _prefetch,
  };

  void _pump() {
    while (_active < _maxConcurrent) {
      final band = _visible.isNotEmpty
          ? _visible
          : _normal.isNotEmpty
          ? _normal
          : _prefetch;
      if (band.isEmpty) return;
      final job = band.removeLast();
      _run(job);
    }
  }

  void _run(_Job<Object?> job) {
    _active++;
    job._state = _JobState.running;
    Timer? timeoutTimer;
    if (job.timeout != Duration.zero) {
      timeoutTimer = Timer(job.timeout, () {
        job._detach(
          ThumbnailException(
            ThumbnailErrorCode.timeout,
            'timed out after ${job.timeout.inMilliseconds}ms',
          ),
        );
      });
    }

    Future<Object?>.sync(() => job.worker()).then(
      (result) {
        timeoutTimer?.cancel();
        _finish(job);
        if (job._detached) {
          onOrphanResult?.call(job.key, result);
        } else {
          job._complete(result);
        }
        _pump();
      },
      onError: (Object error, StackTrace stack) {
        timeoutTimer?.cancel();
        final wrapped = error is ThumbnailException
            ? error
            : ThumbnailException(
                ThumbnailErrorCode.extractionFailed,
                'worker failed: $error',
                cause: error,
              );
        _finish(job);
        if (!job._detached) {
          job._completeError(wrapped, stack);
        }
        // Late failures of detached workers are dropped by design.
        _pump();
      },
    );
  }

  void _finish(_Job<Object?> job) {
    _active--;
    job._state = _JobState.done;
    if (identical(_byKey[job.key], job)) _byKey.remove(job.key);
  }

  void _onCancelQueued(_Job<Object?> job) {
    _bandOf(job.priority).remove(job);
    if (identical(_byKey[job.key], job)) _byKey.remove(job.key);
    scheduleMicrotask(_pump);
  }

  void _onDetachRunning(_Job<Object?> job) {
    // The slot stays occupied until the worker settles, but the job is no
    // longer joinable.
    if (identical(_byKey[job.key], job)) _byKey.remove(job.key);
  }
}

enum _JobState { queued, running, done }

class _Job<T> implements ScheduledJob<T> {
  _Job(this.scheduler, this.key, this.priority, this.timeout, this.worker);

  final RequestScheduler scheduler;
  final String key;
  final Duration timeout;
  final SchedulerWorker<T> worker;
  ThumbnailPriority priority;

  final Completer<T> _completer = Completer<T>();
  _JobState _state = _JobState.queued;
  bool _detached = false;

  @override
  Future<T> get future => _completer.future;

  @override
  bool get isRunning => _state == _JobState.running && !_detached;

  @override
  bool get isDone => _completer.isCompleted;

  @override
  void cancel() {
    const cancelledError = ThumbnailException(
      ThumbnailErrorCode.cancelled,
      'request cancelled',
    );
    switch (_state) {
      case _JobState.queued:
        _state = _JobState.done;
        scheduler._onCancelQueued(this as _Job<Object?>);
        _completer.completeError(cancelledError);
      case _JobState.running:
        _detach(cancelledError);
      case _JobState.done:
        break; // Already settled.
    }
  }

  @override
  void bump(ThumbnailPriority newPriority) {
    if (_state != _JobState.queued) return;
    if (newPriority.index <= priority.index) return;
    final oldBand = scheduler._bandOf(priority);
    oldBand.remove(this as _Job<Object?>);
    priority = newPriority;
    scheduler._bandOf(newPriority).add(this as _Job<Object?>);
    scheduleMicrotask(scheduler._pump);
  }

  /// Fails the future now and lets the worker finish into the orphan path.
  void _detach(ThumbnailException error) {
    if (_detached || _state != _JobState.running) return;
    _detached = true;
    scheduler._onDetachRunning(this as _Job<Object?>);
    _completer.completeError(error);
  }

  void _complete(Object? result) {
    if (!_completer.isCompleted) _completer.complete(result as T);
  }

  void _completeError(ThumbnailException error, StackTrace stack) {
    if (!_completer.isCompleted) _completer.completeError(error, stack);
  }
}
