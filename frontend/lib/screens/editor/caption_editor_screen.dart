import '../../widgets/caption_scene.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../../core/api_exception.dart';
import '../../core/caption_languages.dart';
import '../../core/theme.dart';
import '../../models/caption.dart';
import '../../models/job.dart';
import '../../providers/caption_provider.dart';
import '../../providers/export_provider.dart';
import '../../providers/job_provider.dart';
import '../../providers/project_provider.dart';
import '../../widgets/app_button.dart';
import '../../widgets/caption_style_card.dart';
import '../../widgets/color_field.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/error_message.dart';
import '../../widgets/processing_progress.dart';
import '../dashboard/dashboard_shell.dart';

class CaptionEditorScreen extends ConsumerStatefulWidget {
  const CaptionEditorScreen({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<CaptionEditorScreen> createState() =>
      _CaptionEditorScreenState();
}

class _CaptionEditorScreenState extends ConsumerState<CaptionEditorScreen> {
  VideoPlayerController? _video;
  double _positionSeconds = 0;
  bool _isDownloading = false;
  bool _isSaveRenderBusy = false;

  @override
  void dispose() {
    _video?.removeListener(_onTick);
    _video?.dispose();
    super.dispose();
  }

  void _attachVideo(String url) {
    if (_video != null) return;
    final c = VideoPlayerController.networkUrl(Uri.parse(url));
    _video = c;
    c.initialize().then((_) {
      if (mounted) setState(() {});
    });
    c.addListener(_onTick);
  }

  void _onTick() {
    final v = _video;
    if (v == null || !mounted) return;
    final pos = v.value.position.inMilliseconds / 1000.0;
    if ((pos - _positionSeconds).abs() > 0.05 || !v.value.isPlaying) {
      setState(() => _positionSeconds = pos);
    }
  }

  Future<void> _editWord(int segIndex, int wordIndex, String current) async {
    final controller = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit word'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (result != null) {
      final notifier =
          ref.read(captionEditorProvider(widget.projectId).notifier);
      // wordIndex -1 means "this segment has no word-level data": edit the line.
      if (wordIndex < 0) {
        if (result.trim().isNotEmpty)
          notifier.updateSegmentText(segIndex, result.trim());
      } else {
        notifier.updateWordText(segIndex, wordIndex, result);
      }
    }
  }

  Future<void> _editTiming(int segIndex, CaptionSegment segment) async {
    final startController =
        TextEditingController(text: segment.start.toStringAsFixed(2));
    final endController =
        TextEditingController(text: segment.end.toStringAsFixed(2));
    final result = await showDialog<(double, double)>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Adjust caption timing'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: startController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration:
                    const InputDecoration(labelText: 'Start (seconds)')),
            TextField(
                controller: endController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'End (seconds)')),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
              onPressed: () {
                final start = double.tryParse(startController.text);
                final end = double.tryParse(endController.text);
                if (start != null && end != null && start >= 0 && end > start) {
                  Navigator.pop(ctx, (start, end));
                }
              },
              child: const Text('Save')),
        ],
      ),
    );
    startController.dispose();
    endController.dispose();
    if (result != null) {
      ref
          .read(captionEditorProvider(widget.projectId).notifier)
          .updateSegmentTiming(segIndex, result.$1, result.$2);
    }
  }

  Future<void> _renderAgain() async {
    if (_isSaveRenderBusy) return;
    setState(() => _isSaveRenderBusy = true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _SaveRenderDialog(),
    ).then((_) {});

    final notifier = ref.read(captionEditorProvider(widget.projectId).notifier);
    var dialogOpen = true;
    try {
      final jobId = await notifier.saveAndRerender();
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      dialogOpen = false;
      if (jobId != null) {
        final result = await showDialog<Job>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _InPlaceRenderDialog(jobId: jobId),
        );
        await notifier.finishRender(jobId,
            completed: result?.isCompleted == true);
        if (mounted) {
          ref.invalidate(exportsProvider(widget.projectId));
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                result?.isCompleted == true
                    ? 'Your edited video is ready to download.'
                    : (result?.error ?? 'Video rendering did not complete.'),
              ),
            ),
          );
        }
      } else {
        final msg =
            ref.read(captionEditorProvider(widget.projectId)).errorMessage;
        if (msg != null) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(msg)));
        }
      }
    } finally {
      if (dialogOpen && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      if (mounted) setState(() => _isSaveRenderBusy = false);
    }
  }

  Future<void> _downloadLatest() async {
    setState(() => _isDownloading = true);
    try {
      final editorState = ref.read(captionEditorProvider(widget.projectId));
      if (editorState.hasUnsavedChanges || editorState.hasUnrenderedChanges) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Save & render your changes before downloading.'),
          ),
        );
        return;
      }

      final exportId = await ref
          .read(captionEditorProvider(widget.projectId).notifier)
          .matchingExportId();
      if (!mounted) return;
      if (exportId == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content:
                  Text('Render your current settings before downloading.')),
        );
        return;
      }

      final url = await fetchExportDownloadUrl(ref, exportId);
      final opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
        webOnlyWindowName: '_self',
      );
      if (!opened && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't open the download link.")),
        );
      }
    } on ApiException catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Could not download the latest render.')),
        );
      }
    } finally {
      if (mounted) setState(() => _isDownloading = false);
    }
  }

  Future<bool> _confirmLeave(bool dirty) async {
    if (!dirty) return true;
    return showConfirmDialog(
      context,
      title: 'Discard changes?',
      message: 'You have unsaved caption edits.',
      confirmLabel: 'Discard',
      destructive: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(captionEditorProvider(widget.projectId));
    final notifier = ref.read(captionEditorProvider(widget.projectId).notifier);

    ref.listen<AsyncValue<String>>(videoPreviewUrlProvider(widget.projectId),
        (_, next) {
      final url = next.valueOrNull;
      if (url != null) _attachVideo(url);
    });
    // Also handle the case where the URL is already cached.
    final cachedUrl =
        ref.watch(videoPreviewUrlProvider(widget.projectId)).valueOrNull;
    if (cachedUrl != null) _attachVideo(cachedUrl);

    if (state.isLoading) {
      return Scaffold(
          appBar: AppBar(title: const Text('Edit captions')),
          body: const Center(child: CircularProgressIndicator()));
    }
    if (state.transcript == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Edit captions')),
        body: ErrorMessage(
            message: state.errorMessage ?? 'No captions found.',
            onRetry: notifier.load),
      );
    }

    final wide = MediaQuery.of(context).size.width >= Breakpoints.desktop;
    _VideoPane videoPane(double availableHeight) => _VideoPane(
          controller: _video,
          transcript: state.transcript!,
          positionSeconds: _positionSeconds,
          presetId: state.stylePreset,
          overrides: state.styleOverrides,
          videoFormat: state.videoFormat,
          availableHeight: availableHeight,
          onTransformChanged: (x, y, scale, rotation) =>
              notifier.setStyleOverrides(
            state.styleOverrides.copyWith(
              positionX: x,
              positionY: y,
              scale: scale,
              rotationDegrees: rotation,
            ),
          ),
          onDownload: _downloadLatest,
          isDownloading: _isDownloading,
        );
    final controls = _ControlsPane(
      projectId: widget.projectId,
      state: state,
      videoFormat: state.videoFormat,
      onEditWord: _editWord,
      onEditTiming: _editTiming,
      onSeek: (s) => _video?.seekTo(Duration(milliseconds: (s * 1000).round())),
    );

    return PopScope(
      canPop: !state.hasUnsavedChanges,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmLeave(state.hasUnsavedChanges) && context.mounted)
          context.go('/dashboard');
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Edit captions'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () async {
              if (await _confirmLeave(state.hasUnsavedChanges) &&
                  context.mounted) context.go('/dashboard');
            },
          ),
          actions: [
            AppButton(
              label: 'Save & render',
              variant: AppButtonVariant.text,
              onPressed:
                  (state.hasUnsavedChanges || state.hasUnrenderedChanges) &&
                          !_isSaveRenderBusy
                      ? _renderAgain
                      : null,
            ),
            const SizedBox(width: AppSpacing.sm),
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.md),
              child: AppButton(
                label: 'Render video',
                icon: Icons.movie_filter_outlined,
                onPressed: state.isRendering || _isSaveRenderBusy
                    ? null
                    : _renderAgain,
              ),
            ),
          ],
        ),
        body: LayoutBuilder(
          builder: (context, constraints) => wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 5,
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        child: videoPane(
                            constraints.maxHeight - AppSpacing.md * 2),
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(flex: 6, child: controls),
                  ],
                )
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      child: videoPane(constraints.maxHeight * 0.46),
                    ),
                    Expanded(child: controls),
                  ],
                ),
        ),
      ),
    );
  }
}

