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
        title: Text(wordIndex < 0 ? 'Edit caption line' : 'Edit word'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: wordIndex < 0 ? 2 : 1,
          maxLines: wordIndex < 0 ? 5 : 1,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'Type your caption. Use your keyboard’s emoji picker to add emoji.',
            border: OutlineInputBorder(),
          ),
        ),
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

  Future<void> _requestCaptionTranslation(
    BuildContext context,
    CaptionTranscript transcript,
    CaptionEditorNotifier notifier,
  ) async {
    final sourceLanguage = transcript.sourceTrack?.language ??
        (transcript.activeTrack == 'source'
            ? transcript.language
            : 'English');
    final language = await showDialog<String>(
      context: context,
      builder: (_) => _CaptionLanguageDialog(
        currentLanguage: sourceLanguage,
        targetLanguage: transcript.translationTrack?.language,
      ),
    );
    if (language == null || !context.mounted) return;
    final savedMatches = transcript.translationTracks
        .where((track) =>
            track.language.toLowerCase() == language.toLowerCase())
        .toList();
    if (savedMatches.isNotEmpty) {
      notifier.selectCaptionTrack(
        'translation',
        language: savedMatches.first.language,
      );
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Showing saved ${savedMatches.first.language} translation.'),
      ));
      return;
    }
    final changed = await notifier.translateTo(language);
    if (changed) notifier.selectCaptionTrack('translation');
    if (!context.mounted) return;
    final error = ref
        .read(captionEditorProvider(widget.projectId))
        .errorMessage;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(changed
          ? 'Translation generated in $language and selected for preview. Save & render to update your video.'
          : error ?? 'Could not generate translation.'),
    ));
  }

  Future<void> _translateCaptionTo(
    BuildContext context,
    CaptionEditorNotifier notifier,
    String language,
  ) async {
    final changed = await notifier.translateTo(language);
    if (changed) notifier.selectCaptionTrack('translation');
    if (!context.mounted) return;
    final error = ref
        .read(captionEditorProvider(widget.projectId))
        .errorMessage;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(changed
          ? 'Translation generated in $language and selected for preview. Save & render to update your video.'
          : error ?? 'Could not generate translation.'),
    ));
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
          onTransformChanged: (x, y, scale, rotation) {
            final index = state.transcript!.segments.indexWhere((segment) =>
                _positionSeconds >= segment.start &&
                _positionSeconds < segment.end);
            if (index >= 0) {
              notifier.updateSegmentTransform(
                index,
                x: x,
                y: y,
                scale: scale,
                rotationDegrees: rotation,
              );
            }
          },
          onDownload: _downloadLatest,
          isDownloading: _isDownloading,
        );
    final controls = _ControlsPane(
      projectId: widget.projectId,
      state: state,
      videoFormat: state.videoFormat,
      currentTime: _positionSeconds,
      onEditWord: _editWord,
      onEditTiming: _editTiming,
      onRequestTranslation: _requestCaptionTranslation,
      onTranslateTo: _translateCaptionTo,
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
    required this.currentTime,
    required this.onEditWord,
    required this.onEditTiming,
    required this.onRequestTranslation,
    required this.onTranslateTo,
    required this.onSeek,
  });

  final String projectId;
  final CaptionEditorState state;
  final String videoFormat;
  final double currentTime;
  final Future<void> Function(int segIndex, int wordIndex, String current)
      onEditWord;
  final Future<void> Function(int segIndex, CaptionSegment segment)
      onEditTiming;
  final Future<void> Function(
    BuildContext context,
    CaptionTranscript transcript,
    CaptionEditorNotifier notifier,
  ) onRequestTranslation;
  final Future<void> Function(
    BuildContext context,
    CaptionEditorNotifier notifier,
    String language,
  ) onTranslateTo;
  final void Function(double seconds) onSeek;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(captionEditorProvider(projectId).notifier);
    final theme = Theme.of(context);
    final o = state.styleOverrides;
    final currentLineIndex = state.transcript!.segments.indexWhere(
      (segment) => currentTime >= segment.start && currentTime < segment.end,
    );
    final currentLine = state.transcript!.segments.cast<CaptionSegment?>().firstWhere(
          (segment) => segment != null &&
              currentTime >= segment.start && currentTime < segment.end,
          orElse: () => null,
        );
    final automaticCaptionFont = currentLine == null
        ? captionFontForTranscript(state.transcript!)
        : captionFontForText(currentLine.text, state.transcript!.language);
    final activeCaptionFont = currentLine?.fontFamily == 'auto'
        ? automaticCaptionFont
        : currentLine?.fontFamily ?? o.fontFamily ?? automaticCaptionFont;
    final selectedPreset = presetInfoFor(currentLine?.stylePreset ?? state.stylePreset);
    final effectiveY = currentLine?.positionY ?? o.positionY ??
        _positionY(o.position ?? _presetPosition(state.stylePreset));
    final selectedPosition = effectiveY < 0.34
        ? 'top'
        : effectiveY < 0.68
            ? 'center'
            : 'bottom';

    void updateCurrentLineTransform({double? x, double? y, double? scale, double? rotation}) {
      if (currentLineIndex < 0) return;
      notifier.updateSegmentTransform(
        currentLineIndex,
        x: x ?? currentLine!.positionX ?? o.positionX ?? 0.5,
        y: y ?? currentLine!.positionY ?? o.positionY ??
            _positionY(o.position ?? _presetPosition(state.stylePreset)),
        scale: scale ?? currentLine!.scale ?? o.scale,
        rotationDegrees: rotation ?? currentLine!.rotationDegrees ?? o.rotationDegrees,
      );
    }

    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(tabs: [
            Tab(icon: Icon(Icons.tune), text: 'Style'),
            Tab(icon: Icon(Icons.subtitles_outlined), text: 'Captions'),
          ]),
          Expanded(
            child: TabBarView(
              children: [
                // ---------------- Style tab ----------------
                ListView(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  children: [
                    if (currentLine != null) ...[
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpacing.md),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.subtitles,
                                  color: theme.colorScheme.primary),
                              const SizedBox(width: AppSpacing.sm),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Selected caption line',
                                        style: theme.textTheme.labelLarge),
                                    const SizedBox(height: 4),
                                    Text(currentLine.text,
                                        style: theme.textTheme.bodyMedium),
                                    const SizedBox(height: 4),
                                    Text(
                                      'Word weights: ${currentLine.words.isEmpty ? 'not available' : currentLine.words.map((word) => word.weight).join(' · ')}',
                                      style: theme.textTheme.bodySmall,
                                    ),
                                    const SizedBox(height: 4),
                                    Text('Template, font, animation, size, and placement are saved for this line.',
                                        style: theme.textTheme.bodySmall),
                                    const SizedBox(height: 4),
                                    Text('Tap a caption timestamp in Captions to select another line.',
                                        style: theme.textTheme.bodySmall),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                    ],
                    _EditorSectionHeading(
                      icon: Icons.movie_creation_outlined,
                      title: 'Canvas',
                      subtitle: 'Set the output shape for your captions.',
                    ),
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
                    _EditorSectionHeading(
                      icon: Icons.auto_awesome_outlined,
                      title: 'Caption templates',
                      subtitle: 'Choose a template for the caption line shown in the preview.',
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
                            selected: p.id == (currentLine?.stylePreset ?? state.stylePreset),
                            onTap: () => currentLineIndex >= 0
                                ? notifier.updateSegmentStyle(currentLineIndex, stylePreset: p.id)
                                : notifier.setPreset(p.id),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    _EditorSectionHeading(
                      icon: Icons.palette_outlined,
                      title: 'Colors',
                      subtitle: 'Tune text, emphasis, and panel colors.',
                    ),
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
                    _EditorSectionHeading(
                      icon: Icons.open_with,
                      title: 'Typography and placement',
                      subtitle: 'Drag the dotted caption box in the preview to place it. Pinch to scale.',
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    DropdownButtonFormField<String>(
                      value: currentLine?.fontFamily ?? o.fontFamily ?? 'auto',
                      decoration: const InputDecoration(
                        labelText: 'Font family',
                        helperText: 'Automatic uses the current caption text, not the spoken-language setting.',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        DropdownMenuItem(
                            value: 'auto',
                            child: Text('Automatic · ${captionFontLabel(automaticCaptionFont)}')),
                        DropdownMenuItem(
                            value: 'Caption Sans', child: Text('Noto Sans · Clean')),
                        DropdownMenuItem(
                            value: 'Caption Arabic',
                            child: Text('Noto Naskh Arabic')),
                        DropdownMenuItem(
                            value: 'Caption Urdu',
                            child: Text('Noto Nastaliq Urdu')),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        if (currentLineIndex >= 0) {
                          notifier.updateSegmentStyle(currentLineIndex,
                              fontFamily: value);
                        } else {
                          notifier.setStyleOverrides(o.copyWith(
                            fontFamily: value == 'auto' ? null : value,
                            clearFontFamily: value == 'auto',
                          ));
                        }
                      },
                    ),
                    Text(
                      'Font for this caption text: ${captionFontLabel(activeCaptionFont)}',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Slider(
                      min: 16,
                      max: 120,
                      divisions: 52,
                      value: (currentLine?.fontSize ?? o.fontSize ?? 44).clamp(16, 120).toDouble(),
                      label: '${currentLine?.fontSize ?? o.fontSize ?? 44}',
                      onChanged: (v) => currentLineIndex >= 0
                          ? notifier.updateSegmentStyle(currentLineIndex, fontSize: v.round())
                          : notifier.setStyleOverrides(o.copyWith(fontSize: v.round())),
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
                      title: const Text('Show manually added emojis'),
                      value: o.emojisEnabled,
                      onChanged: (v) => notifier
                          .setStyleOverrides(o.copyWith(emojisEnabled: v)),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Motion animations'),
                      value: currentLine?.motionEnabled ?? o.motionEnabled,
                      onChanged: (v) => currentLineIndex >= 0
                          ? notifier.updateSegmentStyle(currentLineIndex, motionEnabled: v)
                          : notifier.setStyleOverrides(o.copyWith(motionEnabled: v)),
                    ),
                    Text('Caption scale', style: theme.textTheme.titleSmall),
                    Slider(
                      min: 0.5,
                      max: 2,
                      divisions: 30,
                      value: (currentLine?.scale ?? o.scale).clamp(0.5, 2).toDouble(),
                      label: '${((currentLine?.scale ?? o.scale) * 100).round()}%',
                      onChanged: (v) => updateCurrentLineTransform(scale: v),
                    ),
                    Text('Rotation', style: theme.textTheme.titleSmall),
                    Slider(
                      min: -30,
                      max: 30,
                      divisions: 60,
                      value: (currentLine?.rotationDegrees ?? o.rotationDegrees).clamp(-30, 30).toDouble(),
                      label: '${(currentLine?.rotationDegrees ?? o.rotationDegrees).round()}°',
                      onChanged: (v) => updateCurrentLineTransform(rotation: v),
                    ),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'top', label: Text('Top')),
                        ButtonSegment(value: 'center', label: Text('Middle')),
                        ButtonSegment(value: 'bottom', label: Text('Bottom')),
                      ],
                      selected: {
                        currentLineIndex >= 0
                            ? selectedPosition
                            : o.position ?? _presetPosition(state.stylePreset)
                      },
                      onSelectionChanged: (s) {
                        final position = s.first;
                        if (currentLineIndex >= 0) {
                          updateCurrentLineTransform(x: 0.5, y: _positionY(position));
                        } else {
                          notifier.setStyleOverrides(o.copyWith(
                            position: position,
                            positionX: 0.5,
                            positionY: _positionY(position),
                          ));
                        }
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
                            onRequestTranslation: onRequestTranslation,
                            onTranslateTo: onTranslateTo,
                            fontFamily: activeCaptionFont,
                          ),
                          const SizedBox(height: AppSpacing.md),
                          Text('Caption track',
                              style: theme.textTheme.titleSmall),
                          const SizedBox(height: AppSpacing.xs),
                          Wrap(
                            spacing: AppSpacing.xs,
                            runSpacing: AppSpacing.xs,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              ChoiceChip(
                                avatar: const Icon(
                                    Icons.record_voice_over_outlined, size: 18),
                                label: const Text('Caption text'),
                                selected:
                                    state.transcript!.activeTrack == 'source',
                                onSelected: (_) =>
                                    notifier.selectCaptionTrack('source'),
                              ),
                              for (final translation
                                  in state.transcript!.translationTracks)
                                ChoiceChip(
                                  avatar: const Icon(Icons.translate, size: 18),
                                  label: Text(translation.language),
                                  selected: state.transcript!.activeTrack ==
                                          'translation' &&
                                      state.transcript!.language.toLowerCase() ==
                                          translation.language.toLowerCase(),
                                  onSelected: (_) => notifier.selectCaptionTrack(
                                    'translation',
                                    language: translation.language,
                                  ),
                                ),
                              ActionChip(
                                avatar: const Icon(Icons.add, size: 18),
                                label: const Text('Add translation'),
                                onPressed: () => onRequestTranslation(
                                  context,
                                  state.transcript!,
                                  notifier,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            state.transcript!.activeTrack == 'source'
                                ? 'Caption text follows the words spoken in the video. It is shown in the preview; your translation stays separate.'
                                : 'Translation is shown in the preview. Save & render to update the downloadable video; the original caption text stays separate.',
                            style: theme.textTheme.bodySmall,
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
                            'Tap a word to change its emphasis. Double-tap or use its edit icon to change the text; tap a caption line to edit it. Add an emoji manually from the emoji button, or remove it.',
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
    required this.onRequestTranslation,
    required this.onTranslateTo,
    required this.fontFamily,
  });

  final CaptionTranscript transcript;
  final CaptionEditorNotifier notifier;
  final bool isTranslating;
  final Future<void> Function(
    BuildContext context,
    CaptionTranscript transcript,
    CaptionEditorNotifier notifier,
  ) onRequestTranslation;
  final Future<void> Function(
    BuildContext context,
    CaptionEditorNotifier notifier,
    String language,
  ) onTranslateTo;
  final String fontFamily;

  @override
  Widget build(BuildContext context) {
    final sourceLanguage = transcript.sourceTrack?.language ?? transcript.language;
    final currentTarget = transcript.translationTrack?.language;
    final selectedTarget = currentTarget == null
        ? null
        : captionLanguages.cast<String?>().firstWhere(
            (language) =>
                language?.toLowerCase() == currentTarget.toLowerCase(),
            orElse: () => null,
          );

    return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
              'Preview uses: ${transcript.activeTrack == 'source' ? 'Caption text' : 'Translation'} · ${transcript.language}',
              style: Theme.of(context).textTheme.titleSmall),
          Text('Font used: ${captionFontLabel(fontFamily)}',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: AppSpacing.xs),
          DropdownButtonFormField<String>(
            value: selectedTarget,
            decoration: InputDecoration(
              labelText: isTranslating
                  ? 'Translating captions…'
                  : 'Translate caption text to',
              prefixIcon: const Icon(Icons.translate),
              border: const OutlineInputBorder(),
            ),
            hint: const Text('Choose a language'),
            items: [
              for (final language in captionLanguages)
                DropdownMenuItem(
                  value: language,
                  enabled: language.toLowerCase() !=
                      sourceLanguage.toLowerCase(),
                  child: Text(language),
                ),
              const DropdownMenuItem(
                  value: 'other', child: Text('Other language…')),
            ],
            onChanged: isTranslating
                ? null
                : (language) {
                    if (language == null) return;
                    if (language == 'other') {
                      onRequestTranslation(context, transcript, notifier);
                    } else {
                      final matchingTracks = transcript.translationTracks
                          .where((track) =>
                              track.language.toLowerCase() ==
                              language.toLowerCase())
                          .toList();
                      final existingTrack = matchingTracks.isEmpty
                          ? null
                          : matchingTracks.first;
                      if (existingTrack != null) {
                        notifier.selectCaptionTrack(
                          'translation',
                          language: existingTrack.language,
                        );
                      } else {
                        onTranslateTo(context, notifier, language);
                      }
                    }
                  },
          ),
          if (isTranslating) const LinearProgressIndicator(),
        ],
      );
  }
}

