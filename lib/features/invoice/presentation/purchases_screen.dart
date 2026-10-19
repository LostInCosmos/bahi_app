import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/api/api_client.dart';
import '../../../core/navigation/tab_screen.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/share_file.dart';
import '../../../core/utils/snack.dart';
import '../../../core/widgets/busy_button.dart';
import '../../../core/widgets/date_range_buttons.dart';
import '../../../core/widgets/inline_message.dart';
import '../../folders/data/folder_api.dart';
import '../../folders/data/folder_controller.dart';
import '../../folders/models/folder.dart';
import '../../folders/widgets/folder_widgets.dart';
import '../data/invoice_api.dart';
import '../models/invoice.dart';
import '../models/purchase_export.dart';
import '../widgets/export_options.dart';
import 'invoice_detail_screen.dart';

class PurchasesScreen extends StatefulWidget {
  const PurchasesScreen({super.key});

  @override
  State<PurchasesScreen> createState() => PurchasesScreenState();
}

class PurchasesScreenState extends State<PurchasesScreen> with TabScreen {
  DateTime? _startDate;
  DateTime? _endDate;
  final _gstinController = TextEditingController();

  /// The shop's folders and where this tab is in them. With no filter set the
  /// list shows the bills in the current folder; with one set it searches every
  /// folder, since a date or supplier search is about the bill, not where it is.
  final FolderController _folders = FolderController();
  int? _listedFolderId;

  List<InvoiceSummary> _invoices = [];
  bool _loading = false;
  bool _refreshAgain = false;
  bool _exporting = false;
  String? _error;

  // Deliberately no fetch here — HomeScreen builds every tab up front (via
  // IndexedStack, so switching tabs is instant and preserves scroll/filter
  // state), but that means an unconditional fetch in initState would fire
  // for every tab the moment the app opens, not just the one actually being
  // looked at. HomeScreen's tab switcher calls refresh() the first (and
  // every) time this tab is actually selected instead.

  @override
  void initState() {
    super.initState();
    _folders.addListener(_onFoldersChanged);
  }

  @override
  void dispose() {
    _folders.removeListener(_onFoldersChanged);
    _folders.dispose();
    _gstinController.dispose();
    super.dispose();
  }

  bool get _searching => _startDate != null || _endDate != null || _gstinController.text.trim().isNotEmpty;

  void _onFoldersChanged() {
    if (!mounted) return;
    setState(() {});
    // Stepping into another folder shows that folder's bills.
    if (_folders.currentId != _listedFolderId) refresh();
  }