/// Position the preset uses by default (mirrors ffmpeg_service.CAPTION_PRESETS).
String _presetPosition(String presetId) => captionPosition(presetId);

double _positionY(String position) => captionPositionY(position);

class _SaveRenderDialog extends StatelessWidget {
  const _SaveRenderDialog();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_awesome_outlined,
              size: 30,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text('Saving your changes',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Preparing your edited video…',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.md),
            const SizedBox(width: 220, child: LinearProgressIndicator()),
          ],
        ),
      ),
    );
  }
}

class _InPlaceRenderDialog extends ConsumerWidget {
  const _InPlaceRenderDialog({required this.jobId});

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
                Text('Preparing your edited video'),
                SizedBox(height: AppSpacing.md),
                LinearProgressIndicator(),
              ],
            ),
            error: (error, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline,
                    color: AppColors.danger, size: 42),
                const SizedBox(height: AppSpacing.sm),
                Text(error is ApiException
                    ? error.message
                    : 'Could not read render progress.'),
              ],
            ),
            data: (job) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  job.isCompleted
                      ? 'Your edited video is ready'
                      : 'Rendering your edited video',
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

class _VideoPane extends StatelessWidget {
  const _VideoPane({
    required this.controller,
    required this.transcript,
    required this.positionSeconds,
    required this.presetId,
    required this.overrides,
    required this.videoFormat,
    required this.availableHeight,
    required this.onTransformChanged,
    required this.onDownload,
    required this.isDownloading,
  });

