import 'sensor_models.dart';

/// Any motion data source: mock, external IMU clip, smartwatch, phone sensors, or several.
/// Implementations: `data/sensors/mock/` (MockSensorSource) and `data/sensors/real/` (REAL SLOT).
abstract class SensorSource {
  SensorCapabilities get capabilities;

  /// Broadcast stream of samples (phone monotonic time).
  Stream<SensorSample> samples();

  Stream<DeviceStatus> status();

  Future<void> connect();
  Future<void> disconnect();

  Future<void> sendCommand(HapticCommand c);
}
