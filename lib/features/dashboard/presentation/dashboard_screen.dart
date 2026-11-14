import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/api/api_client.dart';
import '../../../core/navigation/tab_screen.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/inline_message.dart';
import '../../auth/data/auth_api.dart';
import '../../home/presentation/home_tabs.dart';
import '../../inventory/data/product_catalog.dart';
import '../../inventory/models/product_search.dart';
import '../../inventory/presentation/product_detail_screen.dart';
import '../../invoice/data/invoice_api.dart';
import '../../invoice/models/invoice.dart';
import '../../sales/data/sale_api.dart';
import '../../sales/models/sale.dart';
import '../../sales/presentation/sale_receipt_screen.dart';
import '../../sales/presentation/sales_history_screen.dart';
import '../models/dashboard_stats.dart';

/// The Home tab (DAS-186): what the shop did today and what needs attention,
/// worked out on the phone from the lists the other tabs fetch (see
/// models/dashboard_stats.dart, ported from the web's Dashboard so the two
/// agree). Per open: this month's sales (one window that also covers the
/// 14-day chart), the product list shared with Inventory and Sell (usually a
/// 304) and this month's purchase bills, in parallel. Only the figures are
/// kept, never the raw lists. Nothing is written; every row opens the screen
/// the other tabs use.
class DashboardScreen extends StatefulWidget {
  final HomeTabHost host;
  const DashboardScreen({super.key, required this.host});

  @override
  State<DashboardScreen> createState() => DashboardScreenState();
}

class _Figures {
  final DateTime today;
  final SalesSummary summary;
  final List<TrendDay> trend;
  final StockWatch watch;
  final PurchasesSummary purchases;
  final List<SaleSummary> recent;
  const _Figures(this.today, this.summary, this.trend, this.watch, this.purchases, this.recent);
}

const _recentBills = 5;
const _attentionRows = 6;

// The shop's name, fetched once per sign-in.
String? _shopNameFor;
String? _shopName;

const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const _months = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// "Saturday, 14 November"
String _longDate(DateTime d) => '${_weekdays[d.weekday - 1]}, ${d.day} ${_months[d.month - 1]}';

String _expiryText(int days) => days <= 0 ? 'expires today' : days == 1 ? 'expires tomorrow' : 'expires in $days days';

String _packs(double n) => n == n.roundToDouble() ? plural(n.round(), 'pack') : '${wholeOrFixed2(n)} packs';

class DashboardScreenState extends State<DashboardScreen> with TabScreen {
  _Figures? _data;
  String? _name = _shopName;
  bool _loading = false;
  String? _error;

