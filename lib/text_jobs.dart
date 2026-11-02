enum TextProcessingStatus {
  /// A capture queued for automatic 整理 on this device, not yet sent.
  waiting,
  cancelled,
  sending,
  completed,
  failed,
  review;

  /// Statuses an older version saved for its estimate/confirm jobs read as
  /// [cancelled]; on open they are rewritten (see `_dropOldEstimateJobs`).
  static TextProcessingStatus read(String name) =>
      values.asNameMap()[name] ?? cancelled;
}

class WorkspaceTextJob {
  const WorkspaceTextJob({
    required this.id,
    required this.noteId,
    required this.status,
    this.message = '',
  });

  final String id, noteId, message;
  final TextProcessingStatus status;
}