  final VideoPlayerController? controller;
  final CaptionTranscript transcript;
  final double positionSeconds;
  final String presetId;
  final StyleOverrides overrides;
  final String videoFormat;
  final double availableHeight;
  final void Function(double x, double y, double scale, double rotationDegrees)
      onTransformChanged;
  final VoidCallback onDownload;
  final bool isDownloading;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final ready = c != null && c.value.isInitialized;
    // Reserve space for playback controls, helper text, and the download
    // action so the entire preview pane fits inside the editor viewport.
    final frameAspectRatio = switch (videoFormat) {
      '1:1' => 1.0,
      '4:5' => 4 / 5,
      '16:9' => 16 / 9,
      'original' => ready ? c.value.aspectRatio : 9 / 16,
      _ => 9 / 16,
    };
    final maxFrameHeight =
        (availableHeight - 132).clamp(180.0, 720.0).toDouble();
    final maxFrameWidth = maxFrameHeight * frameAspectRatio;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxWidth: maxFrameWidth, maxHeight: maxFrameHeight),
            child: AspectRatio(
              // Keep the editor preview in the same portrait frame as an Instagram Reel.
              // The source video is contained inside it, so landscape videos get black bars
              // instead of making the whole editor excessively tall.
              aspectRatio: frameAspectRatio,
              child: LayoutBuilder(
                builder: (context, frame) => ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Container(color: Colors.black),
                      if (ready)
                        FittedBox(
                          fit: BoxFit.contain,
                          child: SizedBox(
                            width: c.value.size.width,
                            height: c.value.size.height,
                            child: VideoPlayer(c),
                          ),
                        )
                      else
                        const Center(child: CircularProgressIndicator()),
                      CaptionScene(
                        transcript: transcript,
                        presetId: presetId,
                        overrides: overrides,
                        time: positionSeconds,
                        onTransformChanged: onTransformChanged,
                      ),
                      Positioned(
                        top: 8,
                        right: 8,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.open_with,
                                    color: Colors.white, size: 13),
                                SizedBox(width: 4),
                                Text(
                                  'Drag caption',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (ready)
          Row(
            children: [
              IconButton(
                icon: Icon(c.value.isPlaying ? Icons.pause : Icons.play_arrow),
                onPressed: () => c.value.isPlaying ? c.pause() : c.play(),
              ),
              Expanded(
                child: VideoProgressIndicator(c,
                    allowScrubbing: true,
                    padding: const EdgeInsets.symmetric(vertical: 12)),
              ),
            ],
          ),
        Text(
          'Drag, pinch, or twist captions here. Export uses the same renderer.',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: AppSpacing.sm),
        Align(
          alignment: Alignment.center,
          child: AppButton(
            label: 'Download edited video',
            icon: Icons.download_outlined,
            variant: AppButtonVariant.secondary,
            isLoading: isDownloading,
            onPressed: onDownload,
          ),
        ),
      ],
    );
  }
}