  @override
  Future<void> refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final today = DateTime.now();
    final from = salesWindowStart(today);
    final to = isoDate(today)!;
    final catalog = ProductCatalog.instance;
    try {
      final lists = await Future.wait<Object?>([
        ApiClient.instance.listSales(startDate: from, endDate: to),
        ApiClient.instance.listInvoices(startDate: from, endDate: to),
        catalog.refresh(),
        _loadShopName(),
      ]);
      final failure = catalog.lastError;
      if (failure != null && catalog.index == null) throw failure;
      final sales = lists[0] as List<SaleSummary>;
      final products = catalog.index?.products ?? const [];
      if (!mounted) return;
      setState(() => _data = _Figures(
            today,
            salesSummary(sales, today),
            salesTrend(sales, today),
            stockWatch(products, today),
            purchasesSummary(lists[1] as List<InvoiceSummary>, today),
            sales.take(_recentBills).toList(),
          ));
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load the dashboard: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadShopName() async {
    final token = ApiClient.instance.token;
    if (_shopNameFor != token || _shopName == null) {
      try {
        final account = await ApiClient.instance.getAccount();
        _shopNameFor = token;
        _shopName = account.tenantName;
      } catch (_) {
        // The name is a nicety: the figures show without it.
      }
    }
    if (mounted && _name != _shopName) setState(() => _name = _shopName);
  }

  void _openInventory([InventoryFilter? filter]) => widget.host.select('inventory', payload: filter);

  void _openSales() => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SalesHistoryPage()));

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final sections = <Widget>[
      _Header(
        date: _longDate(data?.today ?? DateTime.now()),
        name: _name,
        onStartBilling: () => widget.host.select('sell'),
        onViewSales: _openSales,
      ),
      const SizedBox(height: Spacing.l),
      if (data == null && _error != null) LoadFailed(_error!, onRetry: refresh),
      if (data == null && _error == null)
        const Padding(
          padding: EdgeInsets.only(top: Spacing.xxl),
          child: Column(children: [
            CircularProgressIndicator(),
            SizedBox(height: Spacing.m),
            Text('Adding up today…'),
          ]),
        ),
      if (data != null) ...[
        if (_error != null) ...[
          ErrorText(_error!, padding: EdgeInsets.zero),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: refresh, child: const Text('Try again')),
          ),
        ],
        _Hero(data: data),
        const SizedBox(height: Spacing.m),
        _Tiles(watch: data.watch, purchases: data.purchases, onInventory: _openInventory, host: widget.host),
        const SizedBox(height: Spacing.m),
        _Attention(watch: data.watch, today: data.today, onInventory: _openInventory),
        const SizedBox(height: Spacing.m),
        _Recent(sales: data.recent, monthCount: data.summary.monthCount, onAll: _openSales),
      ],
    ];
    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView.builder(
        padding: const EdgeInsets.all(Spacing.l),
        itemCount: sections.length,
        itemBuilder: (context, i) => sections[i],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String date;
  final String? name;
  final VoidCallback onStartBilling;
  final VoidCallback onViewSales;
  const _Header({required this.date, required this.name, required this.onStartBilling, required this.onViewSales});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(date, style: TextStyle(color: colors.onSurfaceVariant)),
        Text(name ?? 'Your shop', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: Spacing.m),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              key: const ValueKey('home-start-billing'),
              onPressed: onStartBilling,
              icon: const Icon(Icons.shopping_cart_outlined),
              label: const Text('Start billing'),
            ),
          ),
          const SizedBox(width: Spacing.s),
          Expanded(
            child: OutlinedButton.icon(
              key: const ValueKey('home-view-sales'),
              onPressed: onViewSales,
              icon: const Icon(Icons.receipt_outlined),
              label: const Text('View sales'),
            ),
          ),
        ]),
      ],
    );
  }
}

class _Hero extends StatelessWidget {
  final _Figures data;
  const _Hero({required this.data});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final s = data.summary;
    Widget fact(String label, String value) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: TextStyle(fontSize: 12, color: colors.onPrimaryContainer.withValues(alpha: 0.8))),
            Text(value, style: TextStyle(fontWeight: FontWeight.w700, color: colors.onPrimaryContainer)),
          ]),
        );
    return Card(
      color: colors.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(Spacing.l),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text("Today's sales", style: TextStyle(color: colors.onPrimaryContainer.withValues(alpha: 0.8))),
          Text(
            rupeesWhole(s.todayTotal),
            key: const ValueKey('home-today-total'),
            style: Theme.of(context).textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: colors.onPrimaryContainer,
                ),
          ),
          const SizedBox(height: Spacing.s),
          Row(children: [
            fact('Bills', '${s.todayCount}'),
            fact('Average bill', s.averageBill == null ? '—' : rupeesWhole(s.averageBill!)),
            fact('This month', rupeesWhole(s.monthTotal)),
          ]),
          const SizedBox(height: Spacing.l),
          _Trend(days: data.trend),
        ]),
      ),
    );
  }
}

