import '../../domain/timesync/time_sync.dart';

/// SIMULATED. Deterministic time sync: `calibrate` always lands on [trueOffset] (the mock
/// sensor's known clock lead), so tests and the demo never depend on tap timing.
class MockTimeSync extends TimeSync {
  MockTimeSync({this.trueOffset = const Duration(milliseconds: 37)});

  /// Already-calibrated instance (golden tests).
  factory MockTimeSync.calibrated({Duration offset = const Duration(milliseconds: 37)}) =>
      MockTimeSync(trueOffset: offset).._calibrated = true;

  final Duration trueOffset;
  bool _calibrated = false;

  @override
  Duration get offset => _calibrated ? trueOffset : Duration.zero;

  @override
  bool get isCalibrated => _calibrated;

  @override
  Duration? get jitter => _calibrated ? Duration.zero : null;

  @override
  Future<void> calibrate(List<TapEvent> taps) async => _calibrated = true;
}
