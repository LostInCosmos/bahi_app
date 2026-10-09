import 'batch_item.dart';
import 'list_entry.dart';

/// Picking several bills and doing one thing to all of them.
///
/// Pure decisions, kept out of the screen so they can be tested: what a bill
/// may have done to it, and which call does it. Mirrors
/// `shop_webapp/src/features/capture/bulk.js` — same rules, same wording —
/// because the two clients must not drift on what a shopkeeper can do.

/// What the server is still working on. The same set the API refuses to
/// discard, so the screen can say so without a round trip.
const _inFlight = {'pending', 'queued', 'processing', 'retrying'};

/// Bills with no server id yet (waiting to be cropped, still uploading) are
/// the newest there are, so they lead — and among themselves the one added
/// last comes first.
const int kNewest = 1000000000000;

/// Where a card sits in the list: its upload order and nothing else.
///
/// Opening, retrying or moving a bill never changes its id, so it never
/// changes its place — which is the whole meaning of "show in order of
/// upload". Before this, a bill tapped in the shop's list was added to the
/// device's own grid above it, and so jumped to the top.
int localSortKey(BatchItem item, int index) => item.lastJobId ?? item.jobId ?? (kNewest + index);

bool isSavedEntry(ListEntry e) {
  final item = e.item;
  if (item != null) return item.status == BatchItemStatus.saved || item.savedInvoiceId != null;
  return e.upload!.isSaved;
}

/// The server's id for a bill, if it has one.
int? jobIdOf(ListEntry e) {
  final item = e.item;
  if (item != null) return item.jobId ?? item.lastJobId;
  return e.upload!.jobId;
}

enum DiscardRefusal { saved, reading }

/// Whether Discard applies; null means it does.
///
/// Never a saved bill: deleting one puts its stock back, which is a decision
/// about the shop's inventory and not about tidying a screen — so it stays a
/// deliberate, one-at-a-time action on the bill itself. Nor one the server
/// is still reading, which is seconds from being discardable.
DiscardRefusal? whyNotDiscard(ListEntry e) {
  if (isSavedEntry(e)) return DiscardRefusal.saved;
  final item = e.item;
  if (item != null && item.status == BatchItemStatus.processing) return DiscardRefusal.reading;
  final upload = e.upload;
  if (upload != null && _inFlight.contains(upload.status)) return DiscardRefusal.reading;
  return null;
}

class DiscardPlan {
  final List<ListEntry> take;
  final int savedLeft;
  final int readingLeft;

  const DiscardPlan(this.take, this.savedLeft, this.readingLeft);
}

/// Split a selection into what Discard can and cannot take.
DiscardPlan planDiscard(Iterable<ListEntry> entries) {
  final take = <ListEntry>[];
  var saved = 0;
  var reading = 0;
  for (final e in entries) {
    switch (whyNotDiscard(e)) {
      case null:
        take.add(e);
      case DiscardRefusal.saved:
        saved++;
      case DiscardRefusal.reading:
        reading++;
    }
  }
  return DiscardPlan(take, saved, reading);
}

/// The call that files a bill.
///
///   invoice  a saved bill — its folder lives on the invoice
///   job      a read bill not yet saved — its folder lives on the upload
///   local    nothing on the server yet; only this device knows it
enum MoveVia { invoice, job, local }

class MoveStep {
  final MoveVia via;
  final int? id;

  const MoveStep(this.via, [this.id]);
}

MoveStep moveStep(ListEntry e) {
  if (isSavedEntry(e)) {
    final id = e.item != null ? e.item!.savedInvoiceId : e.upload!.invoiceId;
    return id != null ? MoveStep(MoveVia.invoice, id) : const MoveStep(MoveVia.local);
  }
  final job = jobIdOf(e);
  return job != null ? MoveStep(MoveVia.job, job) : const MoveStep(MoveVia.local);
}

class BulkFailure {
  final ListEntry entry;
  final Object error;

  const BulkFailure(this.entry, this.error);
}

class BulkResult {
  final int done;
  final List<BulkFailure> failed;

  const BulkResult(this.done, this.failed);
}

