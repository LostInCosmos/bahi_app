import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_client.dart';
import '../models.dart';
import '../theme.dart';
import 'product_detail_screen.dart';

class InventoryScreen extends StatefulWidget {
  const InventoryScreen({super.key});

  @override
  State<InventoryScreen> createState() => InventoryScreenState();
}

class InventoryScreenState extends State<InventoryScreen> {
  final _searchController = TextEditingController();
  List<ProductSummary> _products = [];
  bool _loading = false;
  String? _error;

  // Deliberately no fetch here — see the same note in purchases_screen.dart:
  // HomeScreen's tab switcher calls refresh() the first (and every) time
  // this tab is actually selected, so every tab doesn't fetch on app open.

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Public so HomeScreen can trigger a reload when this tab is selected —
  /// IndexedStack keeps this widget's state alive across tab switches, so it
  /// won't otherwise notice stock added by a purchase while a different tab
  /// was active.
  Future<void> refresh() => _search();

  Future<void> _search() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final products = await ApiClient.instance.searchProducts(q: _searchController.text.trim());
      if (!mounted) return;
      setState(() => _products = products);
    } catch (e) {
      setState(() => _error = 'Could not load inventory: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: _search,
      child: ListView(
        padding: const EdgeInsets.all(Spacing.l),
        children: [
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              labelText: 'Search a medicine',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(icon: const Icon(Icons.arrow_forward), onPressed: _search),
            ),
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
          ),
          const SizedBox(height: Spacing.m),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: Spacing.m),
              child: Text(_error!, style: TextStyle(color: colors.error)),
            ),
          if (_products.isEmpty && !_loading)
            Padding(
              padding: const EdgeInsets.only(top: Spacing.xxl),
              child: Column(children: [
                Icon(Icons.medication_outlined, size: 48, color: colors.outline),
                const SizedBox(height: Spacing.s),
                Text('No products yet', style: TextStyle(color: colors.onSurfaceVariant)),
              ]),
            ),
          ..._products.map((p) {
            final outOfStock = p.quantityOnHand <= 0;
            return Padding(
              padding: const EdgeInsets.only(bottom: Spacing.s),
              child: Card(
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppRadius.card),
                  onTap: () {
                    HapticFeedback.selectionClick();
                    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProductDetailScreen(productId: p.id)));
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(Spacing.m),
                    child: Row(children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: colors.primaryContainer,
                          borderRadius: BorderRadius.circular(AppRadius.control),
                        ),
                        child: Icon(Icons.medication_outlined, size: 20, color: colors.onPrimaryContainer),
                      ),
                      const SizedBox(width: Spacing.m),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                            if (p.pack != null && p.pack!.isNotEmpty)
                              Text(p.pack!, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
                          ],
                        ),
                      ),
                      const SizedBox(width: Spacing.s),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: Spacing.s, vertical: 4),
                        decoration: BoxDecoration(
                          color: outOfStock ? colors.errorContainer : AppColors.statusSaved.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(AppRadius.chip),
                        ),
                        child: Text(
                          '${p.quantityOnHand.toStringAsFixed(0)} in stock',
                          style: TextStyle(
                            color: outOfStock ? colors.onErrorContainer : AppColors.statusSaved,
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ]),
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}
