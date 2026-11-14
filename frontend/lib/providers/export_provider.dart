import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core_providers.dart';

class ExportItem {
  ExportItem({
    required this.id,
    required this.quality,
    required this.createdAt,
    this.jobId,
    this.outputResolution = 0,
    this.outputFps = 0,
  });

  final String id;
  final String quality;
  final DateTime createdAt;
  final String? jobId;
  final int outputResolution;
  final int outputFps;

  factory ExportItem.fromJson(Map<String, dynamic> j) => ExportItem(
        id: j['id'] as String,
        quality: j['quality'] as String,
        createdAt: DateTime.parse(j['created_at'] as String),
        jobId: j['job_id'] as String?,
        outputResolution: (j['output_resolution'] as num?)?.toInt() ?? 0,
        outputFps: (j['output_fps'] as num?)?.toInt() ?? 0,
      );
}

/// Newest first (the backend orders by created_at desc).
final exportsProvider = FutureProvider.autoDispose.family<List<ExportItem>, String>((ref, projectId) async {
  final raw = await ref.read(apiClientProvider).getList('/api/projects/$projectId/exports');
  return raw.map((e) => ExportItem.fromJson(e as Map<String, dynamic>)).toList();
});

/// A fresh short-lived signed URL each time -- never stored or cached long-term.
Future<String> fetchExportDownloadUrl(WidgetRef ref, String exportId) async {
  final json = await ref.read(apiClientProvider).get('/api/exports/$exportId/download');
  return json['download_url'] as String;
}

final exportDownloadUrlProvider = FutureProvider.autoDispose.family<String, String>((ref, exportId) async {
  final json = await ref.read(apiClientProvider).get('/api/exports/$exportId/download');
  return json['download_url'] as String;
});