class _CaptionLanguageDialog extends StatefulWidget {
  const _CaptionLanguageDialog({
    required this.currentLanguage,
    this.targetLanguage,
  });

  final String currentLanguage;
  final String? targetLanguage;

  @override
  State<_CaptionLanguageDialog> createState() => _CaptionLanguageDialogState();
}

class _CaptionLanguageDialogState extends State<_CaptionLanguageDialog> {
  String get _targetLanguage =>
      _selected == 'other' ? _customLanguage.text.trim() : _selected;

  bool get _canGenerate =>
      _targetLanguage.length >= 2 &&
      _targetLanguage.toLowerCase() != widget.currentLanguage.toLowerCase();

  bool _isAvailable(String? language) => language != null &&
      captionLanguages.any(
          (item) => item.toLowerCase() == language.toLowerCase());

  late final TextEditingController _customLanguage = TextEditingController(
    text: _isAvailable(widget.targetLanguage)
        ? ''
        : (widget.targetLanguage ?? ''),
  );
  late String _selected = _isAvailable(widget.targetLanguage)
      ? captionLanguages.firstWhere((language) =>
          language.toLowerCase() == widget.targetLanguage!.toLowerCase())
      : widget.targetLanguage != null
          ? 'other'
          : captionLanguages.firstWhere(
              (language) =>
                  language.toLowerCase() !=
                  widget.currentLanguage.toLowerCase(),
              orElse: () => captionLanguages.first);

