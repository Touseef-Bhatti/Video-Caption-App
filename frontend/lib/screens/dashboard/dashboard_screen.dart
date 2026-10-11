import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../models/project.dart';
import '../../providers/job_provider.dart';
import '../../providers/project_provider.dart';
import '../../widgets/app_button.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_message.dart';
import '../../widgets/project_card.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  Future<void> _open(BuildContext context, WidgetRef ref, Project p) async {
    if (p.isProcessing) {
      // Resume watching: look up which job is the newest for this project.
      final job = await ref.read(latestJobForProjectProvider(p.id).future);
      if (!context.mounted) return;
      if (job != null) {
        context.go('/processing/${job.id}');
        return;
      }
    }
    if (!context.mounted) return;
    context.go('/editor/${p.id}');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(projectListProvider);
    final notifier = ref.read(projectListProvider.notifier);

    Widget body;
    if (state.isLoading && state.projects.isEmpty) {
      body = const Center(child: CircularProgressIndicator());
    } else if (state.errorMessage != null && state.projects.isEmpty) {
      body = ErrorMessage(message: state.errorMessage!, onRetry: notifier.refresh);
    } else if (state.projects.isEmpty) {
      body = EmptyState(
        icon: Icons.movie_creation_outlined,
        title: 'No projects yet',
        subtitle: 'Upload a video and get captions in minutes.',
        action: AppButton(label: 'Upload a video', icon: Icons.upload, onPressed: () => context.go('/upload')),
      );
    } else {
      body = RefreshIndicator(
        onRefresh: notifier.refresh,
        child: ListView.separated(
          padding: const EdgeInsets.all(AppSpacing.md),
          itemCount: state.projects.length,
          separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
          itemBuilder: (context, i) {
            final p = state.projects[i];
            return ProjectCard(
              project: p,
              onTap: () => _open(context, ref, p),
              onDelete: () async {
                final ok = await showConfirmDialog(
                  context,
                  title: 'Delete project?',
                  message: 'This permanently deletes "${p.name}" and its exports.',
                  confirmLabel: 'Delete',
                  destructive: true,
                );
                if (ok) await notifier.deleteProject(p.id);
              },
            );
          },
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Projects'),
        actions: [
          IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: notifier.refresh),
          const SizedBox(width: AppSpacing.sm),
        ],
      ),
      body: body,
      floatingActionButton: state.projects.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => context.go('/upload'),
              icon: const Icon(Icons.add),
              label: const Text('New project'),
            ),
    );
  }
}
