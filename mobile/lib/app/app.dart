import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../presentation/auth/auth_screen.dart';
import '../presentation/shell/home_shell.dart';
import '../presentation/track/track_screen.dart';
import 'session.dart';

/// Tabs of the signed-in app. Each ported screen replaces its placeholder in step 5c.
List<ShellPage> appPages() => [
      ShellPage('Track', Icons.today_outlined, () => const TrackScreen()),
      ShellPage('Library', Icons.fitness_center, () => const _ComingSoon('Library')),
      ShellPage('Stats', Icons.insights_outlined, () => const _ComingSoon('Stats')),
      ShellPage('Coach', Icons.sports_outlined, () => const _ComingSoon('Coach')),
    ];

class MrFitApp extends ConsumerWidget {
  const MrFitApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    return MaterialApp(
      title: 'MR-Fit',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal, brightness: Brightness.dark)),
      home: switch (session) {
        AsyncData(value: SessionState(status: SessionStatus.signedIn)) => HomeShell(pages: appPages()),
        AsyncData(:final value) => AuthScreen(key: ValueKey(value.notice), notice: value.notice),
        AsyncError() => const AuthScreen(notice: 'Could not read the saved session. Please sign in.'),
        _ => const Scaffold(body: Center(child: CircularProgressIndicator())),
      },
    );
  }
}

class _ComingSoon extends StatelessWidget {
  const _ComingSoon(this.name);
  final String name;

  @override
  Widget build(BuildContext context) => Center(child: Text('$name screen'));
}
