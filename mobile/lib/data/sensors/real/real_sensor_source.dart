// REAL SLOT — the only place where a concrete sensor's transport and wire format may
// appear (e.g. BLE service UUIDs, packet layouts, status bitmasks, haptic byte values).
// Hardware is NOT decided yet (docs/DECISIONS.md O-1/O-4). Candidates from the team's
// earlier plan: an ESP32-S3 bar clip streaming fixed-size IMU packets over BLE, a
// smartwatch, or the phone's own IMU. See docs/INTEGRATION_GUIDE.md for the steps.
//
// To implement:
//  1. Decode the device's frames into generic SensorSample(channel, value, tMonoNs, source)
//     using channel names from domain/sensors/channels.dart ONLY.
//  2. Map the device clock to the phone monotonic clock with TimeSync.toPhoneMonoNs.
//  3. Map device status bits to DeviceStatus booleans (connected, calibrated, restingDwell).
//  4. Map HapticCommand -> device bytes in sendCommand.
//  5. Declare exactly the channels you produce in `capabilities`.
//  6. Bind it in lib/app/bindings.dart (one line) and run test/data/sensor_source_contract_test.dart.

import '../../../domain/sensors/sensor_models.dart';
import '../../../domain/sensors/sensor_source.dart';
import '../../../domain/timesync/time_sync.dart';

class RealSensorSource implements SensorSource {
  RealSensorSource({required this.timeSync});

  final TimeSync timeSync;

  @override
  SensorCapabilities get capabilities => SensorCapabilities.none;

  @override
  Stream<SensorSample> samples() => throw UnimplementedError('REAL SLOT: no sensor hardware chosen yet (O-1)');

  @override
  Stream<DeviceStatus> status() => Stream.value(DeviceStatus.disconnected);

  @override
  Future<void> connect() => throw UnimplementedError('REAL SLOT: no sensor hardware chosen yet (O-1)');

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> sendCommand(HapticCommand c) async {}
}