  /// Called by HomeScreen when this tab is selected — IndexedStack keeps this
  /// widget's state alive across tab switches, so it won't otherwise notice
  /// invoices saved while a different tab was active.
  @override
  Future<void> refresh() async {
    // A refresh asked for mid-load (stepping into a folder, a move) is run
    // again afterwards rather than dropped, so the list never shows a folder
    // other than the one you are in.
    if (_loading) {
      _refreshAgain = true;
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    // Recorded up front: loading the tree notifies listeners, and a folder
    // that differs from this one is what means "navigated, load again".
    _listedFolderId = _folders.currentId;
    try {
      // The folder tree and the bills load together; a failed tree load keeps
      // the last good tree and shows the bills regardless.
      final results = await Future.wait([
        _folders.load(),
        ApiClient.instance.listInvoices(
          startDate: isoDate(_startDate),
          endDate: isoDate(_endDate),
          vendorGstin: _gstinController.text.trim(),
          // Searching looks in every folder; otherwise just this one.
          folderId: _searching ? null : _folders.currentId,
          unfiled: !_searching && _folders.currentId == null,
        ),
      ]);
      if (!mounted) return;
      setState(() => _invoices = results[1] as List<InvoiceSummary>);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load purchases: $e');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        if (_refreshAgain) {
          _refreshAgain = false;
          refresh();
        }
      }
    }
  }

  Future<void> _moveInvoice(InvoiceSummary inv) async {
    final choice = await showFolderPicker(
      context,
      tree: _folders.tree,
      title: 'Move this bill to…',
      currentId: inv.folderId,
    );
    if (choice == null || choice.folderId == inv.folderId || !mounted) return;
    try {
      await ApiClient.instance.moveInvoice(inv.id, folderId: choice.folderId);
    } catch (e) {
      if (mounted) context.say("Couldn't move it: $e");
      return;
    }
    refresh();
  }

  /// The main Export button: offers the files that can be made from the bills
  /// uploaded in the range picked above (all of them with no range).
  Future<void> _openExport() => showExportOptions(
        context,
        heading: exportRangeLabel(start: isoDate(_startDate), end: isoDate(_endDate), vendorGstin: _gstinController.text),
        options: [
          ExportOption(
            title: 'GSTR2 purchase register',
            subtitle: 'Excel file of the saved bills in this range',
            run: _exportRange,
          ),
        ],
      );

  /// The GSTR2 file for the range above.
  Future<void> _exportRange() async {
    if (_exporting) return;
    setState(() {
      _exporting = true;
      _error = null;
    });
    try {
      final export = await ApiClient.instance.exportExcel(
        startDate: isoDate(_startDate),
        endDate: isoDate(_endDate),
        vendorGstin: _gstinController.text.trim(),
      );
      if (!mounted) return;
      if (export.billCount == 0) {
        setState(() => _error = excludedNote(export.excludedUnderReview) ?? 'No bills in this range.');
        return;
      }
      await shareBytes(context, export.bytes,
          name: 'purchases_${DateTime.now().millisecondsSinceEpoch}.xlsx', text: 'GST purchase export');
      final left = excludedNote(export.excludedUnderReview);
      if (left != null && mounted) context.say(left);
    } catch (e) {
      if (mounted) setState(() => _error = 'Export failed: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// The folder menu's Export: offers the files that can be made from the
  /// bills filed directly in [folder].
  Future<void> _openFolderExport(Folder folder) => showExportOptions(
        context,
        heading: 'Export "${folder.name}"',
        options: [
          ExportOption(
            title: 'GSTR2 purchase register',
            subtitle: 'Excel file of every saved bill in this folder',
            run: () => _exportFolder(folder),
          ),
        ],
      );

  /// The GSTR2 file for [folder]. Sends nothing but the folder, so the range
  /// is the bills' own.
  Future<void> _exportFolder(Folder folder) async {
    if (_exporting) return;
    setState(() {
      _exporting = true;
      _error = null;
    });
    try {
      final export = await ApiClient.instance.exportExcel(folderId: folder.id);
      if (!mounted) return;
      if (export.billCount == 0) {
        context.say(excludedNote(export.excludedUnderReview) ?? 'No bills in this folder.');
        return;
      }
      await shareBytes(
        context,
        export.bytes,
        name: 'purchases_folder${folder.id}_${DateTime.now().millisecondsSinceEpoch}.xlsx',
        text: 'GST purchase export — ${folder.name}',
      );
      final n = export.billCount;
      final left = excludedNote(export.excludedUnderReview);
      if (n != null && mounted) context.say('Exported ${plural(n, 'bill')}.${left == null ? '' : ' $left'}');
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 404) {
        // Deleted on another device since this tree loaded.
        context.say('That folder no longer exists.');
        refresh();
      } else {
        context.say(e.message);
      }
    } catch (e) {
      if (mounted) context.say('Export failed: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final header = <Widget>[
      DateRangeButtons(
        start: _startDate,
        end: _endDate,
        startLabel: 'Uploaded from',
        endLabel: 'Uploaded to',
        onChanged: (start, end) => setState(() {
          _startDate = start;
          _endDate = end;
        }),
      ),
      const SizedBox(height: Spacing.s),
      TextField(
        controller: _gstinController,
        decoration: const InputDecoration(labelText: 'Vendor GSTIN (optional)', prefixIcon: Icon(Icons.search)),
      ),
      const SizedBox(height: Spacing.m),
      Row(
        children: [
          Expanded(child: BusyOutlinedButton(busy: _loading, onPressed: refresh, label: 'Refresh')),
          const SizedBox(width: Spacing.s),
          Expanded(
            child: BusyFilledButton(busy: _exporting, onPressed: _openExport, label: 'Export', icon: Icons.ios_share),
          ),
        ],
      ),
      ErrorText(_error),
      const SizedBox(height: Spacing.m),
      if (_searching)
        Padding(
          padding: const EdgeInsets.only(bottom: Spacing.s),
          child: Row(children: [
            Icon(Icons.search, size: 16, color: colors.onSurfaceVariant),
            const SizedBox(width: Spacing.xs),
            Text('Searching all folders', style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12)),
          ]),
        )
      else ...[
        // Negative padding cancels the ListView's own, so the breadcrumb
        // sits flush like it does on New bills.
        Transform.translate(
          offset: const Offset(-Spacing.s, 0),
          child: FolderBar(controller: _folders, onNewFolder: () => showNewFolderDialog(context, _folders)),
        ),
        if (_folders.children.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: Spacing.m, top: Spacing.xs),
            child: folderTileGridBox(
              folders: _folders.children,
              onOpen: (f) => _folders.open(f.id),
              onMenu: (f) =>
                  showFolderActions(context, _folders, f, onDeleted: (_, __) => refresh(), onExport: _openFolderExport),
            ),
          ),
      ],
      if (_invoices.isEmpty && !_loading)
        EmptyHint(
          icon: Icons.inbox_outlined,
          padding: const EdgeInsets.only(top: Spacing.xl),
          text: _searching
              ? 'No bills match'
              : _folders.atHome
                  ? (_folders.children.isEmpty ? 'No purchases yet' : 'No bills here — open a folder')
                  : 'No bills in this folder',
        ),
    ];
    return RefreshIndicator(
      onRefresh: refresh,
      // Built as they scroll into view: a shop's purchases run to hundreds.
      child: ListView.builder(
        padding: const EdgeInsets.all(Spacing.l),
        itemCount: header.length + _invoices.length,
        itemBuilder: (context, i) {
          if (i < header.length) return header[i];
          final inv = _invoices[i - header.length];
          return _InvoiceRow(
            inv,
            onOpen: () async {
              HapticFeedback.selectionClick();
              final deleted = await Navigator.of(context).push<bool>(
                MaterialPageRoute(builder: (_) => InvoiceDetailScreen(invoiceId: inv.id)),
              );
              if (deleted == true) refresh();
            },
            onMove: () => _moveInvoice(inv),
          );
        },
      ),
    );
  }
}

class _InvoiceRow extends StatelessWidget {
  final InvoiceSummary inv;
  final VoidCallback onOpen;
  final VoidCallback onMove;
  const _InvoiceRow(this.inv, {required this.onOpen, required this.onMove});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.s),
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.card),
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.all(Spacing.m),
            child: Row(children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: colors.primaryContainer,
                child: Text(
                  inv.vendorName.isNotEmpty ? inv.vendorName[0].toUpperCase() : '?',
                  style: TextStyle(color: colors.onPrimaryContainer, fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: Spacing.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${inv.vendorName} — ${inv.invoiceNo}',
                        style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(
                      '${inv.invoiceDate} • ${inv.extractionMethod}${inv.reviewed ? '' : ' • not reviewed'}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Spacing.s),
              Text(rupees(inv.grandTotal), style: amountTextStyle(context)),
              SizedBox(
                width: 36,
                child: PopupMenuButton<String>(
                  tooltip: 'Bill options',
                  padding: EdgeInsets.zero,
                  icon: Icon(Icons.more_vert_rounded, size: 20, color: colors.onSurfaceVariant),
                  onSelected: (_) => onMove(),
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'move', child: Text('Move to folder…')),
                  ],
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
