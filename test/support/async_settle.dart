import 'package:flutter_test/flutter_test.dart';

/// Lets real file/SQLite/loopback work started by a tap finish before
/// `pumpAndSettle`: alternates real-time waits with frames until [done] holds
/// (by default, until no frame is scheduled, i.e. progress indicators are
/// gone). Slow disks (e.g. hosted Windows runners) need more than a fixed delay.
Future<void> pumpUntil(
  WidgetTester tester, [
  bool Function()? done,
  Duration timeout = const Duration(seconds: 20),
]) async {
  final finished = done ?? () => !tester.binding.hasScheduledFrame;
  final deadline = DateTime.now().add(timeout);
  do {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    // Advancing fake time too lets ripples and transitions finish, so only
    // ongoing work (e.g. a progress indicator) keeps frames scheduled.
    await tester.pump(const Duration(milliseconds: 25));
  } while (!finished() && DateTime.now().isBefore(deadline));
}
