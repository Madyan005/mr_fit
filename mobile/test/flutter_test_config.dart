import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

/// Applies to every test file. A tap that hits nothing (off-screen or covered widget)
/// fails the test instead of only printing a warning, so UI tests cannot pass by accident.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  WidgetController.hitTestWarningShouldBeFatal = true;
  await testMain();
}