class _ControlsPane extends ConsumerWidget {
  const _ControlsPane({
    required this.projectId,
    required this.state,
    required this.videoFormat,
    required this.onEditWord,
    required this.onEditTiming,
    required this.onSeek,
  });

  final String projectId;
  final CaptionEditorState state;
  final String videoFormat;
  final Future<void> Function(int segIndex, int wordIndex, String current)
      onEditWord;
  final Future<void> Function(int segIndex, CaptionSegment segment)
      onEditTiming;
  final void Function(double seconds) onSeek;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(captionEditorProvider(projectId).notifier);
    final theme = Theme.of(context);
    final o = state.styleOverrides;
    final selectedPreset = presetInfoFor(state.stylePreset);

    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(tabs: [Tab(text: 'Style'), Tab(text: 'Captions')]),
          Expanded(
            child: TabBarView(
              children: [
                // ---------------- Style tab ----------------
                ListView(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  children: [
                    Text('Video format', style: theme.textTheme.titleMedium),
                    const SizedBox(height: AppSpacing.sm),
                    DropdownButtonFormField<String>(
                      value: videoFormat,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        for (final entry in kVideoFormatLabels.entries)
                          DropdownMenuItem(
                            value: entry.key,
                            child: Text(entry.value),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) notifier.setVideoFormat(value);
                      },
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    Row(
                      children: [
                        Text('Caption templates',
                            style: theme.textTheme.titleMedium),
                        const SizedBox(width: 6),
                        const Icon(Icons.auto_awesome, size: 17),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    SizedBox(
                      height: 178,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: kCaptionPresets.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(width: AppSpacing.sm),
                        itemBuilder: (_, i) {
                          final p = kCaptionPresets[i];
                          return CaptionStyleCard(
                            preset: p,
                            selected: p.id == state.stylePreset,
                            onTap: () => notifier.setPreset(p.id),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    Text('Colors', style: theme.textTheme.titleMedium),
                    const SizedBox(height: AppSpacing.sm),
                    Wrap(
                      spacing: AppSpacing.lg,
                      runSpacing: AppSpacing.md,
                      children: [
                        ColorField(
                            label: 'Text',
                            value: o.primaryColor ??
                                colorToHex(selectedPreset.primaryPreview),
                            onChanged: (v) => notifier.setStyleOverrides(
                                o.copyWith(primaryColor: v))),
                        ColorField(
                            label: 'Highlight words',
                            value: o.highlightColor ??
                                colorToHex(selectedPreset.highlightPreview),
                            onChanged: (v) => notifier.setStyleOverrides(
                                o.copyWith(highlightColor: v))),
                        ColorField(
                            label: 'Emphasis words',
                            value: o.emphasisColor ??
                                colorToHex(selectedPreset.emphasisPreview),
                            onChanged: (v) => notifier.setStyleOverrides(
                                o.copyWith(emphasisColor: v))),
                        ColorField(
                            label: 'Background',
                            value: o.backgroundColor ??
                                colorToHex(selectedPreset.backgroundPreview),
                            onChanged: (v) => notifier.setStyleOverrides(
                                o.copyWith(backgroundColor: v))),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    Text('Background opacity',
                        style: theme.textTheme.titleSmall),
                    Slider(
                      min: 0,
                      max: 1,
                      divisions: 20,
                      value: (o.backgroundOpacity ?? 0.75)
                          .clamp(0.0, 1.0)
                          .toDouble(),
                      label:
                          '${((o.backgroundOpacity ?? 0.75) * 100).round()}%',
                      onChanged: (v) => notifier
                          .setStyleOverrides(o.copyWith(backgroundOpacity: v)),
                    ),
                    Text('Size and position',
                        style: theme.textTheme.titleMedium),
                    const SizedBox(height: AppSpacing.sm),
                    DropdownButtonFormField<String>(
                      value: o.fontFamily ?? 'auto',
                      decoration: const InputDecoration(
                        labelText: 'Font family',
                        helperText:
                            'Automatic selects a font for the caption language. You can choose a different script font here.',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: const [
                        DropdownMenuItem(
                            value: 'auto',
                            child: Text('Automatic for caption language')),
                        DropdownMenuItem(
                            value: 'Caption Sans', child: Text('Noto Sans')),
                        DropdownMenuItem(
                            value: 'Caption Arabic',
                            child: Text('Noto Naskh Arabic')),
                        DropdownMenuItem(
                            value: 'Caption Urdu',
                            child: Text('Noto Nastaliq Urdu')),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        notifier.setStyleOverrides(o.copyWith(
                          fontFamily: value == 'auto' ? null : value,
                          clearFontFamily: value == 'auto',
                        ));
                      },
                    ),
                    Slider(
                      min: 16,
                      max: 120,
                      divisions: 52,
                      value: (o.fontSize ?? 44).clamp(16, 120).toDouble(),
                      label: '${o.fontSize ?? 44}',
                      onChanged: (v) => notifier
                          .setStyleOverrides(o.copyWith(fontSize: v.round())),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Bold'),
                      value: o.bold ?? selectedPreset.bold,
                      onChanged: (v) =>
                          notifier.setStyleOverrides(o.copyWith(bold: v)),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Italic'),
                      value: o.italic ?? false,
                      onChanged: (v) =>
                          notifier.setStyleOverrides(o.copyWith(italic: v)),
                    ),
                    Text('Letter spacing', style: theme.textTheme.titleSmall),
                    Slider(
                      min: -1,
                      max: 4,
                      divisions: 50,
                      value: (o.letterSpacing ?? 0).clamp(-1.0, 4.0).toDouble(),
                      label: (o.letterSpacing ?? 0).toStringAsFixed(1),
                      onChanged: (v) => notifier
                          .setStyleOverrides(o.copyWith(letterSpacing: v)),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Show suggested emojis'),
                      value: o.emojisEnabled,
                      onChanged: (v) => notifier
                          .setStyleOverrides(o.copyWith(emojisEnabled: v)),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Motion animations'),
                      value: o.motionEnabled,
                      onChanged: (v) => notifier
                          .setStyleOverrides(o.copyWith(motionEnabled: v)),
                    ),
                    Text('Caption scale', style: theme.textTheme.titleSmall),
                    Slider(
                      min: 0.5,
                      max: 2,
                      divisions: 30,
                      value: o.scale.clamp(0.5, 2).toDouble(),
                      label: '${(o.scale * 100).round()}%',
                      onChanged: (v) =>
                          notifier.setStyleOverrides(o.copyWith(scale: v)),
                    ),
                    Text('Rotation', style: theme.textTheme.titleSmall),
                    Slider(
                      min: -30,
                      max: 30,
                      divisions: 60,
                      value: o.rotationDegrees.clamp(-30, 30).toDouble(),
                      label: '${o.rotationDegrees.round()}°',
                      onChanged: (v) => notifier
                          .setStyleOverrides(o.copyWith(rotationDegrees: v)),
                    ),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'top', label: Text('Top')),
                        ButtonSegment(value: 'center', label: Text('Middle')),
                        ButtonSegment(value: 'bottom', label: Text('Bottom')),
                      ],
                      selected: {
                        o.position ?? _presetPosition(state.stylePreset)
                      },
                      onSelectionChanged: (s) {
                        final position = s.first;
                        notifier.setStyleOverrides(
                          o.copyWith(
                            position: position,
                            positionX: 0.5,
                            positionY: _positionY(position),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Row(
                      children: [
                        const Icon(Icons.open_with, size: 18),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Drag to position. Pinch to scale and twist to rotate the caption.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                        Text(
                          '${((o.positionX ?? 0.5) * 100).round()}%, '
                          '${((o.positionY ?? _positionY(o.position ?? _presetPosition(state.stylePreset))) * 100).round()}%',
                          style: theme.textTheme.labelSmall,
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextButton(
                      onPressed: () =>
                          notifier.setStyleOverrides(const StyleOverrides()),
                      child: const Text('Reset customizations'),
                    ),
                  ],
                ),
                // ---------------- Captions tab ----------------
                ListView.separated(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  itemCount: state.transcript!.segments.length + 1,
                  separatorBuilder: (_, __) =>
                      const Divider(height: AppSpacing.lg),
                  itemBuilder: (context, i) {
                    if (i == 0) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _CaptionLanguageControl(
                            transcript: state.transcript!,
                            notifier: notifier,
                            isTranslating: state.isTranslating,
                          ),
                          const SizedBox(height: AppSpacing.md),
                          Wrap(
                            spacing: AppSpacing.xs,
                            children: [
                              TextButton.icon(
                                onPressed: state.canUndo ? notifier.undo : null,
                                icon: const Icon(Icons.undo, size: 18),
                                label: const Text('Undo'),
                              ),
                              TextButton.icon(
                                onPressed: state.canRedo ? notifier.redo : null,
                                icon: const Icon(Icons.redo, size: 18),
                                label: const Text('Redo'),
                              ),
                            ],
                          ),
                          Text(
                            'Tap a word to cycle normal / highlight / emphasis. Long-press to edit its text. Tap the emoji control to add or remove Gemini-suggested emojis.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      );
                    }
                    final segIndex = i - 1;
                    final seg = state.transcript!.segments[segIndex];
                    return _SegmentRow(
                      segment: seg,
                      onSeek: () => onSeek(seg.start),
                      onTapWord: (w) => notifier.cycleWordStyle(segIndex, w),
                      onSetEmoji: (w, emoji) =>
                          notifier.setWordEmoji(segIndex, w, emoji),
                      onLongPressWord: (w) =>
                          onEditWord(segIndex, w, seg.words[w].text),
                      onEditSegment: () => onEditWord(segIndex, -1, seg.text),
                      onEditTiming: () => onEditTiming(segIndex, seg),
                      canSplit: seg.words.length >= 2 ||
                          seg.text.trim().split(RegExp(r'\s+')).length >= 2,
                      canMergeNext:
                          segIndex + 1 < state.transcript!.segments.length,
                      onSplit: () => notifier.splitSegment(segIndex),
                      onMerge: () => notifier.mergeSegmentWithNext(segIndex),
                      onDelete: () => notifier.deleteSegment(segIndex),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CaptionLanguageControl extends StatelessWidget {
  const _CaptionLanguageControl({
    required this.transcript,
    required this.notifier,
    required this.isTranslating,
  });

  final CaptionTranscript transcript;
  final CaptionEditorNotifier notifier;
  final bool isTranslating;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Caption text language: ${transcript.language}',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          OutlinedButton.icon(
            onPressed: isTranslating
                ? null
                : () async {
                    final language = await showDialog<String>(
                      context: context,
                      builder: (_) => _CaptionLanguageDialog(
                        currentLanguage: transcript.language,
                      ),
                    );
                    if (language == null || !context.mounted) return;
                    final changed = await notifier.translateTo(language);
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(changed
                          ? 'Captions changed to $language. Save to keep the change.'
                          : notifier.state.errorMessage ??
                              'Could not change caption language.'),
                    ));
                  },
            icon: isTranslating
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.translate),
            label: Text(isTranslating
                ? 'Generating captions…'
                : 'Change language with Gemini'),
          ),
          if (isTranslating) const LinearProgressIndicator(),
        ],
      );
}

class _CaptionLanguageDialog extends StatefulWidget {
  const _CaptionLanguageDialog({required this.currentLanguage});

  final String currentLanguage;

  @override
  State<_CaptionLanguageDialog> createState() => _CaptionLanguageDialogState();
}

class _CaptionLanguageDialogState extends State<_CaptionLanguageDialog> {
  late final TextEditingController _customLanguage = TextEditingController(
    text: captionLanguages.any((language) =>
            language.toLowerCase() == widget.currentLanguage.toLowerCase())
        ? ''
        : widget.currentLanguage,
  );
  late String _selected = captionLanguages.any((language) =>
          language.toLowerCase() == widget.currentLanguage.toLowerCase())
      ? captionLanguages.firstWhere((language) =>
          language.toLowerCase() == widget.currentLanguage.toLowerCase())
      : 'other';

  @override
  void dispose() {
    _customLanguage.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Caption text language'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              value: _selected,
              decoration: const InputDecoration(labelText: 'Language'),
              items: [
                for (final language in captionLanguages)
                  DropdownMenuItem(value: language, child: Text(language)),
                const DropdownMenuItem(
                    value: 'other', child: Text('Other language…')),
              ],
              onChanged: (value) =>
                  setState(() => _selected = value ?? 'English'),
            ),
            if (_selected == 'other') ...[
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _customLanguage,
                autofocus: true,
                decoration:
                    const InputDecoration(labelText: 'Enter language name'),
                onChanged: (_) => setState(() {}),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed:
                _selected == 'other' && _customLanguage.text.trim().length < 2
                    ? null
                    : () => Navigator.pop(
                          context,
                          _selected == 'other'
                              ? _customLanguage.text.trim()
                              : _selected,
                        ),
            child: const Text('Generate'),
          ),
        ],
      );
}

class _SegmentRow extends StatelessWidget {
  const _SegmentRow({
    required this.segment,
    required this.onSeek,
    required this.onTapWord,
    required this.onSetEmoji,
    required this.onLongPressWord,
    required this.onEditSegment,
    required this.onEditTiming,
    required this.canSplit,
    required this.canMergeNext,
    required this.onSplit,
    required this.onMerge,
    required this.onDelete,
  });

  final CaptionSegment segment;
  final VoidCallback onSeek;
  final void Function(int wordIndex) onTapWord;
  final void Function(int wordIndex, String? emoji) onSetEmoji;
  final void Function(int wordIndex) onLongPressWord;
  final VoidCallback onEditSegment;
  final VoidCallback onEditTiming;
  final bool canSplit;
  final bool canMergeNext;
  final VoidCallback onSplit;
  final VoidCallback onMerge;
  final VoidCallback onDelete;

  String _t(double s) {
    final m = (s ~/ 60).toString().padLeft(2, '0');
    final sec = (s % 60).toStringAsFixed(1).padLeft(4, '0');
    return '$m:$sec';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Color? chipColor(WordStyle s) => switch (s) {
          WordStyle.normal => null,
          WordStyle.highlight => AppColors.warning.withOpacity(0.2),
          WordStyle.emphasis => AppColors.danger.withOpacity(0.18),
        };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            InkWell(
              onTap: onSeek,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text('${_t(segment.start)} - ${_t(segment.end)}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.primary)),
              ),
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Adjust timing',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.schedule, size: 18),
              onPressed: onEditTiming,
            ),
            PopupMenuButton<String>(
              tooltip: 'Caption actions',
              onSelected: (action) {
                switch (action) {
                  case 'split':
                    onSplit();
                    break;
                  case 'merge':
                    onMerge();
                    break;
                  case 'delete':
                    onDelete();
                    break;
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                    value: 'split',
                    enabled: canSplit,
                    child: const Text('Split caption')),
                PopupMenuItem(
                    value: 'merge',
                    enabled: canMergeNext,
                    child: const Text('Merge with next')),
                const PopupMenuItem(
                    value: 'delete', child: Text('Delete caption')),
              ],
            ),
            Tooltip(
              message: 'How important Gemini judged this line (drives styling)',
              child: Text('weight ${(segment.weight * 100).round()}%',
                  style: theme.textTheme.bodySmall),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        if (segment.words.isEmpty)
          // No word-level data: edit the whole line instead.
          InkWell(
              onTap: onEditSegment,
              child: Text(segment.text, style: theme.textTheme.bodyLarge))
        else
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (var w = 0; w < segment.words.length; w++)
                GestureDetector(
                  onTap: () => onTapWord(w),
                  onLongPress: () => onLongPressWord(w),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: chipColor(segment.words[w].style),
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      border: Border.all(
                          color: theme.dividerTheme.color ?? Colors.grey),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(
                        segment.words[w].text,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: segment.words[w].style == WordStyle.normal
                              ? FontWeight.w400
                              : FontWeight.w700,
                        ),
                      ),
                      if (segment.words[w].emoji != null) ...[
                        const SizedBox(width: 4),
                        Text(segment.words[w].emoji!),
                      ],
                      PopupMenuButton<String>(
                        tooltip: 'Add or remove emoji',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 48),
                        iconSize: 16,
                        icon: const Icon(Icons.add_reaction_outlined),
                        onSelected: (value) =>
                            onSetEmoji(w, value == '__remove__' ? null : value),
                        itemBuilder: (_) => [
                          if (segment.words[w].emoji != null)
                            const PopupMenuItem(
                                value: '__remove__',
                                child: Text('Remove emoji')),
                          for (final emoji in [
                            '✨',
                            '😀',
                            '❤️',
                            '🔥',
                            '🎉',
                            '⚡',
                            '📍',
                            '💡',
                            '✅',
                            '😂'
                          ])
                            PopupMenuItem(value: emoji, child: Text(emoji)),
                        ],
                      ),
                    ]),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}
