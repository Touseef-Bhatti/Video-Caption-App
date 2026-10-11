import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_exception.dart';
import '../../core/theme.dart';
import '../../models/job.dart';
import '../../providers/job_provider.dart';
import '../../providers/project_provider.dart';
import '../../widgets/app_button.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/error_message.dart';
import '../../widgets/processing_progress.dart';

class ProcessingScreen extends ConsumerStatefulWidget {
  const ProcessingScreen({super.key, required this.jobId});

  final String jobId;

  @override
  ConsumerState<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends ConsumerState<ProcessingScreen> {
  bool _openingEditor = false;

  void _openEditor(String projectId) {
    if (_openingEditor) return;
    _openingEditor = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.go('/editor/$projectId');
    });
  }

  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Cancel processing?',
      message: 'The video will stop processing. You can upload it again later.',
      confirmLabel: 'Cancel processing',
      destructive: true,
    );
    if (!ok) return;
    try {
      await ref.read(jobActionsProvider).cancelJob(widget.jobId);
    } on ApiException catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(jobStatusStreamProvider(widget.jobId));

    // Keep the dashboard in sync once the job reaches a terminal state.
    ref.listen<AsyncValue<Job>>(jobStatusStreamProvider(widget.jobId), (prev, next) {
      final job = next.valueOrNull;
      if (job != null && job.isTerminal) ref.read(projectListProvider.notifier).refresh();
      if (job?.isCompleted == true && context.mounted) {
        _openEditor(job!.projectId);
      }
    });

    final currentJob = async.valueOrNull;
    if (currentJob?.isCompleted == true) {
      _openEditor(currentJob!.projectId);
      return const SizedBox.shrink();
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Processing'),
        leading: IconButton(icon: const Icon(Icons.close), onPressed: () => context.go('/dashboard')),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: async.when(
              loading: () => const CircularProgressIndicator(),
              error: (e, _) => ErrorMessage(
                message: e is ApiException ? e.message : 'Something went wrong.',
                onRetry: () => ref.invalidate(jobStatusStreamProvider(widget.jobId)),
              ),
              data: (job) => _JobBody(job: job, onCancel: () => _cancel(context, ref)),
            ),
          ),
        ),
      ),
    );
  }
}

class _JobBody extends StatelessWidget {
  const _JobBody({required this.job, required this.onCancel});

  final Job job;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (job.isCompleted) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle, size: 56, color: AppColors.success),
          const SizedBox(height: AppSpacing.md),
          Text('Your captions are ready', style: theme.textTheme.headlineSmall),
          const SizedBox(height: AppSpacing.sm),
          Text('Opening the caption editor…', style: theme.textTheme.bodyMedium),
        ],
      );
    }

    if (job.isFailed || job.isCancelled) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(job.isCancelled ? Icons.cancel_outlined : Icons.error_outline,
              size: 56, color: job.isCancelled ? Colors.grey : AppColors.danger),
          const SizedBox(height: AppSpacing.md),
          Text(job.isCancelled ? 'Processing cancelled' : "We couldn't process this video",
              style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
          if (job.error != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(job.error!, style: theme.textTheme.bodyMedium, textAlign: TextAlign.center),
          ],
          const SizedBox(height: AppSpacing.lg),
          AppButton(label: 'Upload another video', onPressed: () => context.go('/upload'), expand: true),
          const SizedBox(height: AppSpacing.sm),
          AppButton(
              label: 'Back to projects',
              variant: AppButtonVariant.secondary,
              onPressed: () => context.go('/dashboard'),
              expand: true),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Creating your captions', style: theme.textTheme.headlineSmall),
        const SizedBox(height: AppSpacing.xs),
        Text('You can leave this page -- processing continues in the background.', style: theme.textTheme.bodySmall),
        const SizedBox(height: AppSpacing.lg),
        ProcessingProgress(job: job),
        const SizedBox(height: AppSpacing.lg),
        AppButton(label: 'Cancel', variant: AppButtonVariant.secondary, onPressed: onCancel, expand: true),
      ],
    );
  }
}
