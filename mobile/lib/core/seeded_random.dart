import 'dart:math' as math;

/// Deterministic RNG for mocks: same seed -> same sequence (on the same Dart SDK).
class SeededRandom {
  SeededRandom(int seed) : _r = math.Random(seed);

  final math.Random _r;
  double? _spare;

  double nextDouble() => _r.nextDouble();

  /// Standard normal via Box–Muller (cached pair).
  double gaussian() {
    final s = _spare;
    if (s != null) {
      _spare = null;
      return s;
    }
    double u1;
    do {
      u1 = _r.nextDouble();
    } while (u1 <= 1e-12);
    final u2 = _r.nextDouble();
    final mag = math.sqrt(-2.0 * math.log(u1));
    _spare = mag * math.sin(2 * math.pi * u2);
    return mag * math.cos(2 * math.pi * u2);
  }
}
