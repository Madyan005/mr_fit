# MR-Fit mobile (Flutter, Android)

> Written without a Flutter SDK on the build machine: **not yet compiled**. The first
> person with Flutter ≥ 3.44 should run the bootstrap below and report any compile errors.

## Bootstrap (once)

The repo contains `lib/`, `test/`, `pubspec.yaml` and the Android manifest. Generate the
rest of the Android scaffold. `flutter create` keeps existing files, including the manifest.

```bash
cd mobile
flutter create --platforms=android --org com.mrfit --project-name mr_fit .
# then in android/app/build.gradle.kts set:   minSdk = 26
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # drift code generation
```

## Run

```bash
flutter run                    # Mock mode is the default: runs on an emulator, no BLE/camera needed
flutter test                   # unit + golden tests (contract, mocks, MetricsEngine)
```

Point the app at the backend in **Settings → Backend URL**. Use `http://10.0.2.2:8000`
from the emulator, or `http://<PC-LAN-IP>:8000` from a phone.

## Architecture

```
lib/
  app/bindings.dart        THE one place that binds Mock vs Real (sensor, vision, time sync)
  domain/                  pure Dart: interfaces, models, contract, MetricsEngine (no Flutter, no hardware)
  data/sensors/mock|real   MockSensorSource / REAL SLOT
  data/vision/mock|real    MockVisionPipeline / REAL SLOT
  data/timesync/           MockTimeSync, TapTimeSync
  features/food/           optional, isolated
  presentation/            screens (Riverpod)
```

Rule: hardware names (ESP32, packet structs, UUIDs, MACs) may appear **only** in
`data/sensors/real/` and `data/vision/real/` files marked `// REAL SLOT`.
