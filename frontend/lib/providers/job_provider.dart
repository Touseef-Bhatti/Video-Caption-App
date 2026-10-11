import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_exception.dart';
import '../models/job.dart';
import 'core_providers.dart';

/// Looks up the most recently created job for a project -- this is the fix
/// for the dashboard gap where a project id alone didn't tell the client
/// which job to poll: GET /api/projects/{id}/jobs/latest always returns
/// the newest job (original processing or any later re-render), or null
/// if the project has no jobs yet.
final latestJobForProjectProvider = FutureProvider.family<Job?, String>((ref, projectId) async {
  try {
    final json = await ref.read(apiClientProvider).get('/api/projects/$projectId/jobs/latest');
    return Job.fromJson(json);
  } on ApiException catch (e) {
    if (e.statusCode == 404) return null;
    rethrow;
  }
});

/// Polls GET /api/jobs/{id} every 2 seconds and stops once the job reaches
/// a terminal state (completed/failed/cancelled) -- used by the processing
/// screen and the dashboard's "resume watching" card.
final jobStatusStreamProvider = StreamProvider.family<Job, String>((ref, jobId) {
  final controller = StreamController<Job>();
  Timer? timer;

  Future<void> poll() async {
    try {
      final json = await ref.read(apiClientProvider).get('/api/jobs/$jobId');
      final job = Job.fromJson(json);
      if (!controller.isClosed) controller.add(job);
      if (job.isTerminal) {
        timer?.cancel();
        await controller.close();
      }
    } on ApiException catch (e) {
      if (!controller.isClosed) controller.addError(e);
    }
  }

  poll(); // fire immediately, then every 2s
  timer = Timer.periodic(const Duration(seconds: 2), (_) => poll());

  ref.onDispose(() {
    timer?.cancel();
    if (!controller.isClosed) controller.close();
  });

  return controller.stream;
});

final jobActionsProvider = Provider<JobActions>((ref) => JobActions(ref));

class JobActions {
  JobActions(this._ref);
  final Ref _ref;

  Future<void> cancelJob(String jobId) async {
    await _ref.read(apiClientProvider).post('/api/jobs/$jobId/cancel');
  }
}
