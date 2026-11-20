import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../../domain/session/session_ports.dart';

/// Android foreground service for the duration of a session (D-046): keeps sensor
/// streaming and set persistence alive through rest intervals with the screen off.
/// Type `dataSync` in mock mode (no device is connected), `connectedDevice` for a real
/// external sensor. A refused service is logged; the session still runs in the foreground.
class ForegroundKeepAlive implements KeepAlive {
  bool _initialized = false;

  @override
  Future<void> start({required bool simulated}) async {
    try {
      if (!_initialized) {
        FlutterForegroundTask.init(
          androidNotificationOptions: AndroidNotificationOptions(
            channelId: 'mrfit_session',
            channelName: 'Training session',
            channelDescription: 'Shown while a training session is running',
          ),
          iosNotificationOptions: const IOSNotificationOptions(),
          foregroundTaskOptions: ForegroundTaskOptions(eventAction: ForegroundTaskEventAction.nothing()),
        );
        _initialized = true;
      }
      if (await FlutterForegroundTask.checkNotificationPermission() != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      if (await FlutterForegroundTask.isRunningService) return;
      final r = await FlutterForegroundTask.startService(
        serviceTypes: [simulated ? ForegroundServiceTypes.dataSync : ForegroundServiceTypes.connectedDevice],
        notificationTitle: 'MR-Fit session running',
        notificationText: simulated ? 'SIMULATED sensor data' : 'Recording your set',
      );
      if (r is ServiceRequestFailure) debugPrint('foreground service refused: ${r.error}');
    } on Object catch (e) {
      debugPrint('foreground service unavailable: $e');
    }
  }

  @override
  Future<void> stop() async {
    try {
      if (await FlutterForegroundTask.isRunningService) await FlutterForegroundTask.stopService();
    } on Object catch (e) {
      debugPrint('foreground service stop failed: $e');
    }
  }
}
