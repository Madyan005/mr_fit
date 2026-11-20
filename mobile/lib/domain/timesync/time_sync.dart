/// Estimates the offset between a sensor's clock and the phone monotonic clock (Phase 4:
/// the athlete taps the bar/sensor 3 times while the phone records each tap).
library;

final class TapEvent {
  const TapEvent({required this.phoneMonoNs, required this.sensorNs});

  /// When the phone registered the tap (touch / audio / camera), phone monotonic clock.
  final int phoneMonoNs;

  /// When the sensor registered the same tap (acceleration spike), sensor clock.
  final int sensorNs;
}

abstract class TimeSync {
  /// phone = sensor - offset. Zero until calibrated.
  Duration get offset;

  bool get isCalibrated;

  /// Spread of the per-tap offsets (quality indicator). Null until calibrated.
  Duration? get jitter;

  Future<void> calibrate(List<TapEvent> taps);

  int toPhoneMonoNs(int sensorNs) => sensorNs - offset.inMicroseconds * 1000;
}
