/// THE single binding file. Swapping Mock <-> Real for sensors, vision or time sync is a
/// change HERE ONLY — no UI code changes (spec 3.2).
///
/// The debug switch (Settings > Data source) picks [SourceMode] at runtime; `main.dart`
/// rebuilds the ProviderScope with [sourceOverrides] for the chosen mode.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3.x moved `Override` (and other rarely used types) to misc.dart.
import 'package:flutter_riverpod/misc.dart' show Override;

import '../core/clock.dart';
import '../data/sensors/mock/mock_sensor_source.dart';
import '../data/sensors/mock/mock_world.dart';
import '../data/sensors/mock/scenarios.dart';
import '../data/sensors/real/real_sensor_source.dart';
import '../data/timesync/tap_time_sync.dart';
import '../data/vision/mock/mock_vision_pipeline.dart';
import '../data/vision/real/real_vision_pipeline.dart';
import '../domain/sensors/sensor_source.dart';
import '../domain/session/session_ports.dart';
import '../domain/timesync/time_sync.dart';
import '../domain/vision/vision_pipeline.dart';
import '../domain/workout/workout_models.dart';

enum SourceMode { mock, real }

/// Which demo scenario the mocks play (debug scenario selector).
final scenarioProvider = NotifierProvider<ScenarioNotifier, ScenarioId>(ScenarioNotifier.new);

class ScenarioNotifier extends Notifier<ScenarioId> {
  @override
  ScenarioId build() => ScenarioId.clean;
  void select(ScenarioId id) => state = id;
}

/// Overridden below; reading one without an override is a programming error.
final sourceModeProvider = Provider<SourceMode>((ref) => throw UnimplementedError('bind sourceModeProvider'));
final timeSyncProvider = Provider<TimeSync>((ref) => throw UnimplementedError('bind timeSyncProvider'));
final sensorSourceProvider = Provider<SensorSource>((ref) => throw UnimplementedError('bind sensorSourceProvider'));
final visionPipelineProvider = Provider<VisionPipeline>((ref) => throw UnimplementedError('bind visionPipelineProvider'));

/// Phone monotonic clock shared by the session and the mocks (tests bind a fake clock).
final monotonicClockProvider = Provider<MonotonicClock>((ref) => StopwatchClock());

/// Shared simulated world (mock mode only): keeps the sensor and vision mocks in lock-step.
final mockWorldProvider = Provider<MockWorld>(
    (ref) => MockWorld(scenario: Scenarios.byId(ref.watch(scenarioProvider)), clock: ref.watch(monotonicClockProvider)));

/// Mock mode: the session tells the simulated athlete when to step back and when to lift.
/// Real mode: null (a real athlete needs no script).
final simulationHooksProvider = Provider<SimulationHooks?>((ref) => throw UnimplementedError('bind simulationHooksProvider'));

/// Data source recorded on every set (`data_source`). Any mock bound => simulated.
final dataSourceProvider = Provider<DataSource>(
    (ref) => ref.watch(sourceModeProvider) == SourceMode.mock ? DataSource.simulated : DataSource.real);

/// True while any mock is bound -> the UI shows the "SIMULATED" banner.
final anyMockActiveProvider = Provider<bool>((ref) => ref.watch(dataSourceProvider) == DataSource.simulated);

List<Override> sourceOverrides(SourceMode mode) => switch (mode) {
      SourceMode.mock => [
          sourceModeProvider.overrideWithValue(SourceMode.mock),
          // The real tap algorithm, fed by simulated taps: it measures the mock sensor's
          // 37 ms clock lead (D-048, D-075). MockTimeSync stays for engine unit tests.
          timeSyncProvider.overrideWith((ref) => TapTimeSync()),
          sensorSourceProvider.overrideWith((ref) {
            final src = MockSensorSource(world: ref.watch(mockWorldProvider), timeSync: ref.watch(timeSyncProvider));
            ref.onDispose(src.dispose);
            return src;
          }),
          visionPipelineProvider.overrideWith((ref) => MockVisionPipeline(world: ref.watch(mockWorldProvider))),
          simulationHooksProvider.overrideWith((ref) => ref.watch(mockWorldProvider)),
        ],
      // REAL: while only some hardware exists, swap single lines back to the Mock* binding.
      SourceMode.real => [
          sourceModeProvider.overrideWithValue(SourceMode.real),
          timeSyncProvider.overrideWith((ref) => TapTimeSync()),
          sensorSourceProvider.overrideWith((ref) => RealSensorSource(timeSync: ref.watch(timeSyncProvider))),
          visionPipelineProvider.overrideWith((ref) => RealVisionPipeline()),
          simulationHooksProvider.overrideWithValue(null),
        ],
    };
