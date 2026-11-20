/// Generic, hardware-neutral sensor models. No packet layouts, UUIDs, MACs or byte values
/// here: those belong only in `data/sensors/real/` REAL SLOT files.
library;

import 'channels.dart';

/// One scalar reading. [tMonoNs] is on the PHONE monotonic clock (sensor clock already
/// mapped through TimeSync by the source).
final class SensorSample {
  const SensorSample({required this.channel, required this.value, required this.tMonoNs, required this.source});

  final String channel;
  final double value;
  final int tMonoNs;
  final String source;

  @override
  String toString() => 'SensorSample($channel=$value @$tMonoNs from $source)';
}

final class SensorCapabilities {
  const SensorCapabilities({required this.sourceName, required this.channels, required this.nominalSampleRateHz});

  final String sourceName;
  final Set<String> channels;
  final double nominalSampleRateHz;

  bool has(String channel) => channels.contains(channel);

  /// Bar velocity directly measured (IMU / sensor fusion). Without it the engine derives
  /// velocity from vision and flags it as lower confidence.
  bool get measuresVelocity => has(Channels.barVelZ);

  static const none = SensorCapabilities(sourceName: 'none', channels: {}, nominalSampleRateHz: 0);
}

final class DeviceStatus {
  const DeviceStatus({
    required this.connected,
    required this.sourceLabel,
    this.batteryPct,
    this.rssi,
    this.calibrated = false,
    this.restingDwell = false,
  });

  final bool connected;
  final double? batteryPct;
  final int? rssi;
  final bool calibrated;

  /// Sensor reports "racked / not moving". Optional: sources that cannot tell leave it
  /// false and the engine falls back to zero-motion detection (D-019).
  final bool restingDwell;
  final String sourceLabel;

  static const disconnected = DeviceStatus(connected: false, sourceLabel: '—');

  DeviceStatus copyWith({bool? connected, double? batteryPct, int? rssi, bool? calibrated, bool? restingDwell}) =>
      DeviceStatus(
        connected: connected ?? this.connected,
        batteryPct: batteryPct ?? this.batteryPct,
        rssi: rssi ?? this.rssi,
        calibrated: calibrated ?? this.calibrated,
        restingDwell: restingDwell ?? this.restingDwell,
        sourceLabel: sourceLabel,
      );
}

/// Haptic semantics (ROLE_BRIEFING): fault = double buzz, fatigue = long buzz,
/// inter-set = light sleep. Byte encodings live only in a REAL SLOT.
enum HapticCommand { faultDoubleBuzz, fatigueLongBuzz, interSetSleep, wake }
