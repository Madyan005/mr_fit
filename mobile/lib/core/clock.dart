/// Phone monotonic clock (nanoseconds). Injectable so tests can use virtual time.
abstract class MonotonicClock {
  int nowNs();
}

class StopwatchClock implements MonotonicClock {
  StopwatchClock() : _sw = Stopwatch()..start();
  final Stopwatch _sw;

  @override
  int nowNs() => _sw.elapsedMicroseconds * 1000;
}

class FakeClock implements MonotonicClock {
  FakeClock([this.t = 0]);
  int t;

  @override
  int nowNs() => t;

  void advance(Duration d) => t += d.inMicroseconds * 1000;
}

const int nsPerSecond = 1000000000;
int secondsToNs(double s) => (s * nsPerSecond).round();
double nsToSeconds(int ns) => ns / nsPerSecond;
