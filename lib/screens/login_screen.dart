import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_client.dart';
import '../theme.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _tenantNameController = TextEditingController();
  final _geminiKeyController = TextEditingController();
  final _baseUrlController = TextEditingController(text: ApiClient.instance.baseUrl);

  bool _signupMode = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _tenantNameController.dispose();
    _geminiKeyController.dispose();
    _baseUrlController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ApiClient.instance.setBaseUrl(_baseUrlController.text.trim());
      if (_signupMode) {
        await ApiClient.instance.signup(
          tenantName: _tenantNameController.text.trim(),
          email: _emailController.text.trim(),
          password: _passwordController.text,
          geminiApiKey: _geminiKeyController.text.trim().isEmpty ? null : _geminiKeyController.text.trim(),
        );
      } else {
        await ApiClient.instance.login(
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );
      }
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const HomeScreen()));
    } catch (e) {
      HapticFeedback.heavyImpact();
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(Spacing.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: Spacing.l),
                  Center(
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [colors.primary, colors.primary.withValues(alpha: 0.7)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: const Icon(Icons.receipt_long_rounded, color: Colors.white, size: 36),
                    ),
                  ),
                  const SizedBox(height: Spacing.l),
                  Text(
                    'Bahi',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.displaySmall,
                  ),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    'GST bill capture & reconciliation',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
                  ),
                  const SizedBox(height: Spacing.xxl),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(Spacing.l),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Login/Signup segmented toggle -- an explicit switch
                          // rather than a plain text link, so which mode is
                          // active is always visible, not just implied by
                          // which fields happen to be showing.
                          _ModeToggle(
                            signupMode: _signupMode,
                            onChanged: _busy
                                ? null
                                : (v) {
                                    HapticFeedback.selectionClick();
                                    setState(() => _signupMode = v);
                                  },
                          ),
                          const SizedBox(height: Spacing.l),
                          AnimatedSize(
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOutCubic,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (_signupMode) ...[
                                  TextField(
                                    controller: _tenantNameController,
                                    decoration: const InputDecoration(
                                      labelText: 'Shop / tenant name',
                                      prefixIcon: Icon(Icons.storefront_outlined),
                                    ),
                                  ),
                                  const SizedBox(height: Spacing.m),
                                ],
                                TextField(
                                  controller: _emailController,
                                  keyboardType: TextInputType.emailAddress,
                                  decoration: const InputDecoration(
                                    labelText: 'Email',
                                    prefixIcon: Icon(Icons.mail_outline),
                                  ),
                                ),
                                const SizedBox(height: Spacing.m),
                                TextField(
                                  controller: _passwordController,
                                  obscureText: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Password',
                                    prefixIcon: Icon(Icons.lock_outline),
                                  ),
                                ),
                                if (_signupMode) ...[
                                  const SizedBox(height: Spacing.m),
                                  TextField(
                                    controller: _geminiKeyController,
                                    decoration: const InputDecoration(
                                      labelText: 'Gemini API key (optional)',
                                      helperText: 'Leave blank to use the pooled server key',
                                      prefixIcon: Icon(Icons.vpn_key_outlined),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(height: Spacing.s),
                          Theme(
                            data: Theme.of(context).copyWith(
                              listTileTheme: const ListTileThemeData(dense: true),
                            ),
                            child: ExpansionTile(
                              tilePadding: EdgeInsets.zero,
                              title: Text('Server address', style: Theme.of(context).textTheme.bodySmall),
                              childrenPadding: const EdgeInsets.only(bottom: Spacing.s),
                              children: [
                                TextField(
                                  controller: _baseUrlController,
                                  decoration: const InputDecoration(
                                    labelText: 'API base URL',
                                    helperText:
                                        'Emulator: http://10.0.2.2:8000 — physical device: http://<your-computer-LAN-IP>:8000',
                                    prefixIcon: Icon(Icons.dns_outlined),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 180),
                            child: _error == null
                                ? const SizedBox.shrink()
                                : Padding(
                                    key: ValueKey(_error),
                                    padding: const EdgeInsets.only(top: Spacing.s, bottom: Spacing.s),
                                    child: Container(
                                      padding: const EdgeInsets.all(Spacing.m),
                                      decoration: BoxDecoration(
                                        color: colors.errorContainer,
                                        borderRadius: BorderRadius.circular(AppRadius.control),
                                      ),
                                      child: Text(
                                        _error!,
                                        style: TextStyle(color: colors.onErrorContainer),
                                      ),
                                    ),
                                  ),
                          ),
                          const SizedBox(height: Spacing.s),
                          FilledButton(
                            onPressed: _busy ? null : _submit,
                            child: _busy
                                ? const SizedBox(
                                    height: 18,
                                    width: 18,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                  )
                                : Text(_signupMode ? 'Create account' : 'Log in'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A pill-shaped two-option switch — replaces the old plain text link so the
/// current mode (log in vs. create account) is always visually explicit.
class _ModeToggle extends StatelessWidget {
  final bool signupMode;
  final ValueChanged<bool>? onChanged;
  const _ModeToggle({required this.signupMode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      child: Row(
        children: [
          Expanded(child: _segment(context, 'Log in', !signupMode, () => onChanged?.call(false))),
          Expanded(child: _segment(context, 'Sign up', signupMode, () => onChanged?.call(true))),
        ],
      ),
    );
  }

  Widget _segment(BuildContext context, String label, bool selected, VoidCallback onTap) {
    final colors = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected ? colors.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.chip),
          boxShadow: selected ? [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 4)] : null,
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? colors.onSurface : colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
