/// SIMULATED shared state for the mocks: one scenario, one set start, one positioning
/// start — so MockSensorSource and MockVisionPipeline stay in lock-step.
library;

import '../../../core/clock.dart';
import 'scenario_timeline.dart';
import 'scenarios.dart';

class MockWorld {
  MockWorld({required this.scenario, MonotonicClock? clock})
      : clock = clock ?? StopwatchClock(),
        timeline = ScenarioTimeline(scenario);

  final Scenario scenario;
  final ScenarioTimeline timeline;
  final MonotonicClock clock;

  int? setStartNs; // phone clock
  int? positioningStartNs;

  void startSet([int? nowNs]) => setStartNs = nowNs ?? clock.nowNs();
  void startPositioning([int? nowNs]) => positioningStartNs = nowNs ?? clock.nowNs();
  void reset() {
    setStartNs = null;
    positioningStartNs = null;
  }

  /// Seconds since set start, or null when no set is running (idle standing).
  double? setTime(int phoneNs) {
    final s = setStartNs;
    return s == null ? null : nsToSeconds(phoneNs - s);
  }

  MotionState motionAt(int phoneNs) {
    final t = setTime(phoneNs);
    return timeline.at(t ?? -1); // t < preRoll -> standing still
  }

  bool isRacked(int phoneNs) {
    final t = setTime(phoneNs);
    return t != null && t >= timeline.rackedFromS;
  }

  /// Phase 3 script: the athlete starts too close (poor framing) and steps back.
  /// 0.45 for 2.5 s, ramps to 0.95 by 4.0 s. Before positioning starts: 0.95 (already framed).
  double framingScore(int phoneNs) {
    final p = positioningStartNs;
    if (p == null) return 0.95;
    final t = nsToSeconds(phoneNs - p);
    if (t < 2.5) return 0.45;
    if (t > 4.0) return 0.95;
    return 0.45 + (t - 2.5) / 1.5 * 0.5;
  }
}