/// Run [fn] over every entry and report, rather than stopping at the first
/// failure: eleven of twelve moves that worked should not be undone by the
/// twelfth, and the shopkeeper needs to know which one did not.
Future<BulkResult> runBulk(Iterable<ListEntry> entries, Future<void> Function(ListEntry) fn) async {
  final failed = <BulkFailure>[];
  var done = 0;
  for (final entry in entries) {
    try {
      await fn(entry);
      done++;
    } catch (error) {
      failed.add(BulkFailure(entry, error));
    }
  }
  return BulkResult(done, failed);
}

/// A sentence for the outcome, in the words a shopkeeper would use.
String summarise(String verb, BulkResult result, {int savedLeft = 0, int readingLeft = 0}) {
  final parts = <String>['$verb ${result.done} bill${result.done == 1 ? '' : 's'}'];
  if (result.failed.isNotEmpty) {
    parts.add("${result.failed.length} couldn't be ${verb.toLowerCase()}");
  }
  if (savedLeft > 0) {
    parts.add('$savedLeft saved bill${savedLeft == 1 ? ' was' : 's were'} left — '
        'delete those one at a time, which puts their stock back');
  }
  if (readingLeft > 0) {
    parts.add('$readingLeft still being read — try again in a moment');
  }
  return '${parts.join('; ')}.';
}

/// What the server says about a batch it was asked to file. Only what was
/// actually moved is listed; anything asked for and absent was skipped
/// (already saved, discarded, not this shop's).
class BulkMoveReply {
  final Set<int> movedJobs;
  final Set<int> movedInvoices;

  const BulkMoveReply({this.movedJobs = const {}, this.movedInvoices = const {}});

  factory BulkMoveReply.fromJson(Map<String, dynamic> json) => BulkMoveReply(
        movedJobs: {for (final id in json['moved_jobs'] as List<dynamic>? ?? const []) (id as num).toInt()},
        movedInvoices: {for (final id in json['moved_invoices'] as List<dynamic>? ?? const []) (id as num).toInt()},
      );
}

/// Bills sent per request. Big enough that 332 bills is four calls, small
/// enough that one slow call does not hold the progress bar for long.
const int kMoveChunk = 100;

/// One request's worth of a move.
class MoveBatch {
  final List<ListEntry> entries;
  final List<int> jobIds;
  final List<int> invoiceIds;

  const MoveBatch(this.entries, this.jobIds, this.invoiceIds);

  /// The entries the server did NOT move, given its [reply] — these must go
  /// back where they were, because the screen has already shown them moved.
  List<ListEntry> refused(BulkMoveReply reply) => [
        for (final e in entries)
          if (!_moved(e, reply)) e,
      ];

  static bool _moved(ListEntry e, BulkMoveReply reply) {
    final step = moveStep(e);
    return switch (step.via) {
      MoveVia.invoice => reply.movedInvoices.contains(step.id),
      MoveVia.job => reply.movedJobs.contains(step.id),
      MoveVia.local => true,
    };
  }
}

class MovePlan {
  /// Bills that exist only on this phone: moving them is a local change.
  final List<ListEntry> local;
  final List<MoveBatch> batches;

  const MovePlan(this.local, this.batches);

  int get total => local.length + batches.fold(0, (n, b) => n + b.entries.length);
}

/// Split a selection into what stays on the phone and the requests that
/// carry the rest, [chunk] bills at a time.
MovePlan planMove(Iterable<ListEntry> entries, {int chunk = kMoveChunk}) {
  final local = <ListEntry>[];
  final remote = <ListEntry>[];
  for (final e in entries) {
    (moveStep(e).via == MoveVia.local ? local : remote).add(e);
  }
  final batches = <MoveBatch>[];
  for (var i = 0; i < remote.length; i += chunk) {
    final part = remote.sublist(i, i + chunk > remote.length ? remote.length : i + chunk);
    final jobs = <int>[];
    final invoices = <int>[];
    for (final e in part) {
      final step = moveStep(e);
      (step.via == MoveVia.invoice ? invoices : jobs).add(step.id!);
    }
    batches.add(MoveBatch(part, jobs, invoices));
  }
  return MovePlan(local, batches);
}
