import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api_exception.dart';
import '../../core/theme.dart';
import '../../providers/export_provider.dart';
import '../../widgets/app_button.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_message.dart';

class ExportScreen extends ConsumerWidget {
  const ExportScreen({super.key, required this.projectId});

  final String projectId;

  Future<void> _download(
      BuildContext context, WidgetRef ref, ExportItem item) async {
    try {
      final url = await fetchExportDownloadUrl(ref, item.id);
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
                      'MP4 (H.264 / AAC). Download links are private and expire after one hour.',
                      style: theme.textTheme.bodySmall),
                  const SizedBox(height: AppSpacing.lg),
                  for (var i = 0; i < list.length; i++)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.movie_outlined),
                        title:
                            Text(i == 0 ? 'Latest version' : 'Earlier version'),
                        subtitle: Text(
                            '${list[i].quality == 'high' ? 'High' : 'Standard'} quality  ·  ${DateFormat.yMMMd().add_jm().format(list[i].createdAt.toLocal())}'),
                        trailing: AppButton(
                          label: 'Download',
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
