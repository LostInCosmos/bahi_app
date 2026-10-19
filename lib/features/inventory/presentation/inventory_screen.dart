import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/navigation/tab_screen.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/inline_message.dart';
import '../data/product_catalog.dart';
import '../models/product.dart';
import '../models/product_search.dart';
import '../widgets/product_name.dart';
import 'product_detail_screen.dart';

class InventoryScreen extends StatefulWidget {
  const InventoryScreen({super.key});

  @override
  State<InventoryScreen> createState() => InventoryScreenState();
}

class InventoryScreenState extends State<InventoryScreen> with TabScreen {
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

  /// Called by HomeScreen when this tab is selected — IndexedStack keeps this
  /// widget's state alive across tab switches, so it won't otherwise notice
  /// stock added by a purchase or taken by a sale while a different tab was
  /// active.
  @override
  Future<void> refresh() => _catalog.refresh();

  /// Net rate / MRP / expiry of a product's soonest-expiring in-stock batch,
  /// as one line — only whichever of the three the server sent (DAS-81);
  /// all three are null together for a product with nothing in stock to
  /// price, so this is "if any", never a partial/misleading row.
  static String? _batchDetails(ProductSummary p) {
    final parts = [
      if (p.netRate != null) 'Net ${rupees(p.netRate!)}',
      if (p.mrp != null) 'MRP ${rupees(p.mrp!)}',
      if (p.expiryDate != null) 'Exp ${p.expiryDate}',
    ];
    return parts.isEmpty ? null : parts.join('  ·  ');
  }

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
        ErrorText('Could not load inventory: $failure', padding: const EdgeInsets.only(bottom: Spacing.m)),
      if (loading)
        const Padding(
          padding: EdgeInsets.only(top: Spacing.xxl),
          child: Center(child: CircularProgressIndicator()),
        ),
      if (products.isEmpty && index != null)
        EmptyHint(
          icon: Icons.medication_outlined,
          text: _query.trim().isEmpty ? 'No products yet' : 'No medicine matches that',
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
          return _ProductRow(products[i - header.length], index!);
        },
      ),
    );
  }
}

class _ProductRow extends StatelessWidget {
  final ProductSummary product;
  final ProductIndex index;
  const _ProductRow(this.product, this.index);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final p = product;
    final outOfStock = p.quantityOnHand <= 0;
    final details = InventoryScreenState._batchDetails(p);
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
                    // Beside the name only when the shop has this name more
                    // than once (ADR-020); the pack line below stays for every
                    // product that has one (user decision, 2026-10-19).
                    ProductName(p.name,
                        qualifier: index.qualifier(p.id),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                    if (p.pack != null && p.pack!.isNotEmpty)
                      Text(p.pack!, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
                    if (details != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        details,
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
                  '${qty(p.quantityOnHand)} in stock',
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
  }
}
