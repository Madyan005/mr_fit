# Android permissions and the foreground service

Declared in `mobile/android/app/src/main/AndroidManifest.xml`. Runtime prompts are
requested only when the feature is first used, through `permission_handler`.

| Permission | Why | Runtime prompt | Needed in mock mode |
|---|---|---|---|
| `INTERNET` | Backend API on the LAN | no | yes |
| `CAMERA` | Live preview + pose (Phase 3–6) | yes | yes, for the preview (the mock skeleton works without it) |
| `RECORD_AUDIO` | Voice notes (`speech_to_text`) | yes | optional |
| `VIBRATE` | Haptic cues on the phone | no | yes |
| `POST_NOTIFICATIONS` (API 33+) | Ongoing foreground-service notification | yes | yes |
| `FOREGROUND_SERVICE` | Keep streaming during rest | no | yes |
| `FOREGROUND_SERVICE_DATA_SYNC` | FGS type used in **mock** mode | no | yes |
| `FOREGROUND_SERVICE_CONNECTED_DEVICE` | FGS type for a **real** external sensor | no | no |
| `FOREGROUND_SERVICE_CAMERA` | FGS type when pose runs while locked | no | no |
| `WAKE_LOCK` | Keep CPU awake during a set | no | yes |
| `BLUETOOTH_SCAN` (`neverForLocation`), `BLUETOOTH_CONNECT` (API 31+) | REAL SLOT BLE sensor only | yes | no |
| `BLUETOOTH`, `BLUETOOTH_ADMIN` (≤ API 30) | Legacy BLE | no | no |

## Foreground service choice

`flutter_foreground_task` comes first, as the spec requires. No custom Kotlin service is needed:
- The plugin's own `ForegroundService` is declared with
  `foregroundServiceType="dataSync|connectedDevice|camera"`.
- The app picks the type at start time: `dataSync` while mocks are bound, and
  `connectedDevice` for a real external sensor.
- On Android 14+, a `connectedDevice` service may only start once a prerequisite permission
  such as `BLUETOOTH_CONNECT` has been granted. Mock mode never asks for Bluetooth, so it
  uses `dataSync` instead.
- ASSUMPTION: Android 15 limits `dataSync` services to about 6 h per day. That is fine for
  training sessions.

A thin native Kotlin service would only be justified if a real sensor's SDK required
binding from native code. Nothing does yet (O-1).

## minSdk

Several plugins need a recent minSdk, so set `minSdk = 26` in
`android/app/build.gradle.kts` after bootstrapping (`mobile/README.md`).
ASSUMPTION: 26 is chosen as a safe floor for `flutter_secure_storage` 11 and the SQLCipher
build. It is not tested on devices.
