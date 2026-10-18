import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/product_catalog.dart';
import '../models/product.dart';
import '../../../app/theme/app_theme.dart';
import 'product_detail_screen.dart';

class InventoryScreen extends StatefulWidget {
  const InventoryScreen({super.key});

  @override
  State<InventoryScreen> createState() => InventoryScreenState();
}

class InventoryScreenState extends State<InventoryScreen> {
  final _searchController = TextEditingController();
  final _catalog = ProductCatalog.instance;

  /// What is typed. Searched on the phone, against the whole list, as each
  /// letter is typed — no request per search (DAS-94).
  String _query = '';

  // Deliberately no fetch here — see the same note in purchases_screen.dart:
  // HomeScreen's tab switcher calls refresh() the first (and every) time
  // this tab is actually selected, so every tab doesn't fetch on app open.

  @override
  void initState() {
    super.initState();
    _catalog.addListener(_onCatalog);
  }

  @override
  void dispose() {
    _catalog.removeListener(_onCatalog);
    _searchController.dispose();
    super.dispose();
  }

  void _onCatalog() {
    if (mounted) setState(() {});
  }

  /// Public so HomeScreen can trigger a reload when this tab is selected —
  /// IndexedStack keeps this widget's state alive across tab switches, so it
  /// won't otherwise notice stock added by a purchase or taken by a sale
  /// while a different tab was active.
  Future<void> refresh() => _catalog.refresh();

  /// Net rate / MRP / expiry of a product's soonest-expiring in-stock batch,
  /// as short labels — only whichever of the three the server sent (DAS-81);
  /// all three are null together for a product with nothing in stock to
  /// price, so this is "if any", never a partial/misleading row.
  List<String> _batchDetails(ProductSummary p) => [
        if (p.netRate != null) 'Net ₹${p.netRate!.toStringAsFixed(2)}',
        if (p.mrp != null) 'MRP ₹${p.mrp!.toStringAsFixed(2)}',
        if (p.expiryDate != null) 'Exp ${p.expiryDate}',
      ];

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final index = _catalog.index;
    final products = index?.match(_query) ?? const <ProductSummary>[];
    final loading = index == null && _catalog.isLoading;
    final failure = _catalog.lastError;
    final header = <Widget>[
      TextField(
        key: const ValueKey('inventory-search'),
        controller: _searchController,
        onChanged: (typed) => setState(() => _query = typed),
        decoration: InputDecoration(
          hintText: 'Search a medicine',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Clear search',
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _query = '');
                  },
                ),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.chip), borderSide: BorderSide.none),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.chip), borderSide: BorderSide.none),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.chip),
            borderSide: BorderSide(color: colors.primary, width: 2),
          ),
        ),
        textInputAction: TextInputAction.search,
      ),
      if (products.isNotEmpty) ...[
        const SizedBox(height: Spacing.l),
        Row(
          children: [
            Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.only(right: Spacing.xs),
              decoration: BoxDecoration(color: colors.primary, shape: BoxShape.circle),
            ),
            Text(
              'CURRENT STOCK',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    letterSpacing: 0.6,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ],
        ),
      ],
      const SizedBox(height: Spacing.m),
      if (failure != null)
        Padding(
          padding: const EdgeInsets.only(bottom: Spacing.m),
          child: Text('Could not load inventory: $failure', style: TextStyle(color: colors.error)),
        ),
      if (loading)
        const Padding(
          padding: EdgeInsets.only(top: Spacing.xxl),
          child: Center(child: CircularProgressIndicator()),
        ),
      if (products.isEmpty && index != null)
        Padding(
          padding: const EdgeInsets.only(top: Spacing.xxl),
          child: Column(children: [
            Icon(Icons.medication_outlined, size: 48, color: colors.outline),
            const SizedBox(height: Spacing.s),
            Text(_query.trim().isEmpty ? 'No products yet' : 'No medicine matches that',
                style: TextStyle(color: colors.onSurfaceVariant)),
          ]),
        ),
    ];
    return RefreshIndicator(
      onRefresh: refresh,
      // Built as they scroll into view: a short search shows hundreds of
      // products, and only the visible rows are worth building.
      child: ListView.builder(
        padding: const EdgeInsets.all(Spacing.l),
        itemCount: header.length + products.length,
        itemBuilder: (context, i) {
          if (i < header.length) return header[i];
          final p = products[i - header.length];
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
                          if (_batchDetails(p).isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              _batchDetails(p).join('  ·  '),
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
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
        },
      ),
    );
  }
}
