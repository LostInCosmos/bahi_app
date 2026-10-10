import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/api/api_client.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/widgets/dastavez_logo.dart';
import '../../home/presentation/home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _tenantNameController = TextEditingController();
  final _baseUrlController = TextEditingController(text: ApiClient.instance.baseUrl);

  bool _signupMode = false;
  bool _busy = false;
  bool _obscurePassword = true;
  String? _error;
  String _businessType = 'medical';

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _tenantNameController.dispose();
    _baseUrlController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (kAllowServerOverride) {
        await ApiClient.instance.setBaseUrl(_baseUrlController.text.trim());
      }
      if (_signupMode) {
        await ApiClient.instance.signup(
          tenantName: _tenantNameController.text.trim(),
          email: _emailController.text.trim(),
          password: _passwordController.text,
          businessType: _businessType,
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
      if (mounted) setState(() => _error = e.toString());
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
                  const Center(child: DastavezLogoTile(size: 88)),
                  const SizedBox(height: Spacing.l),
                  Text(
                    'Dastavez',
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
                                  DropdownButtonFormField<String>(
                                    initialValue: _businessType,
                                    decoration: const InputDecoration(
                                      labelText: 'Business type',
                                      prefixIcon: Icon(Icons.category_outlined),
                                    ),
                                    items: const [
                                      DropdownMenuItem(value: 'medical', child: Text('Medical / Pharmacy')),
                                      DropdownMenuItem(value: 'kirana', child: Text('Kirana / General store')),
                                      DropdownMenuItem(value: 'other', child: Text('Other')),
                                    ],
                                    onChanged: (v) {
                                      if (v != null) setState(() => _businessType = v);
                                    },
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
                                  obscureText: _obscurePassword,
                                  decoration: InputDecoration(
                                    labelText: 'Password',
                                    prefixIcon: const Icon(Icons.lock_outline),
                                    suffixIcon: IconButton(
                                      icon: Icon(_obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                                      onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                                    ),
                                  ),
                                ),
                                if (!_signupMode)
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: TextButton(
                                      onPressed: () {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(content: Text("Password reset isn't available yet — contact support.")),
                                        );
                                      },
                                      child: const Text('Forgot password?'),
                                    ),
                                  ),
                ],
                            ),
                          ),
                          if (kAllowServerOverride) ...[
                            const SizedBox(height: Spacing.s),
                            Theme(
                              data: Theme.of(context).copyWith(
                                listTileTheme: const ListTileThemeData(dense: true),
                              ),
                              child: ExpansionTile(
                                tilePadding: EdgeInsets.zero,
                                leading: Icon(Icons.settings_outlined, color: colors.onSurfaceVariant, size: 20),
                                title: const Text('Advanced setting'),
                                subtitle: Text(
                                  'Optional · keep the default unless instructed',
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                                ),
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
                          ],
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
                  const SizedBox(height: Spacing.l),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.shield_outlined, size: 14, color: colors.onSurfaceVariant),
                      const SizedBox(width: Spacing.xs),
                      Text(
                        'Secure access for your store workspace',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ],
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
