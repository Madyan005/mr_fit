/// What the 7-phase session needs from the outside world, as interfaces, so the
/// session logic never names a plugin or a piece of hardware.
library;

import '../sensors/sensor_models.dart';

/// Haptic + voice cues on the phone (vibration motor, text-to-speech).
abstract interface class CueOutput {
  Future<void> haptic(HapticCommand c);
  Future<void> speak(String text);
  Future<void> stopSpeaking();
}

/// Keeps streaming and persistence alive while the screen is off or the app is in the
/// background between sets (Android foreground service).
abstract interface class KeepAlive {
  /// [simulated]: no real device is streaming (service type dataSync, not connectedDevice).
  Future<void> start({required bool simulated});
  Future<void> stop();
}

/// Lets the session drive the SIMULATED world (mock mode only): the athlete "steps back"
/// when positioning starts and "lifts" when the set starts. Null in real mode.
abstract interface class SimulationHooks {
  void startPositioning([int? nowNs]);
  void startSet([int? nowNs]);
  void reset();
}

/// A source that can "feel" a tap the phone registered (mock sensor in Phase 4).
/// Real sensors detect the physical tap themselves.
abstract interface class TapSimulator {
  void simulateTap(int phoneMonoNs);
}
