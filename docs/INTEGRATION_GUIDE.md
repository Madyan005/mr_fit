# Plugging in the real sensor and pose model

For the engineer who replaces the mocks once the hardware is chosen (DECISIONS O-1…O-4).
Everything below happens in the Flutter app (`mobile/`). The backend and the API contract
do not change: a set from real hardware is the same `SetSummaryPayload` with
`data_source: "real"`.

## The rule

Swapping Mock for Real is **one binding file**: `mobile/lib/app/bindings.dart`. The
session, the metrics engine, the screens and the database only see the interfaces
`SensorSource`, `VisionPipeline` and `TimeSync`. Hardware details (BLE UUIDs, packet
layouts, MAC addresses, byte values, model files) may appear **only** in the two REAL SLOT
files:

| Slot | File | Interface |
|---|---|---|
| Sensor | `mobile/lib/data/sensors/real/real_sensor_source.dart` | `domain/sensors/sensor_source.dart` |
| Pose | `mobile/lib/data/vision/real/real_vision_pipeline.dart` | `domain/vision/vision_pipeline.dart` |

Settings → Data source switches the whole app between the `SourceMode.mock` and
`SourceMode.real` lists in `sourceOverrides()`. While only one piece of hardware exists,
put the Mock binding back on the other line of the Real list. The SIMULATED banner and
each set's `data_source` follow what is bound, so a half-real setup is still labelled
simulated. The foreground service type follows the sensor alone: `connectedDevice` as soon
as the sensor is real (D-084, D-085, `test/app/bindings_test.dart`).

## Sensor (`RealSensorSource`)

What it must do:

1. **Capabilities.** Declare a source name, the nominal sample rate, and exactly the
   channels you send. Names come from `domain/sensors/channels.dart` only (mirror of
   `contracts/channels.v1.json`).
2. **Samples.** Emit `SensorSample(channel, value, tMonoNs, source)` on a broadcast
   stream. `tMonoNs` is **phone** monotonic time: pass the device timestamp through
   `timeSync.toPhoneMonoNs(sensorNs)`. Never emit the device's own epoch.
3. **Status.** Emit `DeviceStatus` on connect, on disconnect and about once a second:
   `connected`, `sourceLabel`, and optionally `batteryPct`, `rssi` and `restingDwell`
   ("bar racked"; if the device can't tell, leave it false and the engine detects
   stillness itself, D-019/D-052).
4. **Haptics.** Map each `HapticCommand` (fault double buzz, fatigue long buzz,
   inter-set sleep, wake) to device bytes in `sendCommand`. A device without a motor
   ignores them; the phone vibrates anyway.
5. **Transport and permissions.** BLE scanning and connection live inside the slot.
   Request `BLUETOOTH_SCAN` / `BLUETOOTH_CONNECT` there, at connect time (see
   `docs/ANDROID_PERMISSIONS.md`; Mock mode never asks for them).

What the rest of the app relies on:

| Feature | Needs | Without it |
|---|---|---|
| Calibration taps (Phase 4) | `accel_z` with a spike > g + 15 m/s² when the bar is tapped, within 600 ms of the phone tap (D-074). `TapTimeSync` takes the median of 3 taps | Calibration never completes; the scripted demo stops and says so |
| Measured bar velocity | `bar_vel_z` | Velocity comes from the camera and the HUD says "approximate" (D-050) |
| Velocity loss, reps | `bar_vel_z` or vision | — |
| Set end | `restingDwell`, or stillness | Stillness > 2 s ends the set |

The thresholds (tap spike, 600 ms window, framing 0.8) were tuned on the mock only and
must be checked with the real device.

## Pose model (`RealVisionPipeline`)

What it must do:

1. **Capabilities.** A pipeline name, `keypointSet: 'coco17'`, a max fps.
2. **Results.** `VisionFrameResult` with 17 COCO keypoints (indices in `Coco17`),
   normalised to 0..1 with x to the right and **y down**, confidences 0..1,
   `personInFrame`, and a `framingScore` 0..1 that reaches ≥ 0.8 when the whole body is
   in view (it drives Phase 3).
3. **Frame rate.** Honour `setTargetFps` (30 during a set, 10 at rest) by dropping frames.
   Run inference off the UI thread (isolate or platform thread).

**Camera frames: read this before starting.** There is no camera code in the app yet.
The session calls `analyze(CameraFrame(...))` on a timer at the target fps with an
**empty** frame that carries only the time (D-078). A real pipeline should therefore own
the camera (`camera` 0.12 is already a dependency: `CameraController.startImageStream`,
`CAMERA` permission). Each `analyze` call then answers with its newest result, stamped with
that frame's **capture** time on the phone monotonic clock. The contract test allows a
result up to 200 ms older than the request.

**Camera preview: not covered by the one-binding rule.** The session screens draw the
skeleton on black, labelled "SIMULATED POSE" in Mock mode (`SkeletonView` in
`presentation/session/skeleton_painter.dart`). Showing the live camera image behind the
skeleton is a UI addition in `presentation/session/`. The data path does not need it.

## Time sync

`TapTimeSync` is already the real algorithm and is bound in both modes (it measures the
mock sensor's simulated 37 ms clock lead today). A sensor whose clock is already the phone's
(for example the phone's own IMU) can bind a `TimeSync` with offset zero instead.

## Checking an implementation

1. Add the class to `subjects` in `mobile/test/data/sensor_source_contract_test.dart` or
   `mobile/test/data/vision_pipeline_contract_test.dart`. A subject that needs a device
   should only be added when an environment variable is set (as in
   `test/e2e/live_backend_test.dart`), so `flutter test` keeps working without hardware.
   The sensor test checks channels, phone-clock timestamps, rate, status and haptics. The
   vision test checks keypoints, ranges, orientation, time and fps.
2. Bind it in `bindings.dart` (Real list), switch Settings → Data source → Real.
3. Run a session by hand: Phase 1 shows your device label, battery and signal; Phase 3
   advances when framed; Phase 4 feels three taps; the HUD counts reps; the set ends when
   racked; the rest view shows "Uploaded." and a coaching card.
4. Check on a physical phone what the emulator cannot show: vibration, spoken cues,
   streaming with the screen off (foreground service type `connectedDevice` for a real
   sensor, D-077), battery use.

The gate stays the same: `flutter analyze` and `flutter test` exit 0.
