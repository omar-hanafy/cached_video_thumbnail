import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cached_video_thumbnail/src/scheduler/request_scheduler.dart';
import 'package:cached_video_thumbnail/cached_video_thumbnail.dart';

const _long = Duration(minutes: 10);

/// A worker whose start and completion the test controls.
class ControlledWorker {
  final startedAt = Completer<void>();
  final _gate = Completer<String>();
  bool get started => startedAt.isCompleted;

  bool get finished => _gate.isCompleted;

  Future<String> call() {
    startedAt.complete();
    return _gate.future;
  }

  void finish(String value) => _gate.complete(value);
  void fail(Object error) => _gate.completeError(error);
}

void main() {
  test('never runs more workers than maxConcurrent', () async {
    final scheduler = RequestScheduler(maxConcurrent: 2);
    final workers = List.generate(4, (_) => ControlledWorker());
    final jobs = [
      for (var i = 0; i < 4; i++)
        scheduler.submit(
          'k$i',
          ThumbnailPriority.normal,
          _long,
          workers[i].call,
        ),
    ];
    await pumpEventQueue();

    expect(workers.where((w) => w.started).length, 2);
    expect(scheduler.activeCount, 2);
    expect(scheduler.queueDepth, 2);

    // Finishing one admits exactly one more.
    workers.firstWhere((w) => w.started).finish('done');
    await pumpEventQueue();
    expect(workers.where((w) => w.started).length, 3);

    // Keep finishing whatever starts until all jobs settle.
    for (var i = 0; i < 10 && jobs.any((j) => !j.isDone); i++) {
      for (final w in workers.where((w) => w.started && !w.finished)) {
        w.finish('done');
      }
      await pumpEventQueue();
    }
    await scheduler.drain();
    for (final j in jobs) {
      expect(j.isDone, isTrue);
    }
  });

  test('newest submission wins within a band (LIFO)', () async {
    final scheduler = RequestScheduler(maxConcurrent: 1);
    final blocker = ControlledWorker();
    scheduler.submit('blocker', ThumbnailPriority.normal, _long, blocker.call);
    await pumpEventQueue();

    final order = <String>[];
    Future<String> tracked(String name) async {
      order.add(name);
      return name;
    }

    scheduler.submit('a', ThumbnailPriority.normal, _long, () => tracked('a'));
    scheduler.submit('b', ThumbnailPriority.normal, _long, () => tracked('b'));
    blocker.finish('x');
    await scheduler.drain();
    expect(order, ['b', 'a']);
  });

  test('higher bands always dispatch before lower bands', () async {
    final scheduler = RequestScheduler(maxConcurrent: 1);
    final blocker = ControlledWorker();
    scheduler.submit('blocker', ThumbnailPriority.visible, _long, blocker.call);
    await pumpEventQueue();

    final order = <String>[];
    Future<String> tracked(String name) async {
      order.add(name);
      return name;
    }

    scheduler.submit(
      'p',
      ThumbnailPriority.prefetch,
      _long,
      () => tracked('p'),
    );
    scheduler.submit('n', ThumbnailPriority.normal, _long, () => tracked('n'));
    scheduler.submit('v', ThumbnailPriority.visible, _long, () => tracked('v'));
    blocker.finish('x');
    await scheduler.drain();
    expect(order, ['v', 'n', 'p']);
  });

  test('cancelling a queued job frees it without running the worker', () async {
    final scheduler = RequestScheduler(maxConcurrent: 1);
    final blocker = ControlledWorker();
    scheduler.submit('blocker', ThumbnailPriority.normal, _long, blocker.call);
    await pumpEventQueue();

    var ran = false;
    final job = scheduler.submit(
      'k',
      ThumbnailPriority.normal,
      _long,
      () async {
        ran = true;
        return 'x';
      },
    );
    expect(scheduler.queueDepth, 1);
    job.cancel();
    expect(scheduler.queueDepth, 0);

    await expectLater(
      job.future,
      throwsA(
        isA<ThumbnailException>().having(
          (e) => e.code,
          'code',
          ThumbnailErrorCode.cancelled,
        ),
      ),
    );
    blocker.finish('x');
    await scheduler.drain();
    expect(ran, isFalse);
    expect(scheduler.existing('k'), isNull);
  });

  test('cancelling a running job detaches it; a successful orphan result is reported', () async {
    final orphans = <(String, Object?)>[];
    final scheduler = RequestScheduler(
      maxConcurrent: 1,
      onOrphanResult: (key, result) => orphans.add((key, result)),
    );
    final worker = ControlledWorker();
    final job = scheduler.submit(
      'k',
      ThumbnailPriority.normal,
      _long,
      worker.call,
    );
    await pumpEventQueue();
    expect(job.isRunning, isTrue);

    job.cancel();
    await expectLater(
      job.future,
      throwsA(
        isA<ThumbnailException>().having(
          (e) => e.code,
          'code',
          ThumbnailErrorCode.cancelled,
        ),
      ),
    );
    expect(scheduler.existing('k'), isNull);

    worker.finish('late-result');
    await scheduler.drain();
    expect(orphans, [('k', 'late-result')]);
  });

  test('a failed detached worker does not report an orphan result', () async {
    final orphans = <(String, Object?)>[];
    final scheduler = RequestScheduler(
      maxConcurrent: 1,
      onOrphanResult: (key, result) => orphans.add((key, result)),
    );
    final worker = ControlledWorker();
    final job = scheduler.submit(
      'k',
      ThumbnailPriority.normal,
      _long,
      worker.call,
    );
    await pumpEventQueue();
    job.cancel();
    await expectLater(job.future, throwsA(isA<ThumbnailException>()));

    worker.fail(const ThumbnailException(ThumbnailErrorCode.network, 'boom'));
    await scheduler.drain();
    expect(orphans, isEmpty);
  });

  for (final detachByTimeout in [false, true]) {
    test(
      '${detachByTimeout ? 'timing out' : 'cancelling'} a running worker keeps its slot until settlement',
      () {
        fakeAsync((async) {
          final scheduler = RequestScheduler(maxConcurrent: 1);
          final first = ControlledWorker();
          final firstJob = scheduler.submit(
            'first',
            ThumbnailPriority.normal,
            const Duration(seconds: 1),
            first.call,
          );
          ThumbnailException? terminalError;
          firstJob.future.then<void>(
            (_) {},
            onError: (Object error, StackTrace stack) {
              terminalError = error as ThumbnailException;
            },
          );
          async.elapse(Duration.zero);
          expect(first.started, isTrue);

          final next = ControlledWorker();
          final nextJob = scheduler.submit(
            'next',
            ThumbnailPriority.normal,
            _long,
            next.call,
          );
          if (detachByTimeout) {
            async.elapse(const Duration(seconds: 1));
          } else {
            firstJob.cancel();
            async.elapse(Duration.zero);
          }

          expect(
            terminalError?.code,
            detachByTimeout
                ? ThumbnailErrorCode.timeout
                : ThumbnailErrorCode.cancelled,
          );
          expect(scheduler.activeCount, 1);
          expect(scheduler.queueDepth, 1);
          expect(next.started, isFalse, reason: 'the first worker still runs');

          first.finish('late');
          async.elapse(Duration.zero);
          expect(next.started, isTrue);
          expect(scheduler.activeCount, 1);
          expect(scheduler.queueDepth, 0);
          next.finish('done');
          async.elapse(Duration.zero);
          expect(nextJob.isDone, isTrue);
          expect(scheduler.activeCount, 0);
        });
      },
    );
  }

  test('bump raises a queued job to the front of the higher band', () async {
    final scheduler = RequestScheduler(maxConcurrent: 1);
    final blocker = ControlledWorker();
    scheduler.submit('blocker', ThumbnailPriority.normal, _long, blocker.call);
    await pumpEventQueue();

    final order = <String>[];
    Future<String> tracked(String name) async {
      order.add(name);
      return name;
    }

    final a = scheduler.submit(
      'a',
      ThumbnailPriority.prefetch,
      _long,
      () => tracked('a'),
    );
    scheduler.submit('b', ThumbnailPriority.normal, _long, () => tracked('b'));
    a.bump(ThumbnailPriority.visible);
    blocker.finish('x');
    await scheduler.drain();
    expect(order, ['a', 'b']);
  });

  test('timeout fails the future; a late success is reported as orphan', () {
    fakeAsync((async) {
      final orphans = <(String, Object?)>[];
      final scheduler = RequestScheduler(
        maxConcurrent: 1,
        onOrphanResult: (key, result) => orphans.add((key, result)),
      );
      final job = scheduler.submit(
        'k',
        ThumbnailPriority.normal,
        const Duration(seconds: 1),
        () => Future.delayed(const Duration(seconds: 5), () => 'late'),
      );
      ThumbnailException? error;
      job.future.catchError((Object e) {
        error = e as ThumbnailException;
        return '';
      });
      async.elapse(const Duration(milliseconds: 1100));
      expect(error, isNotNull);
      expect(error!.code, ThumbnailErrorCode.timeout);
      expect(scheduler.existing('k'), isNull);

      async.elapse(const Duration(seconds: 5));
      expect(orphans, [('k', 'late')]);
    });
  });

  test('timeout counts from dispatch, not from enqueue', () {
    fakeAsync((async) {
      final scheduler = RequestScheduler(maxConcurrent: 1);
      // Occupy the slot for 3s.
      scheduler.submit(
        'blocker',
        ThumbnailPriority.normal,
        _long,
        () => Future.delayed(const Duration(seconds: 3), () => 'x'),
      );
      // 1s timeout, but it will wait ~3s in the queue first.
      final job = scheduler.submit(
        'k',
        ThumbnailPriority.normal,
        const Duration(seconds: 1),
        () => Future.delayed(const Duration(milliseconds: 500), () => 'ok'),
      );
      String? result;
      job.future.then((v) => result = v);
      async.elapse(const Duration(seconds: 4));
      expect(result, 'ok', reason: 'queue wait must not consume the timeout');
    });
  });

  test('existing returns the live job and null once finished', () async {
    final scheduler = RequestScheduler(maxConcurrent: 1);
    final worker = ControlledWorker();
    final job = scheduler.submit(
      'k',
      ThumbnailPriority.normal,
      _long,
      worker.call,
    );
    expect(scheduler.existing('k'), same(job));
    await pumpEventQueue();
    expect(scheduler.existing('k'), same(job));
    worker.finish('x');
    await scheduler.drain();
    expect(scheduler.existing('k'), isNull);
  });

  test('ThumbnailException from workers propagates untouched; other errors are wrapped', () async {
    final scheduler = RequestScheduler(maxConcurrent: 2);
    const original = ThumbnailException(ThumbnailErrorCode.network, '404');
    final a = scheduler.submit(
      'a',
      ThumbnailPriority.normal,
      _long,
      () async => throw original,
    );
    await expectLater(a.future, throwsA(same(original)));

    final b = scheduler.submit(
      'b',
      ThumbnailPriority.normal,
      _long,
      () async => throw StateError('x'),
    );
    await expectLater(
      b.future,
      throwsA(
        isA<ThumbnailException>()
            .having((e) => e.code, 'code', ThumbnailErrorCode.extractionFailed)
            .having((e) => e.cause, 'cause', isA<StateError>()),
      ),
    );
  });

  test('raising maxConcurrent dispatches queued work immediately', () async {
    final scheduler = RequestScheduler(maxConcurrent: 1);
    final w1 = ControlledWorker();
    final w2 = ControlledWorker();
    scheduler.submit('a', ThumbnailPriority.normal, _long, w1.call);
    scheduler.submit('b', ThumbnailPriority.normal, _long, w2.call);
    await pumpEventQueue();
    // Newest-first: 'b' took the only slot, 'a' is queued.
    expect(w2.started, isTrue);
    expect(w1.started, isFalse);

    scheduler.maxConcurrent = 2;
    await pumpEventQueue();
    expect(w1.started, isTrue);
    w1.finish('x');
    w2.finish('y');
    await scheduler.drain();
  });
}
