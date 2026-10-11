import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';

import '../../core/api_exception.dart';
import '../../core/theme.dart';
import '../../providers/export_provider.dart';
import '../../providers/project_provider.dart';
import '../../widgets/app_button.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_message.dart';

/// Before/after: the original upload next to the latest captioned export.
class PreviewScreen extends ConsumerWidget {
  const PreviewScreen({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final original = ref.watch(videoPreviewUrlProvider(projectId));
    final exports = ref.watch(exportsProvider(projectId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Preview'),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => context.go('/dashboard')),
        actions: [
          AppButton(
            label: 'Edit captions',
            variant: AppButtonVariant.text,
            onPressed: () => context.go('/editor/$projectId'),
          ),
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.md),
            child: AppButton(label: 'Export', onPressed: () => context.go('/export/$projectId')),
          ),
        ],
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
              icon: Icons.movie_outlined,
              title: 'No captioned video yet',
              subtitle: 'Open the editor and choose "Render video" to create one.',
              action: AppButton(label: 'Edit captions', onPressed: () => context.go('/editor/$projectId')),
            );
          }
          final captioned = ref.watch(exportDownloadUrlProvider(list.first.id));
          final wide = MediaQuery.of(context).size.width >= 800;
          final panes = [
            _LabeledPlayer(label: 'Original', url: original),
            _LabeledPlayer(label: 'With captions', url: captioned),
          ];
          return Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final p in panes) Expanded(child: Padding(padding: const EdgeInsets.all(AppSpacing.sm), child: p)),
                    ],
                  )
                : ListView(children: [for (final p in panes) Padding(padding: const EdgeInsets.only(bottom: AppSpacing.lg), child: p)]),
          );
        },
      ),
    );
  }
}

class _LabeledPlayer extends StatelessWidget {
  const _LabeledPlayer({required this.label, required this.url});

  final String label;
  final AsyncValue<String> url;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppSpacing.sm),
        url.when(
          loading: () => const AspectRatio(aspectRatio: 16 / 9, child: Center(child: CircularProgressIndicator())),
          error: (e, _) => AspectRatio(
            aspectRatio: 16 / 9,
            child: ErrorMessage(message: e is ApiException ? e.message : 'Could not load this video.'),
          ),
          data: (u) => _SimplePlayer(url: u),
        ),
      ],
    );
  }
}

class _SimplePlayer extends StatefulWidget {
  const _SimplePlayer({required this.url});

  final String url;

  @override
  State<_SimplePlayer> createState() => _SimplePlayerState();
}

class _SimplePlayerState extends State<_SimplePlayer> {
  late final VideoPlayerController _c = VideoPlayerController.networkUrl(Uri.parse(widget.url));
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _c.initialize().then((_) {
      if (mounted) setState(() {});
    }).catchError((_) {
      if (mounted) setState(() => _failed = true);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return const AspectRatio(aspectRatio: 16 / 9, child: ErrorMessage(message: 'This video could not be played.'));
    }
    if (!_c.value.isInitialized) {
      return const AspectRatio(aspectRatio: 16 / 9, child: Center(child: CircularProgressIndicator()));
    }
    return Column(
      children: [
        AspectRatio(
          aspectRatio: _c.value.aspectRatio,
          child: ClipRRect(borderRadius: BorderRadius.circular(AppRadius.md), child: VideoPlayer(_c)),
        ),
        ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: _c,
          builder: (_, v, __) => Row(
            children: [
              IconButton(
                icon: Icon(v.isPlaying ? Icons.pause : Icons.play_arrow),
                onPressed: () => v.isPlaying ? _c.pause() : _c.play(),
              ),
              Expanded(child: VideoProgressIndicator(_c, allowScrubbing: true)),
            ],
          ),
        ),
      ],
    );
  }
}
