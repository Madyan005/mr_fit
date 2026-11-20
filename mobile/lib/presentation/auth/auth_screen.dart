import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/providers.dart';
import '../../app/session.dart';
import '../../data/api/api_exception.dart';
import '../../data/auth/token_store.dart';
import '../widgets/simulated_banner.dart';

/// Ported from the v1 auth card (archive/legacy_v1/static/index.html): backend URL,
/// Login / Sign up, email + password. Same client-side rules as the server's AuthRequest.
class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key, this.notice});
  final String? notice;

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _url = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _signup = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    ref.read(tokenStoreProvider).baseUrl().then((u) {
      if (mounted && _url.text.isEmpty) _url.text = u;
    });
  }

  @override
  void dispose() {
    _url.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  String? _validate() {
    try {
      TokenStore.normalizeBaseUrl(_url.text);
    } on FormatException catch (e) {
      return e.message;
    }
    final email = _email.text.trim();
    if (email.length < 3 || !email.contains('@') || email.startsWith('@') || email.endsWith('@')) {
      return 'Enter a valid email address';
    }
    if (_password.text.length < 6) return 'Password must be at least 6 characters';
    return null;
  }

  Future<void> _submit({bool discard = false}) async {
    final problem = _validate();
    if (problem != null) return setState(() => _error = problem);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(sessionProvider.notifier).signIn(
            baseUrl: _url.text,
            email: _email.text,
            password: _password.text,
            signup: _signup,
            discardOtherAccountData: discard,
          );
    } on OtherAccountDataPending catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Unsynced sets on this phone'),
          content: Text('${e.pendingSets} set(s) recorded by ${e.ownerEmail} have not been uploaded yet. '
              'Signing in with another account deletes them from this phone.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete and continue')),
          ],
        ),
      );
      if (ok ?? false) await _submit(discard: true);
      return;
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on FormatException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final notice = widget.notice;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const SimulatedBanner(),
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: AutofillGroup(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text('MR-Fit', textAlign: TextAlign.center, style: theme.textTheme.displaySmall),
                          Text('Speed and simplicity.', textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
                          const SizedBox(height: 24),
                          if (notice != null) ...[
                            Card(
                              color: theme.colorScheme.secondaryContainer,
                              child: Padding(padding: const EdgeInsets.all(12), child: Text(notice)),
                            ),
                            const SizedBox(height: 12),
                          ],
                          TextField(
                            key: const Key('auth.url'),
                            controller: _url,
                            keyboardType: TextInputType.url,
                            decoration: const InputDecoration(
                              labelText: 'Backend URL',
                              helperText: 'Your FastAPI server, e.g. http://192.168.1.20:8000',
                            ),
                          ),
                          const SizedBox(height: 16),
                          SegmentedButton<bool>(
                            segments: const [
                              ButtonSegment(value: false, label: Text('Login')),
                              ButtonSegment(value: true, label: Text('Sign up')),
                            ],
                            selected: {_signup},
                            onSelectionChanged: (s) => setState(() {
                              _signup = s.first;
                              _error = null;
                            }),
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            key: const Key('auth.email'),
                            controller: _email,
                            keyboardType: TextInputType.emailAddress,
                            autofillHints: const [AutofillHints.email],
                            decoration: const InputDecoration(labelText: 'Email'),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            key: const Key('auth.password'),
                            controller: _password,
                            obscureText: true,
                            autofillHints: [_signup ? AutofillHints.newPassword : AutofillHints.password],
                            decoration: const InputDecoration(labelText: 'Password'),
                            onSubmitted: (_) => _busy ? null : _submit(),
                          ),
                          const SizedBox(height: 20),
                          FilledButton(
                            key: const Key('auth.submit'),
                            onPressed: _busy ? null : _submit,
                            child: _busy
                                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                : Text(_signup ? 'Create account' : 'Login'),
                          ),
                          if (_error != null) ...[
                            const SizedBox(height: 12),
                            Text(_error!,
                                key: const Key('auth.error'),
                                textAlign: TextAlign.center,
                                style: TextStyle(color: theme.colorScheme.error)),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
