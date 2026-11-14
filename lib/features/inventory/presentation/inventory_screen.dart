import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/navigation/tab_screen.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/inline_message.dart';
import '../../../core/widgets/floating_header_list.dart';
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

class InventoryScreenState extends State<InventoryScreen> with TabScreen, TabHandoff {
  final _searchController = TextEditingController();
  final _catalog = ProductCatalog.instance;

  /// What is typed. Searched on the phone, against the whole list, as each
  /// letter is typed — no request per search (DAS-94).
  String _query = '';

  /// Only stock expiring within a month, soonest first. Works with the search.
  bool _expiringOnly = false;
  String? _schedule;

  /// Running low or out of stock, one at a time, on top of the search and
  /// the expiring filter (DAS-186).
  StockFilter? _stock;

  /// The Home tab's tile or link: its filter replaces whatever was set here.
  @override
  void handoff(Object payload) {
    if (payload is! InventoryFilter) return;
    _searchController.clear();
    setState(() {
      _query = '';
      _expiringOnly = payload.expiring;
      _stock = payload.stock;
      _schedule = null;
    });
  }

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
    // "4 strips + 5" beside the tablet count in the chip (DAS-160).
    final breakdown = p.loose.packBreakdown(p.quantityOnHand);
    final parts = [
      if (breakdown != null) breakdown,
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
    final matching = index?.match(_query) ?? const <ProductSummary>[];
    final today = DateTime.now();
    final expiring = expiringWithinAMonth(matching, today);
    // DAS-183: one schedule at a time, on top of the search and
    // the expiring filter; a chip only for a schedule the shop has.
    const schedules = ['H1', 'H', 'X'];
    final bySchedule = {for (final s in schedules) s: matching.where((p) => p.schedule == s).length};
    final low = runningLow(matching);
    final out = outOfStock(matching);
    final stockList = switch (_stock) { StockFilter.low => low, StockFilter.out => out, null => null };
    final stockIds = stockList != null && _expiringOnly ? {for (final p in stockList) p.id} : null;
    final base = _expiringOnly
        ? (stockIds != null ? expiring.where((p) => stockIds.contains(p.id)).toList() : expiring)
        : (stockList ?? matching);
    final products = _schedule == null ? base : base.where((p) => p.schedule == _schedule).toList();
    final loading = index == null && _catalog.isLoading;
    final failure = _catalog.lastError;
    // The search and the expiring filter float (FloatingHeaderList).
    final floating = <Widget>[
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
      if (index != null) ...[
        const SizedBox(height: Spacing.s),
        Wrap(
          spacing: Spacing.s,
          runSpacing: Spacing.xs,
          children: [
            FilterChip(
            key: const ValueKey('inventory-expiring'),
            avatar: _expiringOnly ? null : const Icon(Icons.event_busy_outlined, size: 18),
            label: Text('Expiring within a month (${expiring.length})'),
            selected: _expiringOnly,
            onSelected: (on) => setState(() => _expiringOnly = on),
          ),
            FilterChip(
              key: const ValueKey('inventory-low'),
              label: Text('Running low (${low.length})'),
              selected: _stock == StockFilter.low,
              onSelected: (on) => setState(() => _stock = on ? StockFilter.low : null),
            ),
            FilterChip(
              key: const ValueKey('inventory-out'),
              label: Text('Out of stock (${out.length})'),
              selected: _stock == StockFilter.out,
              onSelected: (on) => setState(() => _stock = on ? StockFilter.out : null),
            ),
            for (final s in schedules)
              if (bySchedule[s]! > 0 || _schedule == s)
                FilterChip(
                  key: ValueKey('inventory-schedule-$s'),
                  label: Text('Schedule $s (${bySchedule[s]})'),
                  selected: _schedule == s,
                  onSelected: (on) => setState(() => _schedule = on ? s : null),
                ),
          ],
        ),
      ],
    ];
    final header = <Widget>[
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
              () {
                final parts = [
                  if (_schedule != null) 'SCHEDULE $_schedule',
                  if (_stock == StockFilter.low) 'RUNNING LOW',
                  if (_stock == StockFilter.out) 'OUT OF STOCK',
                  if (_expiringOnly) 'EXPIRING SOONEST FIRST',
                ];
                return parts.isEmpty ? 'CURRENT STOCK' : parts.join(' · ');
              }(),
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
          text: _expiringOnly
              ? (_query.trim().isEmpty ? 'Nothing in stock expires within a month' : 'Nothing that matches expires within a month')
              : _stock == StockFilter.low
                  ? 'Nothing is running low'
                  : _stock == StockFilter.out
                      ? 'Nothing is out of stock'
                      : (_query.trim().isEmpty ? 'No products yet' : 'No medicine matches that'),
        ),
    ];
    return RefreshIndicator(
      onRefresh: refresh,
      // Built as they scroll into view: a short search shows hundreds of
      // products, and only the visible rows are worth building.
      child: FloatingHeaderList(
        floating: floating,
        padding: const EdgeInsets.all(Spacing.l),
        itemCount: header.length + products.length,
        itemBuilder: (context, i) {
          if (i < header.length) return header[i];
          return _ProductRow(products[i - header.length], index!, today);
        },
      ),
    );
  }
}

class _ProductRow extends StatelessWidget {
  final ProductSummary product;
  final ProductIndex index;
  final DateTime today;
  const _ProductRow(this.product, this.index, this.today);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final p = product;
    final outOfStock = p.quantityOnHand <= 0;
    final details = InventoryScreenState._batchDetails(p);
    final warning = expiryWarning(p, today);
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
                    if (p.pack != null && p.pack!.isNotEmpty || p.schedule != null)
                      Row(children: [
                        if (p.schedule != null) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              border: Border.all(color: colors.error),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(p.schedule!,
                                style: TextStyle(color: colors.error, fontSize: 11, fontWeight: FontWeight.w700)),
                          ),
                          const SizedBox(width: Spacing.xs),
                        ],
                        if (p.pack != null && p.pack!.isNotEmpty)
                          Text(p.pack!, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
                      ]),
                    if (details != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        details,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (warning != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        warning,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: colors.onErrorContainer,
                              fontWeight: FontWeight.w600,
                            ),
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
                  // In tablets when sold loose (DAS-160), else packs as before.
                  p.loose.loose && p.loose.unitsOnHand != null
                      ? p.loose.stock(p.quantityOnHand)
                      : '${qty(p.quantityOnHand)} in stock',
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
