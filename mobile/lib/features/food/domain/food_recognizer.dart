/// OPTIONAL, isolated food feature (O-2). Nothing in the biomechanics flow imports this.
library;

/// Image bytes + MIME type. (Not `Image`: ambiguous between dart:ui and widgets, D-020.)
final class FoodImage {
  const FoodImage({required this.bytes, required this.mimeType});
  final List<int> bytes;
  final String mimeType;
}

final class FoodGuess {
  const FoodGuess({required this.label, required this.confidence, this.kcalPer100g, this.gramsEstimate});
  final String label;
  final double confidence; // 0..1
  final double? kcalPer100g;
  final double? gramsEstimate;
}

abstract class FoodRecognizer {
  Future<List<FoodGuess>> recognize(FoodImage img);
}

/// Mock: always returns the same guess, so the feature can be demoed on an emulator.
class MockFoodRecognizer implements FoodRecognizer {
  @override
  Future<List<FoodGuess>> recognize(FoodImage img) async =>
      const [FoodGuess(label: 'mixed salad (SIMULATED)', confidence: 0.5, kcalPer100g: 90)];
}
