import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/providers.dart';
import '../../app/session.dart';
import '../widgets/simulated_banner.dart';

/// One tab of the home shell. Pages are registered in [HomeShell.pages].
final class ShellPage {
  const ShellPage(this.label, this.icon, this.builder);
  final String label;
  final IconData icon;
  final Widget Function() builder;
}

/// Ported v1 navigation (Track / Library / Stats / Coach) as a bottom NavigationBar.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key, required this.pages});
  final List<ShellPage> pages;

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    final notice = ref.read(startupNoticeProvider);
    if (notice != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(notice)));
      });
    }
  }

  Future<void> _signOut() async {
    final pending = ref.read(pendingUploadsProvider).value ?? 0;
    if (pending > 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Sign out?'),
          content: Text('$pending upload(s) are still waiting. They stay on this phone and '
              'continue when you sign in again with this account.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Sign out')),
          ],
        ),
      );
      if (!(ok ?? false)) return;
    }
    await ref.read(sessionProvider.notifier).signOut();
  }

  @override
  Widget build(BuildContext context) {
    final pending = ref.watch(pendingUploadsProvider).value ?? 0;
    final page = widget.pages[_index];
    return Scaffold(
      appBar: AppBar(
        title: Text(page.label),
        actions: [
          if (pending > 0)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Tooltip(
                message: '$pending upload(s) waiting',
                child: Badge(label: Text('$pending'), child: const Icon(Icons.cloud_upload_outlined)),
              ),
            ),
          IconButton(
            key: const Key('shell.signout'),
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: _signOut,
          ),
        ],
      ),
      body: Column(
        children: [
          const SimulatedBanner(),
          Expanded(child: KeyedSubtree(key: ValueKey(_index), child: page.builder())),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [for (final p in widget.pages) NavigationDestination(icon: Icon(p.icon), label: p.label)],
      ),
    );
  }
}