class _Trend extends StatelessWidget {
  final List<TrendDay> days;
  const _Trend({required this.days});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final max = days.fold<double>(0, (m, d) => d.total > m ? d.total : m);
    const height = 56.0;
    final first = DateTime.parse(days.first.date);
    return Semantics(
      label: 'Sales over the last ${days.length} days',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Sales, last ${days.length} days',
            style: TextStyle(fontSize: 12, color: colors.onPrimaryContainer.withValues(alpha: 0.8))),
        const SizedBox(height: Spacing.xs),
        SizedBox(
          height: height,
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            for (final d in days)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1.5),
                  child: Tooltip(
                    message: '${shortDate(DateTime.parse(d.date))}: ${rupees(d.total)}',
                    child: Container(
                      height: max > 0 ? (d.total / max * height).clamp(3.0, height) : 3,
                      decoration: BoxDecoration(
                        color: d.isToday ? colors.primary : colors.onPrimaryContainer.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ),
              ),
          ]),
        ),
        const SizedBox(height: Spacing.xs),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(shortDate(first).substring(0, 6),
              style: TextStyle(fontSize: 11, color: colors.onPrimaryContainer.withValues(alpha: 0.8))),
          Text('Today', style: TextStyle(fontSize: 11, color: colors.onPrimaryContainer.withValues(alpha: 0.8))),
        ]),
      ]),
    );
  }
}

class _Tiles extends StatelessWidget {
  final StockWatch watch;
  final PurchasesSummary purchases;
  final void Function([InventoryFilter? filter]) onInventory;
  final HomeTabHost host;
  const _Tiles({required this.watch, required this.purchases, required this.onInventory, required this.host});

  @override
  Widget build(BuildContext context) {
    final tiles = [
      _Tile(
        key: const ValueKey('home-tile-expiring'),
        icon: Icons.event_busy_outlined,
        title: 'Expiring within a month',
        value: '${watch.expiringSoon}',
        sub: watch.expired > 0
            ? '${plural(watch.expired, 'medicine')} already expired'
            : '${watch.expiringLater} more within $kExpiringLaterDays days',
        onTap: () => onInventory(const InventoryFilter(expiring: true)),
      ),
      _Tile(
        key: const ValueKey('home-tile-low'),
        icon: Icons.inventory_2_outlined,
        title: 'Running low',
        value: '${watch.lowStock}',
        sub: '${watch.outOfStock} out of stock · ${plural(watch.products, 'medicine')}',
        onTap: () => onInventory(const InventoryFilter(stock: StockFilter.low)),
      ),
      _Tile(
        key: const ValueKey('home-tile-purchases'),
        icon: Icons.receipt_long_outlined,
        title: 'Purchases this month',
        value: rupeesWhole(purchases.total),
        sub: plural(purchases.count, 'bill'),
        onTap: () => host.select('purchases'),
      ),
      _Tile(
        key: const ValueKey('home-tile-value'),
        icon: Icons.currency_rupee,
        title: 'Stock value at cost',
        value: watch.stockValue == null ? '—' : rupeesWhole(watch.stockValue!),
        sub: watch.stockValue == null
            ? 'Add a purchase bill to see it'
            : 'Approx., ${plural(watch.valuedProducts, 'medicine')} with a purchase rate',
        onTap: () => onInventory(),
      ),
    ];
    return Column(children: [
      for (var i = 0; i < tiles.length; i += 2) ...[
        if (i > 0) const SizedBox(height: Spacing.s),
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: tiles[i]),
            const SizedBox(width: Spacing.s),
            Expanded(child: tiles[i + 1]),
          ]),
        ),
      ],
    ]);
  }
}

class _Tile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final String sub;
  final VoidCallback onTap;
  const _Tile({super.key, required this.icon, required this.title, required this.value, required this.sub, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Padding(
          padding: const EdgeInsets.all(Spacing.m),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(title, style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant))),
              Icon(icon, size: 18, color: colors.primary),
            ]),
            const SizedBox(height: Spacing.xs),
            Text(value, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            Text(sub, style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
          ]),
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback onAll;
  final List<Widget> children;
  final Key? allKey;
  const _Panel({required this.title, required this.subtitle, required this.onAll, required this.children, this.allKey});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Spacing.m, Spacing.s, Spacing.s, Spacing.s),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                Text(subtitle, style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
              ]),
            ),
            TextButton(key: allKey, onPressed: onAll, child: const Text('All')),
          ]),
          ...children,
        ]),
      ),
    );
  }
}

