import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api_exception.dart';
import '../../core/theme.dart';
import '../../models/job.dart';
import '../../models/export_options.dart';
import '../../providers/core_providers.dart';
import '../../providers/export_provider.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/app_button.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_message.dart';
import '../../widgets/render_progress_dialog.dart';

class ExportScreen extends ConsumerWidget {
  const ExportScreen({super.key, required this.projectId});

  final String projectId;

  String _formatLabel(ExportItem item) {
    if (item.outputResolution == 0 && item.outputFps == 0) {
      return 'Original quality';
    }
    final resolution = switch (item.outputResolution) {
      0 => 'Original size',
      720 => '720 px',
      1024 => '1024 px',
      2048 => '2K',
      3840 => '4K',
      final value => '$value px',
    };
    final fps = item.outputFps == 0 ? 'source fps' : '${item.outputFps} fps';
    return '$resolution · $fps';
  }

  Future<void> _download(
      BuildContext context, WidgetRef ref, ExportItem item) async {
    try {
      const options = ExportOptions();
      if (!context.mounted) return;

      final captionState = await ref
          .read(apiClientProvider)
          .get('/api/projects/$projectId/captions');
      var selected = item;
      var justRendered = false;
      if (captionState['matching_export_id'] != item.id ||
          item.outputResolution != options.resolution ||
          item.outputFps != options.fps) {
        final response = await ref.read(apiClientProvider).post(
          '/api/projects/$projectId/render',
          data: {
            'quality': ref.read(settingsProvider).defaultExportQuality,
            'output_resolution': options.resolution,
            'output_fps': options.fps,
          },
        );
        final jobId = response['job_id'] as String;
        final job = await showDialog<Job>(
          context: context,
          barrierDismissible: false,
          builder: (_) => RenderProgressDialog(jobId: jobId),
        );
        if (!context.mounted) return;
        if (job?.isCompleted != true) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(job?.error ?? 'Video rendering did not complete.'),
          ));
          return;
        }
        ref.invalidate(exportsProvider(projectId));
        final exports = await ref.read(exportsProvider(projectId).future);
        ExportItem? rendered;
        for (final export in exports) {
          if (export.jobId == jobId) {
            rendered = export;
            break;
          }
        }
        if (rendered == null) {
          throw StateError('The completed render has no downloadable export.');
        }
        selected = rendered;
        justRendered = true;
      }

      if (justRendered && context.mounted) {
        final save = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Your video is ready'),
            content: const Text('Save the rendered video to your device.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Close')),
              FilledButton.icon(
                onPressed: () => Navigator.pop(context, true),
                icon: const Icon(Icons.download),
                label: const Text('Save to device'),
              ),
            ],
          ),
        );
        if (save != true || !context.mounted) return;
      }

      final url = await fetchExportDownloadUrl(ref, selected.id);
      final ok = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
        webOnlyWindowName: '_self',
      );
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Couldn't open the download link.")));
      }
    } on ApiException catch (e) {
      if (context.mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not prepare this download.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exports = ref.watch(exportsProvider(projectId));
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Export'),
        leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => context.go('/preview/$projectId')),
      ),
      body: exports.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorMessage(
          message: e is ApiException ? e.message : 'Could not load exports.',
          onRetry: () => ref.invalidate(exportsProvider(projectId)),
        ),
        data: (list) {
          if (list.isEmpty) {
            return EmptyState(
              icon: Icons.download_outlined,
              title: 'Nothing to export yet',
              subtitle: 'Render a captioned video from the editor first.',
              action: AppButton(
                  label: 'Edit captions',
                  onPressed: () => context.go('/editor/$projectId')),
            );
          }
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.lg),
                children: [
                  Text('Your captioned videos',
                      style: theme.textTheme.headlineSmall),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                      'Videos save at the same dimensions and frame rate as the uploaded file, with its original audio.',
                      style: theme.textTheme.bodySmall),
                  const SizedBox(height: AppSpacing.lg),
                  for (var i = 0; i < list.length; i++)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.movie_outlined),
                        title: Text(
                            '${i == 0 ? 'Latest version' : 'Earlier version'} · ${_formatLabel(list[i])}'),
                        subtitle: Text(
                            '${list[i].quality == 'high' ? 'High' : 'Standard'} quality  ·  ${DateFormat.yMMMd().add_jm().format(list[i].createdAt.toLocal())}'),
                        trailing: AppButton(
                          label: 'Save to device',
                          icon: Icons.download,
                          onPressed: () => _download(context, ref, list[i]),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
