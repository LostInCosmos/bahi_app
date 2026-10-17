/// Batch job-status answers (DAS-19): what one held request to
/// `POST /invoices/extract/status` reports per bill. Kept apart from the
/// invoice models — these carry no invoice data, only where a job is.
library;

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

  const JobStatusBrief({
    required this.jobId,
    required this.status,
    required this.attempt,
    required this.maxAttempts,
    this.retryAt,
    this.saved = false,
  });

  bool get isTerminal => status == 'done' || status == 'failed' || status == 'cancelled';
  bool get isRetrying => status == 'retrying';
  bool get isProcessing => status == 'processing';

  /// Nothing more will ever happen to this job — safe to stop asking about
  /// it. A `done` job that is not yet [saved] is terminal but NOT settled:
  /// the server keeps the long-poll open on it rather than answering at
  /// once, exactly as it does for one still in flight (DAS-79).
  bool get isSettled => status != 'done' ? isTerminal : saved;

  factory JobStatusBrief.fromJson(Map<String, dynamic> json) => JobStatusBrief(
        jobId: json['job_id'] as int,
        status: json['status'] as String,
        attempt: json['attempt'] as int? ?? 0,
        maxAttempts: json['max_attempts'] as int? ?? 3,
        retryAt: json['retry_at'] == null ? null : DateTime.parse(json['retry_at'] as String).toUtc(),
        saved: json['saved'] as bool? ?? false,
      );
}

/// What one held request answers with. [changed] false means the server
/// waited and nothing happened — go straight back to waiting.
class JobStatusBatch {
  final List<JobStatusBrief> jobs;
  final bool changed;

  const JobStatusBatch({required this.jobs, required this.changed});

  factory JobStatusBatch.fromJson(Map<String, dynamic> json) => JobStatusBatch(
        jobs: (json['jobs'] as List<dynamic>? ?? [])
            .map((e) => JobStatusBrief.fromJson(e as Map<String, dynamic>))
            .toList(),
        changed: json['changed'] as bool? ?? false,
      );
}
