/// Batch job-status answers (DAS-19): what one held request to
/// `POST /invoices/extract/status` reports per bill. Kept apart from the
/// invoice models — these carry no invoice data, only where a job is.
library;

import '../../../core/utils/json.dart';

/// One bill's state in a batch status answer. Deliberately without a result:
/// learning a bill is done is cheap and happens often, fetching its result
/// happens once. See ApiClient.jobStatuses.
class JobStatusBrief {
  final int jobId;
  final String status;
  final int attempt;
  final int maxAttempts;
  final DateTime? retryAt;
  /// Whether the bill has been saved — a `done` job can sit unsaved for a
  /// long time (a clean bill whose own save attempt failed, or one still
  /// flagged), so this is what actually changes for it later, not [status]
  /// (DAS-79).
  final bool saved;

  /// For a `done` job (DAS-105): where our team's review stands
  /// (`none|pending|done`) and how many fields the shop still has to fix
  /// (the GSTIN excluded, as everywhere). Null while in flight, and on a
  /// server older than the fields — then the single-job fetch is the only
  /// way to know, as before.
  final String? reviewState;
  final int? flagCount;

  const JobStatusBrief({
    required this.jobId,
    required this.status,
    required this.attempt,
    required this.maxAttempts,
    this.retryAt,
    this.saved = false,
    this.reviewState,
    this.flagCount,
  });

  bool get isTerminal => status == 'done' || status == 'failed' || status == 'cancelled';
  bool get isRetrying => status == 'retrying';
  bool get isProcessing => status == 'processing';

  /// Nothing more will ever happen to this job — safe to stop asking about
  /// it. A `done` job that is not yet [saved] is terminal but NOT settled:
  /// the server keeps the long-poll open on it rather than answering at
  /// once, exactly as it does for one still in flight (DAS-79).
  bool get isSettled => status != 'done' ? isTerminal : saved;

  /// This answer as the string the server compares with the phone's `seen`
  /// (DAS-132). Mirrors the backend's `status_seen.card_state`, the
  /// contract agreed on the ticket.
  String get cardState => switch (status) {
        'retrying' => 'retrying:$attempt',
        'done' => saved ? 'done:saved' : 'done:unsaved:${flagCount ?? 0}',
        _ => status,
      };

  factory JobStatusBrief.fromJson(Map<String, dynamic> json) => JobStatusBrief(
        jobId: json.intReq('job_id'),
        status: json.strReq('status'),
        attempt: json.intOr('attempt', 0),
        maxAttempts: json.intOr('max_attempts', 3),
        retryAt: json.utc('retry_at'),
        saved: json.boolOr('saved'),
        reviewState: json.str('review_state'),
        flagCount: json.integer('flag_count'),
      );
}

/// What one held request answers with. [changed] false means the server
/// waited and nothing happened — go straight back to waiting.
class JobStatusBatch {
  final List<JobStatusBrief> jobs;
  final bool changed;

  const JobStatusBatch({required this.jobs, required this.changed});

  factory JobStatusBatch.fromJson(Map<String, dynamic> json) => JobStatusBatch(
        jobs: json.listOf('jobs', JobStatusBrief.fromJson),
        changed: json.boolOr('changed'),
      );
}
