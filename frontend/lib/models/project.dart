class Project {
  Project({
    required this.id,
    required this.name,
    required this.status,
    required this.durationSeconds,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String status;
  final double? durationSeconds;
  final DateTime createdAt;

  factory Project.fromJson(Map<String, dynamic> json) => Project(
        id: json['id'] as String,
        name: json['name'] as String,
        status: json['status'] as String,
        durationSeconds: (json['duration_seconds'] as num?)?.toDouble(),
        createdAt: DateTime.parse(json['created_at'] as String),
      );

  bool get isProcessing => status == 'processing' || status == 'queued';
  bool get isCompleted => status == 'completed';
  bool get isFailed => status == 'failed';
}
