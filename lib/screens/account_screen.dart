import 'package:flutter/material.dart';

import '../api_client.dart';
import '../models.dart';
import '../theme.dart';

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
  final _geminiKeyController = TextEditingController();
  String _businessType = 'medical';

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
    _geminiKeyController.dispose();
    super.dispose();
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
        _businessType = account.businessType;
      });
    } catch (e) {
      setState(() => _error = 'Could not load account: $e');
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
        geminiApiKey: _geminiKeyController.text.isEmpty ? null : _geminiKeyController.text,
      );
      if (!mounted) return;
      setState(() {
        _account = account;
        _geminiKeyController.clear();
        _savedMessage = 'Saved.';
      });
    } on ApiException catch (e) {
      setState(() => _error = 'Could not save: ${e.message}');
    } catch (e) {
      setState(() => _error = 'Could not save: $e');
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
                  DropdownButtonFormField<String>(
                    initialValue: _businessType,
                    decoration: const InputDecoration(
                      labelText: 'Business type',
                      helperText: "Tunes how bills are read and checked — a kirana bill's columns "
                          "work differently from a pharmacy bill's.",
                      helperMaxLines: 3,
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
                  TextField(
                    controller: _geminiKeyController,
                    obscureText: true,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: 'Gemini API key',
                      helperText: (_account?.hasGeminiApiKey ?? false)
                          ? 'A key is already set — leave this blank to keep it, or enter a new one to replace it.'
                          : 'No key set — using the pooled server key. Enter one here to use your own instead.',
                      helperMaxLines: 2,
                    ),
                  ),
                  const SizedBox(height: Spacing.l),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Spacing.m),
                      child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ),
                  if (_savedMessage != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Spacing.m),
                      child: Text(_savedMessage!, style: const TextStyle(color: AppColors.statusSaved)),
                    ),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(
                            height: 16,
                            width: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('Save details'),
                  ),
                ],
              ),
            ),
    );
  }
}
