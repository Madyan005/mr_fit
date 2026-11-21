// What every SensorSource must do, so the session, the engine and the UI work with it
// unchanged (docs/INTEGRATION_GUIDE.md). Runs against MockSensorSource today. When a
// real source exists, add it to `subjects`; one that needs a device should only be added
// when an opt-in environment variable is set, like test/e2e/live_backend_test.dart.
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mr_fit/core/clock.dart';
import 'package:mr_fit/data/sensors/mock/mock_sensor_source.dart';
import 'package:mr_fit/data/sensors/mock/mock_world.dart';
import 'package:mr_fit/data/sensors/mock/scenarios.dart';
import 'package:mr_fit/data/timesync/tap_time_sync.dart';
import 'package:mr_fit/domain/sensors/channels.dart';
import 'package:mr_fit/domain/sensors/sensor_models.dart';
import 'package:mr_fit/domain/sensors/sensor_source.dart';
import 'package:mr_fit/domain/timesync/time_sync.dart';

import '../support/session_fakes.dart';

typedef SensorSubject = ({String name, SensorSource Function(MonotonicClock clock, TimeSync sync) create});

final subjects = <SensorSubject>[
  (
    name: 'MockSensorSource',
    create: (clock, sync) => MockSensorSource(world: MockWorld(scenario: Scenarios.clean, clock: clock), timeSync: sync),
  ),
  (
    name: 'MockSensorSource without bar velocity (a weaker source)',
    create: (clock, sync) => MockSensorSource(
        world: MockWorld(scenario: Scenarios.clean, clock: clock),
        timeSync: sync,
        channels: {Channels.accelX, Channels.accelY, Channels.accelZ, Channels.batteryPct}),
  ),
];

void main() {
  for (final subject in subjects) {
    group(subject.name, () {
      test('declares a name, a rate and only registry channels', () {
        fakeAsync((fa) {
          final caps = subject.create(FakeAsyncClock(fa), TapTimeSync()).capabilities;
          expect(caps.sourceName, isNotEmpty);
          expect(caps.nominalSampleRateHz, greaterThan(0));
          expect(caps.channels, isNotEmpty);
          expect(Channels.all.containsAll(caps.channels), isTrue,
              reason: 'channel names come from contracts/channels.v1.json only: ${caps.channels.difference(Channels.all)}');
        });
      });

      test('connect, stream on the phone clock, disconnect', () {
        fakeAsync((fa) {
          final clock = FakeAsyncClock(fa);
          fa.elapse(const Duration(seconds: 5)); // the phone clock is not at zero
          final src = subject.create(clock, TapTimeSync());
          final caps = src.capabilities;
          final samples = <SensorSample>[];
          final statuses = <DeviceStatus>[];
          src.samples().listen(samples.add);
          src.status().listen(statuses.add);

          fa.elapse(const Duration(milliseconds: 500));
          expect(samples, isEmpty, reason: 'nothing before connect()');

          final connectedAt = clock.nowNs();
          src.connect();
          fa.elapse(const Duration(seconds: 1));
          expect(statuses.where((s) => s.connected), isNotEmpty, reason: 'reports connected within 1 s');
          expect(statuses.lastWhere((s) => s.connected).sourceLabel, isNotEmpty);

          samples.clear();
          final from = clock.nowNs();
          fa.elapse(const Duration(seconds: 2));
          final to = clock.nowNs();
          expect(samples, isNotEmpty);

          // Only declared channels; every declared channel actually arrives.
          final seen = samples.map((s) => s.channel).toSet();
          expect(caps.channels.containsAll(seen), isTrue, reason: 'undeclared: ${seen.difference(caps.channels)}');
          expect(seen, caps.channels, reason: 'declared but never sent: ${caps.channels.difference(seen)}');
          expect(samples.every((s) => s.source.isNotEmpty && s.value.isFinite), isTrue);

          // Phone monotonic time: already mapped through TimeSync, not the device's own
          // epoch. Before calibration an offset of a few hundred ms is acceptable.
          const slackNs = 250 * 1000000;
          expect(samples.every((s) => s.tMonoNs >= connectedAt - slackNs && s.tMonoNs <= to + slackNs), isTrue,
              reason: 'timestamps far from the phone clock: raw device time?');
          final last = <String, int>{};
          for (final s in samples) {
            final prev = last[s.channel];
            expect(prev == null || s.tMonoNs > prev, isTrue, reason: '${s.channel} time must increase');
            last[s.channel] = s.tMonoNs;
          }

          // The fastest channel runs at the declared rate (within 20 %).
          final perChannel = <String, int>{};
          for (final s in samples) {
            perChannel[s.channel] = (perChannel[s.channel] ?? 0) + 1;
          }
          final seconds = (to - from) / 1e9;
          final fastest = perChannel.values.reduce((a, b) => a > b ? a : b) / seconds;
          expect(fastest, closeTo(caps.nominalSampleRateHz, caps.nominalSampleRateHz * 0.2));

          // Every haptic command is accepted (a source without a motor ignores them).
          for (final c in HapticCommand.values) {
            expect(() => src.sendCommand(c), returnsNormally);
          }
          fa.flushMicrotasks();

          src.disconnect();
          fa.flushMicrotasks();
          expect(statuses.last.connected, isFalse, reason: 'reports disconnected');
          final count = samples.length;
          fa.elapse(const Duration(seconds: 1));
          expect(samples.length, count, reason: 'no samples after disconnect()');
        });
      });
    });
  }
}