  @override
  void dispose() {
    _customLanguage.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Translate captions'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Choose the language you want captions translated into. Source language: ${widget.currentLanguage}.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.sm),
            DropdownButtonFormField<String>(
              value: _selected,
              decoration: const InputDecoration(labelText: 'Language'),
              items: [
                for (final language in captionLanguages)
                  DropdownMenuItem(
                    value: language,
                    enabled: language.toLowerCase() !=
                        widget.currentLanguage.toLowerCase(),
                    child: Text(language),
                  ),
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
            onPressed: _canGenerate
                ? () => Navigator.pop(context, _targetLanguage)
                : null,
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
    final wordGroups = captionWordGroups(segment.words);
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
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Wrap(
          spacing: AppSpacing.xs,
          runSpacing: 0,
          children: [
            TextButton.icon(
              onPressed: onEditTiming,
              icon: const Icon(Icons.schedule, size: 17),
              label: const Text('Timing'),
            ),
            TextButton.icon(
              onPressed: canSplit ? onSplit : null,
              icon: const Icon(Icons.call_split, size: 17),
              label: const Text('Split'),
            ),
            TextButton.icon(
              onPressed: canMergeNext ? onMerge : null,
              icon: const Icon(Icons.call_merge, size: 17),
              label: const Text('Merge'),
            ),
            TextButton.icon(
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline, size: 17),
              label: const Text('Delete'),
            ),
          ],
        ),
        if (segment.words.isEmpty)
          // No word-level data: edit the whole line instead.
          InkWell(
              onTap: onEditSegment,
              child: Text(segment.text, style: theme.textTheme.bodyLarge))
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final group in wordGroups)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (final w in group)
                        GestureDetector(
                  onTap: () => onTapWord(w),
                  onLongPress: () => onLongPressWord(w),
                  onDoubleTap: () => onLongPressWord(w),
                  child: Tooltip(
                    message: 'Context weight: ${segment.words[w].weight}/100',
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
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            segment.words[w].text,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: segment.words[w].style == WordStyle.normal
                                  ? FontWeight.w400
                                  : FontWeight.w700,
                            ),
                          ),
                          Text(
                            '${segment.words[w].weight}/100',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      if (segment.words[w].emoji != null) ...[
                        const SizedBox(width: 4),
                        Text(segment.words[w].emoji!),
                      ],
                      IconButton(
                        tooltip: 'Edit word text',
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints.tightFor(
                            width: 30, height: 30),
                        padding: EdgeInsets.zero,
                        iconSize: 15,
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => onLongPressWord(w),
                      ),
                      PopupMenuButton<String>(
                        tooltip: 'Add or remove emoji',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 48),
                        iconSize: 16,
                        icon: const Icon(Icons.add_reaction_outlined),
                        onSelected: (value) async {
                          if (value == '__custom__') {
                            final controller = TextEditingController(
                                text: segment.words[w].emoji ?? '');
                            final emoji = await showDialog<String>(
                              context: context,
                              builder: (dialogContext) => AlertDialog(
                                title: const Text('Add an emoji'),
                                content: TextField(
                                  controller: controller,
                                  autofocus: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Emoji',
                                    hintText: 'Type or paste any emoji',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(dialogContext),
                                    child: const Text('Cancel'),
                                  ),
                                  FilledButton(
                                    onPressed: () => Navigator.pop(
                                        dialogContext, controller.text.trim()),
                                    child: const Text('Apply'),
                                  ),
                                ],
                              ),
                            );
                            controller.dispose();
                            if (emoji != null && emoji.isNotEmpty) {
                              onSetEmoji(w, emoji);
                            }
                          } else {
                            onSetEmoji(
                                w, value == '__remove__' ? null : value);
                          }
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: '__custom__',
                            child: Text('Type or paste an emoji…'),
                          ),
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
                    // Word importance is also used to group words into short
                    // caption lines in the preview and downloaded video.
                    ),
                  ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

class _EditorSectionHeading extends StatelessWidget {
  const _EditorSectionHeading({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(subtitle, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
