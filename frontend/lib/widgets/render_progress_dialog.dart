import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_exception.dart';
import '../core/theme.dart';
import '../models/job.dart';
import '../providers/job_provider.dart';
import 'processing_progress.dart';

class RenderProgressDialog extends ConsumerWidget {
  const RenderProgressDialog({super.key, required this.jobId});

  final String jobId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(jobStatusStreamProvider(jobId));
    ref.listen<AsyncValue<Job>>(jobStatusStreamProvider(jobId), (_, next) {
      final job = next.valueOrNull;
      if (job != null && job.isTerminal) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) Navigator.of(context).pop(job);
        });
      }
    });

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: async.when(
            loading: () => const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Preparing your video'),
                SizedBox(height: AppSpacing.md),
                LinearProgressIndicator(),
              ],
            ),
            error: (error, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.error_outline,
                    color: AppColors.danger, size: 42),
                const SizedBox(height: AppSpacing.sm),
                Text(error is ApiException
                    ? error.message
                    : 'Could not read render progress.'),
                const SizedBox(height: AppSpacing.md),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ],
            ),
            data: (job) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  job.isCompleted
                      ? 'Your video is ready'
                      : 'Rendering your video',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: AppSpacing.md),
                if (job.isFailed || job.isCancelled)
                  Text(job.error ?? 'Video rendering did not complete.')
                else
                  ProcessingProgress(job: job),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
