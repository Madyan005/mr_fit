import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:mr_fit/app/bindings.dart';
import 'package:mr_fit/app/providers.dart';
import 'package:mr_fit/data/sensors/mock/mock_sensor_source.dart';
import 'package:mr_fit/data/sensors/real/real_sensor_source.dart';
import 'package:mr_fit/data/timesync/tap_time_sync.dart';
import 'package:mr_fit/data/vision/mock/mock_vision_pipeline.dart';
import 'package:mr_fit/data/vision/real/real_vision_pipeline.dart';
import 'package:mr_fit/domain/sensors/sensor_source.dart';
import 'package:mr_fit/domain/vision/vision_pipeline.dart';
import 'package:mr_fit/domain/workout/workout_models.dart';

void main() {
  ProviderContainer container(List<Override> overrides) {
    final c = ProviderContainer(retry: noAutoRetry, overrides: overrides);
    addTearDown(c.dispose);
    return c;
  }

  test('mock mode: everything simulated', () {
    final c = container(sourceOverrides(SourceMode.mock));
    expect(c.read(dataSourceProvider), DataSource.simulated);
    expect(c.read(anyMockActiveProvider), isTrue);
  });

  test('real mode with only real bindings: real', () {
    final c = container(sourceOverrides(SourceMode.real));
    expect(c.read(dataSourceProvider), DataSource.real);
    expect(c.read(anyMockActiveProvider), isFalse);
  });

  // The Real list from sourceOverrides with one line swapped back to a Mock* binding,
  // as the comment in bindings.dart suggests while only some hardware exists.
  List<Override> realWith({SensorSource Function(Ref ref)? sensor, VisionPipeline Function(Ref ref)? vision}) => [
        sourceModeProvider.overrideWithValue(SourceMode.real),
        timeSyncProvider.overrideWith((ref) => TapTimeSync()),
        sensorSourceProvider.overrideWith(sensor ?? (ref) => RealSensorSource(timeSync: ref.watch(timeSyncProvider))),
        visionPipelineProvider.overrideWith(vision ?? (ref) => RealVisionPipeline()),
        simulationHooksProvider.overrideWithValue(null),
      ];

  test('real mode with one line swapped back to a mock is still labelled simulated', () {
    final vision = container(realWith(vision: (ref) => MockVisionPipeline(world: ref.watch(mockWorldProvider))));
    expect(vision.read(dataSourceProvider), DataSource.simulated);
    expect(vision.read(anyMockActiveProvider), isTrue, reason: 'the SIMULATED banner stays');
    expect(vision.read(sensorSimulatedProvider), isFalse, reason: 'real device: foreground type connectedDevice');

    final sensor = container(realWith(sensor: (ref) => MockSensorSource(world: ref.watch(mockWorldProvider))));
    expect(sensor.read(dataSourceProvider), DataSource.simulated);
    expect(sensor.read(sensorSimulatedProvider), isTrue);

    expect(container(realWith()).read(dataSourceProvider), DataSource.real, reason: 'same list, nothing swapped');
  });
}
