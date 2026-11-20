import '../../domain/timesync/time_sync.dart';

/// Real (hardware-agnostic) Phase-4 algorithm: offset = median(sensorNs - phoneMonoNs) over
/// the taps; jitter = max - min of those differences. Median rejects one bad tap of three.
class TapTimeSync extends TimeSync {
  TapTimeSync({this.minTaps = 3, this.maxJitter = const Duration(milliseconds: 60)});

  final int minTaps;
  final Duration maxJitter;
  Duration _offset = Duration.zero;
  Duration? _jitter;

  @override
  Duration get offset => _offset;

  @override
  bool get isCalibrated => _jitter != null;

  @override
  Duration? get jitter => _jitter;

  @override
  Future<void> calibrate(List<TapEvent> taps) async {
    if (taps.length < minTaps) {
      throw StateError('need at least $minTaps taps, got ${taps.length}');
    }
    final diffs = [for (final t in taps) t.sensorNs - t.phoneMonoNs]..sort();
    final mid = diffs.length ~/ 2;
    final median = diffs.length.isOdd ? diffs[mid] : (diffs[mid - 1] + diffs[mid]) ~/ 2;
    final jitter = Duration(microseconds: (diffs.last - diffs.first) ~/ 1000);
    if (jitter > maxJitter) {
      throw StateError('taps disagree by ${jitter.inMilliseconds} ms (> ${maxJitter.inMilliseconds} ms); repeat calibration');
    }
    _offset = Duration(microseconds: median ~/ 1000);
    _jitter = jitter;
  }
}
