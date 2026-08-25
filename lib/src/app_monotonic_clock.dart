class AppMonotonicClock {
  AppMonotonicClock._();

  static final DateTime _wallAnchor = DateTime.now();
  static final Stopwatch _stopwatch = Stopwatch()..start();

  static int nowUs() => _stopwatch.elapsedMicroseconds;

  static DateTime wallTime(int monotonicUs) => _wallAnchor.add(
        Duration(microseconds: monotonicUs),
      );

  static int monotonicUs(DateTime wallTime) =>
      wallTime.difference(_wallAnchor).inMicroseconds;
}