class _Attention extends StatelessWidget {
  final StockWatch watch;
  final DateTime today;
  final void Function([InventoryFilter? filter]) onInventory;
  const _Attention({required this.watch, required this.today, required this.onInventory});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Color dot(AttentionWhy why) => switch (why) {
          AttentionWhy.expired => colors.error,
          AttentionWhy.expiring => Colors.orange,
          AttentionWhy.low => Colors.amber,
          AttentionWhy.out => colors.outline,
        };
    String line(AttentionRow a) => switch (a.why) {
          AttentionWhy.expired => 'Expired ${plural(-a.days!, 'day')} ago · ${_packs(a.product.quantityOnHand)}',
          AttentionWhy.expiring => '${_expiryText(a.days!)} · ${_packs(a.product.quantityOnHand)}',
          AttentionWhy.low => 'Only ${_packs(a.product.quantityOnHand)} left',
          AttentionWhy.out => 'Out of stock',
        };
    return _Panel(
      title: 'Needs attention',
      subtitle: 'Sell or reorder these first',
      onAll: () => onInventory(),
      children: [
        if (watch.attention.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Spacing.m),
            child: Text('Nothing expired or expiring in $kExpiringLaterDays days, and nothing running low.',
                style: TextStyle(color: colors.onSurfaceVariant)),
          ),
        for (final a in watch.attention.take(_attentionRows))
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Container(width: 10, height: 10, decoration: BoxDecoration(color: dot(a.why), shape: BoxShape.circle)),
            minLeadingWidth: 10,
            title: Text(a.product.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(line(a)),
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => ProductDetailScreen(productId: a.product.id))),
          ),
        const Divider(height: Spacing.m),
        Wrap(spacing: Spacing.xs, children: [
          TextButton(
            key: const ValueKey('home-link-expiring'),
            onPressed: () => onInventory(const InventoryFilter(expiring: true)),
            child: Text('Expiring · ${watch.expiringSoon}'),
          ),
          TextButton(
            key: const ValueKey('home-link-low'),
            onPressed: () => onInventory(const InventoryFilter(stock: StockFilter.low)),
            child: Text('Running low · ${watch.lowStock}'),
          ),
          TextButton(
            key: const ValueKey('home-link-out'),
            onPressed: () => onInventory(const InventoryFilter(stock: StockFilter.out)),
            child: Text('Out of stock · ${watch.outOfStock}'),
          ),
        ]),
      ],
    );
  }
}

class _Recent extends StatelessWidget {
  final List<SaleSummary> sales;
  final int monthCount;
  final VoidCallback onAll;
  const _Recent({required this.sales, required this.monthCount, required this.onAll});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _Panel(
      title: 'Recent bills',
      subtitle: '${plural(monthCount, 'sale')} this month',
      onAll: onAll,
      allKey: const ValueKey('home-recent-all'),
      children: [
        if (sales.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Spacing.m),
            child: Text('No sales yet. Start billing to see them here.', style: TextStyle(color: colors.onSurfaceVariant)),
          ),
        for (final s in sales)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(Icons.receipt_outlined, color: colors.primary),
            title: Text(s.buyerName?.isNotEmpty == true ? s.buyerName! : 'Walk-in customer'),
            subtitle: Text('${s.saleNo} · ${shortDate(DateTime.parse(s.saleDate))}'),
            trailing: Text(rupees(s.grandTotal), style: amountTextStyle(context)),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => SaleReceiptScreen(saleId: s.id, primaryActionLabel: 'Close')),
            ),
          ),
      ],
    );
  }
}
