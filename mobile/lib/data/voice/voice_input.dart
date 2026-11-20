import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Dictation for the Track input (v1 mic button). Behind an interface so widget tests
/// do not need the platform plugin.
abstract interface class VoiceInput {
  /// False when speech recognition is unavailable or the microphone permission was denied.
  Future<bool> start(void Function(String words, bool isFinal) onWords);
  Future<void> stop();
}

class SpeechToTextVoiceInput implements VoiceInput {
  final SpeechToText _stt = SpeechToText();

  @override
  Future<bool> start(void Function(String words, bool isFinal) onWords) async {
    if (!await _stt.initialize()) return false;
    await _stt.listen(
      onResult: (SpeechRecognitionResult r) => onWords(r.recognizedWords, r.finalResult),
      listenOptions: SpeechListenOptions(partialResults: true, cancelOnError: true),
    );
    return true;
  }

  @override
  Future<void> stop() => _stt.stop();
}
