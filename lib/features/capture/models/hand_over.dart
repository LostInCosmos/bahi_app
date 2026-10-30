/// When a phone's card gives way to the shop's list (DAS-62), and what to do
/// when the list files the bill somewhere else (DAS-151).
///
/// The card holds the folder the bill was added in, or last moved to, on
/// this phone (`BatchItem.folderId`). The server's row holds the folder the
/// server knows. Until DAS-151 an upload carried no folder, so every row
/// started at Home, the card handed over to it anyway, and the bill jumped
/// out of its folder. A card now hands over only to a row in the same folder.
library;

import 'batch_item.dart';
import 'status_filter.dart';
import 'upload_summary.dart';

/// A card whose finished bill the list files somewhere else.
typedef Misfiled = ({BatchItem item, UploadSummary row});

/// What [splitHandOver] found: see there.
typedef HandOver = ({List<BatchItem> handed, List<Misfiled> refile});

/// The cards whose bill [uploads] already shows in the same box and folder
/// ([handed]), and those it shows in the same box but another folder
/// ([refile]: the server is told the card's folder, then the card hands over).
///
/// The card wins a disagreement. It is this phone's latest word: the folder
/// the bill was added in, which an older server or an upload from before the
/// fix never heard of, or a move made while the upload was on its way, which
/// had no job to send yet. A move from another phone in the seconds before
/// the hand-over is the one case it overrides, and it is undone by a choice
/// this phone's user made.
HandOver splitHandOver(Iterable<BatchItem> items, Iterable<UploadSummary> uploads) {
  final byJob = {for (final u in uploads) u.jobId: u};
  final handed = <BatchItem>[];
  final refile = <Misfiled>[];
  for (final item in items) {
    // Corrections the server has not got are only on this card (DAS-153).
    if (!item.isFinishedOnServer || item.correctionUnsent) continue;
    final row = byJob[item.lastJobId ?? item.jobId];
    if (row == null || uploadCategory(row) != categoryOfItem(item)) continue;
    if (row.folderId == item.folderId) {
      handed.add(item);
    } else {
      refile.add((item: item, row: row));
    }
  }
  return (handed: handed, refile: refile);
}
