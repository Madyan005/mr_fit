/// THE channel registry (mirror of contracts/channels.v1.json; a test keeps them equal).
/// Sources declare which of these they offer via [SensorCapabilities]; the engine and UI
/// must cope with any of them being absent.
library;

abstract final class Channels {
  static const accelX = 'accel_x';
  static const accelY = 'accel_y';
  static const accelZ = 'accel_z';
  static const gyroX = 'gyro_x';
  static const gyroY = 'gyro_y';
  static const gyroZ = 'gyro_z';
  static const barVelZ = 'bar_vel_z';
  static const barAccelZ = 'bar_accel_z';
  static const barTiltRoll = 'bar_tilt_roll';
  static const visionVelZ = 'vision_vel_z';
  static const heartRateBpm = 'heart_rate_bpm';
  static const batteryPct = 'battery_pct';

  static const all = <String>{
    accelX, accelY, accelZ, gyroX, gyroY, gyroZ, barVelZ, barAccelZ, barTiltRoll,
    visionVelZ, heartRateBpm, batteryPct,
  };
}
