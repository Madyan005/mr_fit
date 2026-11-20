import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:vibration/vibration.dart';

import '../../domain/sensors/sensor_models.dart';
import '../../domain/session/session_ports.dart';

/// Phone vibration + text-to-speech. A missing vibrator or TTS engine is logged and
/// ignored: cues are helpful, never required to finish a set.
class DeviceCueOutput implements CueOutput {
  final FlutterTts _tts = FlutterTts();
  bool _ttsReady = false;

  /// Patterns in ms: [wait, on, off, on, ...].
  static const patterns = {
    HapticCommand.faultDoubleBuzz: [0, 120, 90, 120],
    HapticCommand.fatigueLongBuzz: [0, 700],
    HapticCommand.interSetSleep: [0, 60, 60, 60, 60, 60],
    HapticCommand.wake: [0, 80],
  };

  @override
  Future<void> haptic(HapticCommand c) async {
    try {
      if (await Vibration.hasVibrator()) await Vibration.vibrate(pattern: patterns[c]!);
    } on Object catch (e) {
      debugPrint('haptic unavailable: $e');
    }
  }

  @override
  Future<void> speak(String text) async {
    try {
      if (!_ttsReady) {
        await _tts.setLanguage('en-US');
        await _tts.setSpeechRate(0.5);
        _ttsReady = true;
      }
      await _tts.speak(text);
    } on Object catch (e) {
      debugPrint('tts unavailable: $e');
    }
  }

  @override
  Future<void> stopSpeaking() async {
    try {
      await _tts.stop();
    } on Object catch (e) {
      debugPrint('tts stop failed: $e');
    }
  }
}
