import 'package:flutter/widgets.dart';

import 'batch_item.dart';
import 'upload_summary.dart';

/// One card on the Capture list.
///
/// A bill this device holds ([item]) and a bill from the shop's list
/// ([upload]) are drawn in the SAME grid, in the order they were uploaded.
/// They used to be two groups, and a bill jumped between them the moment
/// it was opened. This is what lets the list hold both without caring
/// which a card came from.
class ListEntry {
  /// `l:<…>` for a bill this device holds, `j:<job id>` for one from the
  /// shop's list. Stable for a bill's life, so a card keeps its state.
  final String id;

  /// Where the card sits: its upload order and nothing else. See
  /// [localSortKey].
  final int sortKey;

  final BatchItem? item;
  final UploadSummary? upload;

  /// The card itself. Built by whoever owns the callbacks it needs.
  final Widget card;

  const ListEntry({
    required this.id,
    required this.sortKey,
    required this.card,
    this.item,
    this.upload,
  }) : assert((item == null) != (upload == null), 'an entry is one or the other');

  bool get isLocal => item != null;
}
