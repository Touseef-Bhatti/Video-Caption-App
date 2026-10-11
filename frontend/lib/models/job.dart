/// Mirrors backend JobStatus (11 states) -- kept as plain strings rather
/// than a Dart enum so an unrecognized future status from the server never
/// crashes JSON parsing; screens fall back to treating anything not in
/// [terminalStates] as "in progress".
class JobStage {
  JobStage._();
  static const queued = 'queued';
  static const uploading = 'uploading';
  static const preparing = 'preparing';
  static const extractingAudio = 'extracting_audio';
  static const transcribing = 'transcribing';
  static const creatingCaptions = 'creating_captions';
  static const rendering = 'rendering';
  static const finalizing = 'finalizing';
  static const completed = 'completed';
  static const failed = 'failed';
  static const cancelled = 'cancelled';

  static const terminalStates = {completed, failed, cancelled};
}

class Job {
  Job({
    required this.id,
    required this.projectId,
    required this.status,
    required this.stage,
    required this.progress,
    required this.createdAt,
    this.error,
  });

  final String id;
  final String projectId;
  final String status;
  final String stage;
  final int progress;
  final String? error;
  final DateTime createdAt;

  bool get isTerminal => JobStage.terminalStates.contains(status);
  bool get isFailed => status == JobStage.failed;
  bool get isCancelled => status == JobStage.cancelled;
  bool get isCompleted => status == JobStage.completed;

  factory Job.fromJson(Map<String, dynamic> json) => Job(
        id: json['id'] as String,
        projectId: json['project_id'] as String,
        status: json['status'] as String,
        stage: json['stage'] as String,
        progress: (json['progress'] as num).toInt(),
        error: json['error'] as String?,
        createdAt: DateTime.parse(json['created_at'] as String),
      );
}
