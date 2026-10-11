import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../models/job.dart';

const _orderedStages = [
  (JobStage.preparing, 'Preparing video'),
  (JobStage.extractingAudio, 'Extracting audio'),
  (JobStage.transcribing, 'Analyzing speech'),
  (JobStage.creatingCaptions, 'Creating captions'),
  (JobStage.rendering, 'Rendering video'),
  (JobStage.finalizing, 'Finalizing'),
];

/// Progress bar plus a step list that ticks off as the job's backend status advances.
class ProcessingProgress extends StatelessWidget {
  const ProcessingProgress({super.key, required this.job});

  final Job job;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentIndex = _orderedStages.indexWhere((s) => s.$1 == job.status);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          child: LinearProgressIndicator(value: job.progress / 100, minHeight: 8),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text('${job.progress}%  ·  ${job.stage}', style: theme.textTheme.bodySmall),
        const SizedBox(height: AppSpacing.lg),
        for (var i = 0; i < _orderedStages.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                _icon(i, currentIndex, job, theme),
                const SizedBox(width: AppSpacing.md),
                Text(
                  _orderedStages[i].$2,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: i == currentIndex ? FontWeight.w600 : FontWeight.w400,
                    color: i > currentIndex && !job.isCompleted ? theme.textTheme.bodySmall?.color : null,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _icon(int i, int currentIndex, Job job, ThemeData theme) {
    if (job.isCompleted || i < currentIndex) {
      return const Icon(Icons.check_circle, size: 20, color: AppColors.success);
    }
    if (i == currentIndex && !job.isTerminal) {
      return const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    return Icon(Icons.radio_button_unchecked, size: 20, color: theme.textTheme.bodySmall?.color);
  }
}
