import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/api/api_client.dart';
import '../../../core/config/business_types.dart';
import '../../../core/widgets/busy_button.dart';
import '../../../core/widgets/inline_message.dart';
import '../../../core/config/legal_documents.dart';
import '../widgets/stock_page_card.dart';
import '../data/auth_api.dart';
import '../models/account.dart';
import 'legal_screen.dart';
import 'sign_out.dart';

/// Shop details — the mobile counterpart of the web app's Account page.
/// Business type in particular tunes how bills are read and validated (see
/// services/extraction.py / services/validation.py on the backend) — a
/// kirana bill's quantity/amount columns work differently from a
/// pharmacy's, so this needs to be settable without going through the web
/// app, which was previously the only place that could change it.
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _shopNameController = TextEditingController();
  final _gstinController = TextEditingController();
  final _addressController = TextEditingController();
  final _dlNoController = TextEditingController();
  final _phoneController = TextEditingController();
  String _businessType = kDefaultBusinessType;

  AccountInfo? _account;
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _savedMessage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _shopNameController.dispose();
    _gstinController.dispose();
    _addressController.dispose();
    _dlNoController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  /// Asks for the password, deletes the account on the server, then forgets
  /// the shop on this device and lands on the login screen (R1, 2026-10-19).
  Future<void> _confirmDelete() async {
    final tenantId = ApiClient.instance.tenantId;
    final deleted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _DeleteAccountDialog(),
    );
    if (deleted != true || !mounted) return;
    if (tenantId != null) await forgetShopOnDevice(tenantId);
    if (!mounted) return;
    await signOut(context);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final account = await ApiClient.instance.getAccount();
      if (!mounted) return;
      setState(() {
        _account = account;
        _shopNameController.text = account.tenantName;
        _gstinController.text = account.gstin ?? '';
        _addressController.text = account.address ?? '';
        _dlNoController.text = account.dlNo ?? '';
        _phoneController.text = account.phone ?? '';
        _businessType = account.businessType;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load account: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
      _savedMessage = null;
    });
    try {
      final account = await ApiClient.instance.updateAccount(
        tenantName: _shopNameController.text.trim(),
        gstin: _gstinController.text.trim().toUpperCase(),
        address: _addressController.text.trim(),
        businessType: _businessType,
        // Sent as typed: an empty field clears it (DAS-121).
        dlNo: _dlNoController.text,
        phone: _phoneController.text,
      );
      if (!mounted) return;
      setState(() {
        _account = account;
        // The server keeps the phone as its 10 digits: show what it kept.
        _phoneController.text = account.phone ?? '';
        _savedMessage = 'Saved.';
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = 'Could not save: ${e.message}');
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: ListView(
                padding: const EdgeInsets.all(Spacing.l),
                children: [
                  if (_account != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Spacing.l),
                      child: Text('Signed in as ${_account!.email}', style: Theme.of(context).textTheme.bodyMedium),
                    ),
                  Text('Shop details', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: Spacing.m),
                  TextField(
                    controller: _shopNameController,
                    decoration: const InputDecoration(labelText: 'Shop name'),
                  ),
                  const SizedBox(height: Spacing.m),
                  TextField(
                    controller: _gstinController,
                    maxLength: 15,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: 'Shop GSTIN',
                      helperText: 'Used on the GSTR2 export and to classify Local/Central purchases',
                    ),
                  ),
                  const SizedBox(height: Spacing.m),
                  TextField(
                    controller: _addressController,
                    decoration: const InputDecoration(labelText: 'Shop address'),
                  ),
                  const SizedBox(height: Spacing.m),
                  TextField(
                    controller: _dlNoController,
                    maxLength: 100,
                    decoration: const InputDecoration(
                      labelText: 'Drug licence no.',
                      helperText: 'Prints on your bills. Clear it to leave it off.',
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: Spacing.m),
                  TextField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'Shop phone',
                      helperText: 'Prints on your bills. 10 digits; +91 or 0 in front is fine.',
                    ),
                  ),
                  const SizedBox(height: Spacing.m),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: _businessType,
                    decoration: const InputDecoration(
                      labelText: 'Business type',
                      helperText: "Tunes how bills are read and checked — a kirana bill's columns "
                          "work differently from a pharmacy bill's.",
                      helperMaxLines: 3,
                    ),
                    items: businessTypeItems(),
                    onChanged: (v) {
                      if (v != null) setState(() => _businessType = v);
                    },
                  ),
                  const SizedBox(height: Spacing.l),
                  ErrorText(_error, padding: const EdgeInsets.only(bottom: Spacing.m)),
                  if (_savedMessage != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Spacing.m),
                      child: Text(_savedMessage!, style: const TextStyle(color: AppColors.statusSaved)),
                    ),
                  BusyFilledButton(busy: _saving, onPressed: _save, label: 'Save details'),
                  // Only while the shop's page is live; otherwise nothing at all.
                  if (_account?.publicStockUrl != null) ...[
                    const SizedBox(height: Spacing.xl),
                    StockPageCard(
                      url: _account!.publicStockUrl!,
                      posterUrl: _account!.publicPosterUrl,
                      shopName: _account!.tenantName,
                    ),
                  ],
                  const SizedBox(height: Spacing.xl),
                  Text('Legal', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: Spacing.xs),
                  for (final doc in legalDocuments)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.description_outlined),
                      title: Text(doc.title),
                      subtitle: Text('Version ${doc.version} · ${doc.effectiveDate}'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => LegalScreen.open(context, doc.id),
                    ),
                  const SizedBox(height: Spacing.xl),
                  Text('Delete account', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    'Deletes this shop and everything in it — bills, stock, sales and every sign-in — within 30 days. '
                    'Export your records first; they cannot be recovered. You can also ask by email at $kSupportEmail.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: Spacing.s),
                  OutlinedButton.icon(
                    key: const ValueKey('delete-account'),
                    onPressed: _loading ? null : _confirmDelete,
                    style: OutlinedButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                    icon: const Icon(Icons.delete_forever_outlined),
                    label: const Text('Delete account'),
                  ),
                ],
              ),
            ),
    );
  }
}

/// "Type your password to delete": the server refuses a wrong one with
/// `403 wrong_password` and the shopkeeper tries again; any other failure is
/// shown as it is. Pops `true` only after the server answered `204`.
class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog();

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _password.addListener(() => setState(() {})); // Delete enables once something is typed
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ApiClient.instance.deleteAccount(password: _password.text);
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.errorCode == 'wrong_password' ? 'Wrong password. Try again.' : 'Could not delete: $e');
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not delete: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Delete this account?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Everything in this shop will be removed within 30 days and cannot be recovered. '
              'Enter your password to confirm.'),
          const SizedBox(height: Spacing.m),
          TextField(
            key: const ValueKey('delete-password'),
            controller: _password,
            obscureText: true,
            autofocus: true,
            enabled: !_busy,
            decoration: const InputDecoration(labelText: 'Password'),
            onSubmitted: (_) => _busy ? null : _delete(),
          ),
          ErrorText(_error, padding: const EdgeInsets.only(top: Spacing.s)),
        ],
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
        TextButton(
          key: const ValueKey('delete-confirm'),
          onPressed: _busy || _password.text.isEmpty ? null : _delete,
          child: _busy
              ? const ButtonSpinner(size: 18)
              : Text('Delete', style: TextStyle(color: colors.error)),
        ),
      ],
    );
  }
}
