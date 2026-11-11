import 'dart:math' as math;

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
import '../../widgets/caption_style_card.dart';
import '../../widgets/color_field.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/error_message.dart';
import '../../widgets/processing_progress.dart';

const _editorAccent = Color(0xFF7438F5);
const _editorAccentSoft = Color(0xFFF0E9FF);
const _editorCanvas = Color(0xFFF7F7FB);
const _editorBorder = Color(0xFFE3E4ED);
const _editorMuted = Color(0xFF73758B);

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
  int? _selectedSegmentIndex;
  final Map<int, (double, double)> _timelineTrimPreviews = {};
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
            hintText: 'Type your caption.',
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
        (transcript.activeTrack == 'source' ? transcript.language : 'English');
    final language = await showDialog<String>(
      context: context,
      builder: (_) => _CaptionLanguageDialog(
        currentLanguage: sourceLanguage,
        targetLanguage: transcript.translationTrack?.language,
      ),
    );
    if (language == null || !context.mounted) return;
    final savedMatches = transcript.translationTracks
        .where(
            (track) => track.language.toLowerCase() == language.toLowerCase())
        .toList();
    if (savedMatches.isNotEmpty) {
      notifier.selectCaptionTrack(
        'translation',
        language: savedMatches.first.language,
      );
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:
            Text('Showing saved ${savedMatches.first.language} translation.'),
      ));
      return;
    }
    final changed = await notifier.translateTo(language);
    if (changed) notifier.selectCaptionTrack('translation');
    if (!context.mounted) return;
    final error =
        ref.read(captionEditorProvider(widget.projectId)).errorMessage;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(changed
          ? 'Translation generated in $language and selected for preview. Download the video to render it with your captions.'
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
    final error =
        ref.read(captionEditorProvider(widget.projectId)).errorMessage;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(changed
          ? 'Translation generated in $language and selected for preview. Download the video to render it with your captions.'
          : error ?? 'Could not generate translation.'),
    ));
  }

  Future<void> _changeCaptionScript(
    CaptionEditorNotifier notifier,
    String script,
  ) async {
    final changed = await notifier.setCaptionScript(script);
    if (!mounted) return;
    final error =
        ref.read(captionEditorProvider(widget.projectId)).errorMessage;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(changed
          ? 'Caption text script changed. The spoken words and translations are unchanged. Download the video to render the updated captions.'
          : error ?? 'Could not change the caption text script.'),
    ));
  }

  Future<void> _renderAgain({bool downloadWhenDone = false}) async {
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
          if (result?.isCompleted == true && downloadWhenDone) {
            await _openMatchingExport();
          } else if (!downloadWhenDone || result?.isCompleted != true) {
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
        }
      } else {
        final msg =
            ref.read(captionEditorProvider(widget.projectId)).errorMessage;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text(msg ?? 'Could not start video rendering. Please try again.'),
        ));
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
        await _renderAgain(downloadWhenDone: true);
        return;
      }

      final exportId = await ref
          .read(captionEditorProvider(widget.projectId).notifier)
          .matchingExportId();
      if (!mounted) return;
      if (exportId == null) {
        await _renderAgain(downloadWhenDone: true);
        return;
      }
      await _openExportDownload(exportId);
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

  Future<void> _saveDraft() async {
    final saved =
        await ref.read(captionEditorProvider(widget.projectId).notifier).save();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(saved
          ? 'Draft saved. Your video has not been rendered.'
          : ref.read(captionEditorProvider(widget.projectId)).errorMessage ??
              'Could not save your draft.'),
    ));
  }

  Future<void> _openMatchingExport() async {
    final exportId = await ref
        .read(captionEditorProvider(widget.projectId).notifier)
        .matchingExportId();
    if (!mounted) return;
    if (exportId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The edited video is not ready yet.')),
      );
      return;
    }
    await _openExportDownload(exportId);
  }

  Future<void> _openExportDownload(String exportId) async {
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

    final screenWidth = MediaQuery.of(context).size.width;
    final wide = screenWidth >= 1280;
    final compactHeader = screenWidth < 600;
    void selectSegment(int index) {
      if (index < 0 || index >= state.transcript!.segments.length) return;
      final start = state.transcript!.segments[index].start;
      setState(() {
        _selectedSegmentIndex = index;
        _positionSeconds = start;
      });
      _video?.seekTo(Duration(milliseconds: (start * 1000).round()));
    }

    _VideoPane videoPane(double availableHeight, {bool compact = false}) =>
        _VideoPane(
          controller: _video,
          transcript: state.transcript!,
          positionSeconds: _positionSeconds,
          presetId: state.stylePreset,
          overrides: state.styleOverrides,
          videoFormat: state.videoFormat,
          onVideoFormatChanged: notifier.setVideoFormat,
          availableHeight: availableHeight,
          compact: compact,
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
        );
    final controls = _ControlsPane(
      projectId: widget.projectId,
      state: state,
      currentTime: _positionSeconds,
      selectedSegmentIndex: _selectedSegmentIndex,
      onSelectSegment: selectSegment,
      onEditWord: _editWord,
      onEditTiming: _editTiming,
      onRequestTranslation: _requestCaptionTranslation,
      onTranslateTo: _translateCaptionTo,
      onChangeCaptionScript: _changeCaptionScript,
      bottomTabs: !wide,
    );

    final baseTheme = Theme.of(context);
    final editorTheme = baseTheme.copyWith(
      brightness: Brightness.light,
      scaffoldBackgroundColor: _editorCanvas,
      colorScheme: baseTheme.colorScheme.copyWith(
        brightness: Brightness.light,
        primary: _editorAccent,
        secondary: _editorAccent,
        surface: Colors.white,
        onSurface: const Color(0xFF15151D),
      ),
      textTheme: baseTheme.textTheme.apply(
        bodyColor: const Color(0xFF15151D),
        displayColor: const Color(0xFF15151D),
      ),
      cardTheme: baseTheme.cardTheme.copyWith(
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: _editorBorder),
        ),
      ),
      inputDecorationTheme: baseTheme.inputDecorationTheme.copyWith(
        fillColor: Colors.white,
        enabledBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: _editorBorder),
        ),
      ),
      appBarTheme: baseTheme.appBarTheme.copyWith(
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF15151D),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
    );

    return Theme(
      data: editorTheme,
      child: PopScope(
        canPop: !state.hasUnsavedChanges,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          if (await _confirmLeave(state.hasUnsavedChanges) && context.mounted)
            context.go('/dashboard');
        },
        child: Scaffold(
          drawer: wide
              ? null
              : Drawer(
                  width: math.min(screenWidth * 0.84, 310).toDouble(),
                  child: SafeArea(
                    child: _EditorNavigation(
                      selected: 'editor',
                      extended: true,
                      onNavigate: (path) async {
                        Navigator.of(context).pop();
                        if (await _confirmLeave(state.hasUnsavedChanges) &&
                            context.mounted) context.go(path);
                      },
                    ),
                  ),
                ),
          appBar: AppBar(
            toolbarHeight: compactHeader ? 58 : 64,
            title: Row(
              children: [
                Container(
                  width: compactHeader ? 34 : 38,
                  height: compactHeader ? 34 : 38,
                  decoration: BoxDecoration(
                    color: _editorAccent,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: const Icon(Icons.play_arrow_rounded,
                      color: Colors.white, size: 27),
                ),
                SizedBox(width: compactHeader ? 8 : 12),
                const Text('Caption Studio',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ],
            ),
            leading: Builder(
              builder: (scaffoldContext) => IconButton(
                tooltip: wide ? 'Back to projects' : 'Open navigation',
                icon: Icon(wide ? Icons.arrow_back : Icons.menu_rounded),
                onPressed: wide
                    ? () async {
                        if (await _confirmLeave(state.hasUnsavedChanges) &&
                            context.mounted) context.go('/dashboard');
                      }
                    : () => Scaffold.of(scaffoldContext).openDrawer(),
              ),
            ),
            actions: [
              if (wide) ...[
                Container(
                  margin: const EdgeInsets.only(right: 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: _editorAccentSoft,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.auto_awesome_rounded,
                          size: 17, color: _editorAccent),
                      SizedBox(width: 7),
                      Text('Captions ready',
                          style: TextStyle(
                              color: _editorAccent,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
                OutlinedButton.icon(
                  onPressed:
                      _isDownloading || _isSaveRenderBusy || state.isSaving
                          ? null
                          : _saveDraft,
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: const Text('Save Draft'),
                ),
                const SizedBox(width: 10),
              ],
              if (wide || !compactHeader) ...[
                IconButton(
                  tooltip: 'Undo',
                  onPressed: state.canUndo
                      ? ref
                          .read(
                              captionEditorProvider(widget.projectId).notifier)
                          .undo
                      : null,
                  icon: const Icon(Icons.undo_rounded),
                ),
                IconButton(
                  tooltip: 'Redo',
                  onPressed: state.canRedo
                      ? ref
                          .read(
                              captionEditorProvider(widget.projectId).notifier)
                          .redo
                      : null,
                  icon: const Icon(Icons.redo_rounded),
                ),
              ] else
                PopupMenuButton<String>(
                  tooltip: 'More editor actions',
                  onSelected: (action) {
                    if (action == 'save') _saveDraft();
                    if (action == 'undo') {
                      ref
                          .read(
                              captionEditorProvider(widget.projectId).notifier)
                          .undo();
                    }
                    if (action == 'redo') {
                      ref
                          .read(
                              captionEditorProvider(widget.projectId).notifier)
                          .redo();
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                        value: 'save', child: Text('Save draft')),
                    PopupMenuItem(
                      value: 'undo',
                      enabled: state.canUndo,
                      child: const Text('Undo'),
                    ),
                    PopupMenuItem(
                      value: 'redo',
                      enabled: state.canRedo,
                      child: const Text('Redo'),
                    ),
                  ],
                ),
              Padding(
                padding: EdgeInsets.only(right: compactHeader ? 8 : 12),
                child: compactHeader
                    ? IconButton.filled(
                        tooltip: 'Download video',
                        style: IconButton.styleFrom(
                          backgroundColor: _editorAccent,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: _isDownloading ||
                                _isSaveRenderBusy ||
                                state.isSaving
                            ? null
                            : _downloadLatest,
                        icon: _isDownloading
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.download_rounded, size: 19),
                      )
                    : FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: _editorAccent,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 13),
                        ),
                        onPressed: _isDownloading ||
                                _isSaveRenderBusy ||
                                state.isSaving
                            ? null
                            : _downloadLatest,
                        icon: _isDownloading
                            ? const SizedBox.square(
                                dimension: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.download_rounded, size: 19),
                        label: Text(wide ? 'Download Video' : 'Download'),
                      ),
              ),
            ],
          ),
          body: LayoutBuilder(
            builder: (context, constraints) => wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _EditorNavigation(
                        selected: 'editor',
                        extended: screenWidth >= 1600,
                        onNavigate: (path) async {
                          if (await _confirmLeave(state.hasUnsavedChanges) &&
                              context.mounted) context.go(path);
                        },
                      ),
                      const VerticalDivider(width: 1, color: _editorBorder),
                      SizedBox(
                        width: screenWidth >= 1500 ? 320 : 285,
                        child: _EditorMediaPanel(
                          transcript: state.transcript!,
                          selectedIndex: _selectedSegmentIndex,
                          positionSeconds: _positionSeconds,
                          videoFormat: state.videoFormat,
                          durationSeconds: _video?.value.isInitialized == true
                              ? _video!.value.duration.inMilliseconds / 1000
                              : null,
                          onSelectSegment: selectSegment,
                          onEditSegment: (index, text) =>
                              _editWord(index, -1, text),
                        ),
                      ),
                      const VerticalDivider(width: 1, color: _editorBorder),
                      Expanded(
                        child: Column(
                          children: [
                            Expanded(
                              child: Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(18, 14, 18, 8),
                                child: LayoutBuilder(
                                  builder: (context, paneConstraints) =>
                                      videoPane(paneConstraints.maxHeight),
                                ),
                              ),
                            ),
                            SizedBox(
                              height: (constraints.maxHeight * 0.31)
                                  .clamp(225.0, 285.0)
                                  .toDouble(),
                              child: Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(12, 0, 12, 12),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(14),
                                  child: _DesktopEditorTimeline(
                                    transcript: state.transcript!,
                                    positionSeconds: _positionSeconds,
                                    selectedSegmentIndex: _selectedSegmentIndex,
                                    trimPreviews: _timelineTrimPreviews,
                                    durationSeconds:
                                        _video?.value.isInitialized == true
                                            ? _video!.value.duration
                                                    .inMilliseconds /
                                                1000
                                            : null,
                                    isPlaying: _video?.value.isPlaying ?? false,
                                    onSeek: (seconds) => _video?.seekTo(
                                        Duration(
                                            milliseconds:
                                                (seconds * 1000).round())),
                                    onSelectSegment: selectSegment,
                                    onEditSegment: (index) => _editWord(
                                      index,
                                      -1,
                                      state.transcript!.segments[index].text,
                                    ),
                                    onTrimPreview: (index, start, end) =>
                                        setState(() {
                                      _timelineTrimPreviews[index] =
                                          (start, end);
                                    }),
                                    onTrimSegment: (index, start, end) {
                                      notifier.updateSegmentTiming(
                                          index, start, end);
                                      setState(() =>
                                          _timelineTrimPreviews.remove(index));
                                    },
                                    onTogglePlayback: () {
                                      final video = _video;
                                      if (video == null ||
                                          !video.value.isInitialized) return;
                                      video.value.isPlaying
                                          ? video.pause()
                                          : video.play();
                                    },
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const VerticalDivider(width: 1, color: _editorBorder),
                      SizedBox(
                        width: screenWidth >= 1500 ? 400 : 365,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(8, 10, 12, 10),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(15),
                            child: Material(
                              color: Colors.white,
                              child: Container(
                                decoration: BoxDecoration(
                                  border: Border.all(color: _editorBorder),
                                  borderRadius: BorderRadius.circular(15),
                                ),
                                child: controls,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  )
                : Column(
                    children: [
                      Expanded(
                        flex: 6,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                          child: LayoutBuilder(
                            builder: (context, paneConstraints) => videoPane(
                              paneConstraints.maxHeight,
                              compact: true,
                            ),
                          ),
                        ),
                      ),
                      _MobileCaptionTimeline(
                        transcript: state.transcript!,
                        positionSeconds: _positionSeconds,
                        durationSeconds: _video?.value.isInitialized == true
                            ? _video!.value.duration.inMilliseconds / 1000
                            : null,
                        isPlaying: _video?.value.isPlaying ?? false,
                        onSeek: (seconds) => _video?.seekTo(
                            Duration(milliseconds: (seconds * 1000).round())),
                        onEditSegment: (index) => _editWord(
                          index,
                          -1,
                          state.transcript!.segments[index].text,
                        ),
                        onTogglePlayback: () {
                          final video = _video;
                          if (video == null || !video.value.isInitialized)
                            return;
                          video.value.isPlaying ? video.pause() : video.play();
                        },
                      ),
                      Expanded(
                          flex: 5,
                          child: SafeArea(top: false, child: controls)),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _EditorNavigation extends StatelessWidget {
  const _EditorNavigation({
    required this.selected,
    required this.extended,
    required this.onNavigate,
  });

  final String selected;
  final bool extended;
  final ValueChanged<String> onNavigate;

  @override
  Widget build(BuildContext context) {
    final destinations = [
      ('projects', 'Projects', Icons.folder_outlined, '/dashboard'),
      ('upload', 'New video', Icons.add_circle_outline_rounded, '/upload'),
      ('editor', 'Caption editor', Icons.closed_caption_rounded, null),
    ];
    final secondary = [
      ('settings', 'Settings', Icons.settings_outlined, '/settings'),
      ('profile', 'Account', Icons.person_outline_rounded, '/profile'),
      ('help', 'Help center', Icons.help_outline_rounded, '/help'),
    ];

    Widget navItem((String, String, IconData, String?) item) {
      final (id, label, icon, path) = item;
      final isSelected = selected == id;
      return Padding(
        padding: EdgeInsets.symmetric(
          horizontal: extended ? 12 : 8,
          vertical: 3,
        ),
        child: Tooltip(
          message: label,
          child: Material(
            color: isSelected ? _editorAccentSoft : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: isSelected || path == null ? null : () => onNavigate(path),
              child: SizedBox(
                height: 46,
                child: Row(
                  mainAxisAlignment: extended
                      ? MainAxisAlignment.start
                      : MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: extended ? 44 : 48,
                      child: Icon(
                        icon,
                        size: 21,
                        color: isSelected ? _editorAccent : _editorMuted,
                      ),
                    ),
                    if (extended) ...[
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isSelected
                                ? _editorAccent
                                : const Color(0xFF373747),
                            fontSize: 14,
                            fontWeight:
                                isSelected ? FontWeight.w700 : FontWeight.w500,
                          ),
                        ),
                      ),
                      if (isSelected)
                        Container(
                          width: 4,
                          height: 20,
                          margin: const EdgeInsets.only(right: 10),
                          decoration: BoxDecoration(
                            color: _editorAccent,
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      width: extended ? 224 : 68,
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(extended ? 18 : 0, 20, 12, 20),
            child: Row(
              mainAxisAlignment:
                  extended ? MainAxisAlignment.start : MainAxisAlignment.center,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: _editorAccentSoft,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.graphic_eq_rounded,
                      color: _editorAccent, size: 20),
                ),
                if (extended) ...[
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'WORKSPACE',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _editorMuted,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (extended)
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 16, 10),
              child: Text(
                'PROJECT',
                style: TextStyle(
                  color: _editorMuted,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
            ),
          for (final item in destinations) navItem(item),
          const Spacer(),
          if (extended)
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 16, 10),
              child: Text(
                'PREFERENCES',
                style: TextStyle(
                  color: _editorMuted,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
            ),
          for (final item in secondary) navItem(item),
          SizedBox(height: extended ? 16 : 12),
        ],
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
    required this.onVideoFormatChanged,
    required this.availableHeight,
    this.compact = false,
    required this.onTransformChanged,
  });

  final VideoPlayerController? controller;
  final CaptionTranscript transcript;
  final double positionSeconds;
  final String presetId;
  final StyleOverrides overrides;
  final String videoFormat;
  final ValueChanged<String> onVideoFormatChanged;
  final double availableHeight;
  final bool compact;
  final void Function(double x, double y, double scale, double rotationDegrees)
      onTransformChanged;
  @override
  Widget build(BuildContext context) {
    final c = controller;
    final ready = c != null && c.value.isInitialized;
    final frameAspectRatio = switch (videoFormat) {
      '1:1' => 1.0,
      '4:5' => 4 / 5,
      '16:9' => 16 / 9,
      'original' => ready ? c.value.aspectRatio : 9 / 16,
      _ => 9 / 16,
    };
    final maxFrameHeight = (availableHeight - (compact ? 8 : 58))
        .clamp(compact ? 120.0 : 180.0, 720.0)
        .toDouble();
    final maxFrameWidth = maxFrameHeight * frameAspectRatio;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxWidth: maxFrameWidth, maxHeight: maxFrameHeight),
            child: AspectRatio(
              // Match the selected export ratio while containing the source frame.
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
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (ready && !compact)
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
              Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 9),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: const Color(0xFFD8D9E6)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: videoFormat,
                    isDense: true,
                    icon: const Icon(Icons.keyboard_arrow_down, size: 18),
                    style: const TextStyle(
                      color: Color(0xFF171728),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                    selectedItemBuilder: (context) => [
                      for (final entry in kVideoFormatLabels.entries)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                              entry.key == 'original' ? 'Original' : entry.key),
                        ),
                    ],
                    items: [
                      for (final entry in kVideoFormatLabels.entries)
                        DropdownMenuItem(
                          value: entry.key,
                          child: Text(entry.value),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) onVideoFormatChanged(value);
                    },
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
      ],
    );
  }
}

class _MobileCaptionTimeline extends StatelessWidget {
  const _MobileCaptionTimeline({
    required this.transcript,
    required this.positionSeconds,
    required this.durationSeconds,
    required this.isPlaying,
    required this.onSeek,
    required this.onEditSegment,
    required this.onTogglePlayback,
  });

  final CaptionTranscript transcript;
  final double positionSeconds;
  final double? durationSeconds;
  final bool isPlaying;
  final ValueChanged<double> onSeek;
  final ValueChanged<int> onEditSegment;
  final VoidCallback onTogglePlayback;

  @override
  Widget build(BuildContext context) {
    final inferredDuration = transcript.segments.fold<double>(
      1,
      (value, segment) => segment.end > value ? segment.end : value,
    );
    final duration = durationSeconds != null && durationSeconds! > 0
        ? durationSeconds!
        : inferredDuration;
    final activeSegment = transcript.segments.where((segment) =>
        positionSeconds >= segment.start && positionSeconds < segment.end);
    final activeText = activeSegment.isEmpty ? null : activeSegment.first.text;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _editorBorder),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                tooltip: isPlaying ? 'Pause video' : 'Play video',
                visualDensity: VisualDensity.compact,
                onPressed: onTogglePlayback,
                icon: Icon(
                    isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: const Color(0xFF242536),
                    size: 24),
              ),
              const SizedBox(width: 4),
              Text(_formatEditorTime(positionSeconds),
                  style: const TextStyle(
                      color: const Color(0xFF242536),
                      fontSize: 12,
                      fontFeatures: [FontFeature.tabularFigures()])),
              const SizedBox(width: 5),
              Text('/ ${_formatEditorTime(duration)}',
                  style: const TextStyle(color: _editorMuted, fontSize: 12)),
              const Spacer(),
              if (activeText != null)
                Flexible(
                  child: Text(
                    activeText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style:
                        const TextStyle(color: Color(0xFFBDBDC5), fontSize: 11),
                  ),
                ),
            ],
          ),
          SizedBox(
            height: 42,
            child: LayoutBuilder(
              builder: (context, constraints) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) => onSeek(
                    (details.localPosition.dx / constraints.maxWidth * duration)
                        .clamp(0.0, duration)
                        .toDouble()),
                onDoubleTapDown: (details) {
                  final time = (details.localPosition.dx /
                          constraints.maxWidth *
                          duration)
                      .clamp(0.0, duration)
                      .toDouble();
                  var nearestIndex = 0;
                  var nearestDistance = double.infinity;
                  for (var i = 0; i < transcript.segments.length; i++) {
                    final segment = transcript.segments[i];
                    final distance = time < segment.start
                        ? segment.start - time
                        : time > segment.end
                            ? time - segment.end
                            : 0.0;
                    if (distance < nearestDistance) {
                      nearestIndex = i;
                      nearestDistance = distance;
                    }
                  }
                  if (transcript.segments.isNotEmpty) {
                    onEditSegment(nearestIndex);
                  }
                },
                onHorizontalDragUpdate: (details) => onSeek(
                    (details.localPosition.dx / constraints.maxWidth * duration)
                        .clamp(0.0, duration)
                        .toDouble()),
                child: CustomPaint(
                  size: Size.infinite,
                  painter: _CaptionTimelinePainter(
                    segments: transcript.segments,
                    duration: duration,
                    position: positionSeconds,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatEditorTime(double seconds) {
  final totalMs = (seconds * 1000).round().clamp(0, 359999999);
  final minutes = totalMs ~/ 60000;
  final secs = (totalMs ~/ 1000) % 60;
  final centiseconds = (totalMs % 1000) ~/ 10;
  return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}.${centiseconds.toString().padLeft(2, '0')}';
}

class _CaptionTimelinePainter extends CustomPainter {
  const _CaptionTimelinePainter({
    required this.segments,
    required this.duration,
    required this.position,
  });

  final List<CaptionSegment> segments;
  final double duration;
  final double position;

  @override
  void paint(Canvas canvas, Size size) {
    const top = 8.0;
    const height = 25.0;
    final track = RRect.fromRectAndRadius(
        Rect.fromLTWH(0, top, size.width, height), const Radius.circular(7));
    canvas.drawRRect(track, Paint()..color = const Color(0xFF29292D));

    for (final segment in segments) {
      final left = (segment.start / duration * size.width)
          .clamp(0.0, size.width)
          .toDouble();
      final right = (segment.end / duration * size.width)
          .clamp(left, size.width)
          .toDouble();
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTRB(left, top + 3, right, top + height - 3),
        const Radius.circular(4),
      );
      final active = position >= segment.start && position < segment.end;
      canvas.drawRRect(
        rect,
        Paint()..color = active ? _editorAccent : const Color(0xFFDAD4E8),
      );
    }

    final tickPaint = Paint()
      ..color = const Color(0xFF727279)
      ..strokeWidth = 1;
    final secondCount = duration.ceil();
    final tickStep = secondCount > 60
        ? 10
        : secondCount > 25
            ? 5
            : 1;
    for (var second = 0; second <= secondCount; second += tickStep) {
      final x = second / duration * size.width;
      canvas.drawLine(
          Offset(x, 0), Offset(x, second % 10 == 0 ? 6 : 4), tickPaint);
    }

    final x =
        (position / duration * size.width).clamp(0.0, size.width).toDouble();
    final playhead = Paint()
      ..color = const Color(0xFFE8FFF8)
      ..strokeWidth = 2;
    canvas.drawLine(Offset(x, 0), Offset(x, top + height + 2), playhead);
    canvas.drawCircle(
        Offset(x, 2), 4, Paint()..color = const Color(0xFFE8FFF8));
  }

  @override
  bool shouldRepaint(covariant _CaptionTimelinePainter oldDelegate) =>
      oldDelegate.position != position ||
      oldDelegate.duration != duration ||
      oldDelegate.segments != segments;
}

class _EditorMediaPanel extends StatefulWidget {
  const _EditorMediaPanel({
    required this.transcript,
    required this.selectedIndex,
    required this.positionSeconds,
    required this.videoFormat,
    required this.durationSeconds,
    required this.onSelectSegment,
    required this.onEditSegment,
  });

  final CaptionTranscript transcript;
  final int? selectedIndex;
  final double positionSeconds;
  final String videoFormat;
  final double? durationSeconds;
  final ValueChanged<int> onSelectSegment;
  final void Function(int index, String text) onEditSegment;

  @override
  State<_EditorMediaPanel> createState() => _EditorMediaPanelState();
}

class _EditorMediaPanelState extends State<_EditorMediaPanel> {
  final _search = TextEditingController();
  bool _showSource = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final transcript = widget.transcript;
    final segments = _showSource
        ? (transcript.sourceTrack?.segments ?? transcript.segments)
        : transcript.segments;
    final query = _search.text.trim().toLowerCase();
    final visibleIndices = [
      for (var i = 0; i < segments.length; i++)
        if (query.isEmpty || segments[i].text.toLowerCase().contains(query)) i,
    ];
    final ratioLabel = widget.videoFormat == 'original'
        ? 'Original format'
        : widget.videoFormat;
    return Container(
      color: const Color(0xFFFAFAFD),
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: _editorBorder),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 58,
                  decoration: BoxDecoration(
                    color: const Color(0xFFECE8F4),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: const Icon(Icons.movie_creation_outlined,
                      color: _editorAccent, size: 25),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Uploaded video',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 5),
                      Text(
                        '${widget.durationSeconds == null ? 'Video' : _formatEditorTime(widget.durationSeconds!)}  ·  $ratioLabel',
                        style: const TextStyle(
                            fontSize: 10.5, color: _editorMuted),
                      ),
                      const SizedBox(height: 3),
                      Text('${transcript.segments.length} caption lines',
                          style: const TextStyle(
                              fontSize: 10.5, color: _editorMuted)),
                    ],
                  ),
                ),
                const Icon(Icons.more_horiz_rounded,
                    size: 20, color: _editorMuted),
              ],
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => context.go('/upload'),
            icon: const Icon(Icons.cloud_upload_outlined, size: 18),
            label: const Text('Upload another video'),
            style: OutlinedButton.styleFrom(
              foregroundColor: _editorAccent,
              side: const BorderSide(color: _editorBorder),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(vertical: 13),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: _editorBorder),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 9, 10, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: _MediaTab(
                            label: 'Transcript',
                            selected: _showSource,
                            onTap: () => setState(() => _showSource = true),
                          ),
                        ),
                        Expanded(
                          child: _MediaTab(
                            label: 'Captions',
                            selected: !_showSource,
                            onTap: () => setState(() => _showSource = false),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(10),
                    child: TextField(
                      controller: _search,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        hintText: 'Search in transcript...',
                        prefixIcon: const Icon(Icons.search_rounded, size: 19),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 11),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(9)),
                      ),
                    ),
                  ),
                  Expanded(
                    child: visibleIndices.isEmpty
                        ? const Center(
                            child: Text('No matching captions',
                                style: TextStyle(color: _editorMuted)))
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(9, 0, 9, 10),
                            itemCount: visibleIndices.length,
                            separatorBuilder: (_, __) => const Divider(
                                height: 1, indent: 8, endIndent: 8),
                            itemBuilder: (context, itemIndex) {
                              final index = visibleIndices[itemIndex];
                              final segment = segments[index];
                              final selected = widget.selectedIndex == index ||
                                  (widget.selectedIndex == null &&
                                      widget.positionSeconds >= segment.start &&
                                      widget.positionSeconds < segment.end);
                              return InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onTap: () => widget.onSelectSegment(index),
                                onDoubleTap: () {
                                  if (!_showSource ||
                                      transcript.activeTrack == 'source') {
                                    widget.onEditSegment(index, segment.text);
                                  }
                                },
                                child: Container(
                                  padding:
                                      const EdgeInsets.fromLTRB(8, 9, 7, 9),
                                  decoration: BoxDecoration(
                                    color: selected
                                        ? _editorAccentSoft
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      SizedBox(
                                        width: 72,
                                        child: Text(
                                          '${_formatEditorTime(segment.start)} – ${_formatEditorTime(segment.end)}',
                                          style: const TextStyle(
                                              color: _editorMuted,
                                              fontSize: 10),
                                        ),
                                      ),
                                      Expanded(
                                        child: Text(
                                          segment.text,
                                          maxLines: 3,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11.5,
                                            height: 1.35,
                                            fontWeight: selected
                                                ? FontWeight.w600
                                                : FontWeight.w400,
                                          ),
                                        ),
                                      ),
                                      if (selected)
                                        const Icon(Icons.more_vert_rounded,
                                            size: 17, color: _editorMuted),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MediaTab extends StatelessWidget {
  const _MediaTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? _editorAccent : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Center(
            child: Text(label,
                style: TextStyle(
                  color: selected ? _editorAccent : _editorMuted,
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                )),
          ),
        ),
      );
}

class _DesktopEditorTimeline extends StatelessWidget {
  const _DesktopEditorTimeline({
    required this.transcript,
    required this.positionSeconds,
    required this.selectedSegmentIndex,
    required this.trimPreviews,
    required this.durationSeconds,
    required this.isPlaying,
    required this.onSeek,
    required this.onSelectSegment,
    required this.onEditSegment,
    required this.onTrimPreview,
    required this.onTrimSegment,
    required this.onTogglePlayback,
  });

  final CaptionTranscript transcript;
  final double positionSeconds;
  final int? selectedSegmentIndex;
  final Map<int, (double, double)> trimPreviews;
  final double? durationSeconds;
  final bool isPlaying;
  final ValueChanged<double> onSeek;
  final ValueChanged<int> onSelectSegment;
  final ValueChanged<int> onEditSegment;
  final void Function(int index, double start, double end) onTrimPreview;
  final void Function(int index, double start, double end) onTrimSegment;
  final VoidCallback onTogglePlayback;

  @override
  Widget build(BuildContext context) {
    final duration = durationSeconds != null && durationSeconds! > 0
        ? durationSeconds!
        : transcript.segments.fold<double>(
            1, (value, segment) => value > segment.end ? value : segment.end);
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: _editorBorder)),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 46,
            child: Row(
              children: [
                IconButton(
                  tooltip: isPlaying ? 'Pause' : 'Play',
                  onPressed: onTogglePlayback,
                  icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
                ),
                IconButton(
                    tooltip: 'Jump to start',
                    onPressed: () => onSeek(0),
                    icon: const Icon(Icons.skip_previous, size: 19)),
                const SizedBox(width: 8),
                Text(
                    '${_formatEditorTime(positionSeconds)}  /  ${_formatEditorTime(duration)}',
                    style: const TextStyle(
                      color: Color(0xFF55576D),
                      fontSize: 11,
                      fontFeatures: [FontFeature.tabularFigures()],
                    )),
                const Spacer(),
                Text('${transcript.segments.length} captions',
                    style: const TextStyle(color: _editorMuted, fontSize: 11)),
                const SizedBox(width: 16),
              ],
            ),
          ),
          const Divider(height: 1, color: _editorBorder),
          Expanded(
            child: Row(
              children: [
                const SizedBox(
                  width: 86,
                  child: Column(
                    children: [
                      SizedBox(height: 27),
                      _TimelineTrackLabel(
                          label: 'AUDIO',
                          icon: Icons.graphic_eq,
                          color: Color(0xFF9570E8)),
                      _TimelineTrackLabel(
                          label: 'CAPTIONS',
                          icon: Icons.closed_caption_outlined,
                          color: _editorAccent),
                    ],
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final width = constraints.maxWidth;
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapUp: (details) => onSeek(
                                (details.localPosition.dx / width * duration)
                                    .clamp(0.0, duration)
                                    .toDouble()),
                            onHorizontalDragUpdate: (details) => onSeek(
                                (details.localPosition.dx / width * duration)
                                    .clamp(0.0, duration)
                                    .toDouble()),
                            child: CustomPaint(
                              painter: _DesktopTimelinePainter(
                                duration: duration,
                                position: positionSeconds,
                              ),
                            ),
                          ),
                          for (var index = 0;
                              index < transcript.segments.length;
                              index++)
                            _buildTimelineClip(index, width, duration),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimelineClip(int index, double width, double duration) {
    final segment = transcript.segments[index];
    final preview = trimPreviews[index];
    final start = preview?.$1 ?? segment.start;
    final end = preview?.$2 ?? segment.end;
    return Positioned(
      left: (start / duration * width).clamp(0.0, width).toDouble(),
      top: 74,
      width: ((end - start) / duration * width).clamp(20.0, width).toDouble(),
      height: 36,
      child: _TimelineCaptionClip(
        segment: segment,
        maxDuration: duration,
        selected: index == selectedSegmentIndex,
        onTap: () => onSelectSegment(index),
        onDoubleTap: () => onEditSegment(index),
        onTrimPreview: (trim) => onTrimPreview(index, trim.$1, trim.$2),
        onTrim: (trim) => onTrimSegment(index, trim.$1, trim.$2),
      ),
    );
  }
}

class _TimelineCaptionClip extends StatefulWidget {
  const _TimelineCaptionClip({
    required this.segment,
    required this.maxDuration,
    required this.selected,
    required this.onTap,
    required this.onDoubleTap,
    required this.onTrimPreview,
    required this.onTrim,
  });

  final CaptionSegment segment;
  final double maxDuration;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final ValueChanged<(double, double)> onTrimPreview;
  final ValueChanged<(double, double)> onTrim;

  @override
  State<_TimelineCaptionClip> createState() => _TimelineCaptionClipState();
}

class _TimelineCaptionClipState extends State<_TimelineCaptionClip> {
  double? _initialStart;
  double? _initialEnd;
  double? _previewStart;
  double? _previewEnd;
  double _dragPixels = 0;
  double? _dragWidth;
  int _dragEdge = 0;

  void _startDrag(int edge, double width) {
    _initialStart = widget.segment.start;
    _initialEnd = widget.segment.end;
    _previewStart = widget.segment.start;
    _previewEnd = widget.segment.end;
    _dragPixels = 0;
    _dragWidth = width;
    _dragEdge = edge;
  }

  void _updateDrag(DragUpdateDetails details, double width) {
    final start = _initialStart;
    final end = _initialEnd;
    final dragWidth = _dragWidth ?? width;
    if (start == null || end == null || dragWidth <= 0) return;
    _dragPixels += details.delta.dx;
    final delta = _dragPixels / dragWidth * (end - start);
    setState(() {
      if (_dragEdge < 0) {
        _previewStart = (start + delta).clamp(0.0, end - 0.08).toDouble();
      } else {
        _previewEnd =
            (end + delta).clamp(start + 0.08, widget.maxDuration).toDouble();
      }
    });
    widget.onTrimPreview((_previewStart!, _previewEnd!));
  }

  void _endDrag() {
    final start = _previewStart;
    final end = _previewEnd;
    if (start != null && end != null) {
      widget.onTrim((start, end));
    }
    setState(() {
      _initialStart = null;
      _initialEnd = null;
      _previewStart = null;
      _previewEnd = null;
      _dragPixels = 0;
      _dragWidth = null;
      _dragEdge = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final start = _previewStart ?? widget.segment.start;
    final end = _previewEnd ?? widget.segment.end;
    final isDragging = _initialStart != null;
    return GestureDetector(
      onTap: widget.onTap,
      onDoubleTap: widget.onDoubleTap,
      child: Container(
        decoration: BoxDecoration(
          color: widget.selected ? _editorAccent : const Color(0xFFF0ECF8),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: widget.selected ? _editorAccent : const Color(0xFFE0D9EF),
          ),
        ),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(widget.segment.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: widget.selected
                            ? Colors.white
                            : const Color(0xFF343343),
                        fontSize: 10,
                        fontWeight: FontWeight.w500)),
              ),
            ),
            if (isDragging)
              Positioned(
                right: 4,
                top: 2,
                child: Text('${(end - start).toStringAsFixed(1)}s',
                    style: TextStyle(
                        color: widget.selected ? Colors.white70 : _editorMuted,
                        fontSize: 9)),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: _TrimHandle(
                edge: -1,
                selected: widget.selected,
                onDragStart: (width) => _startDrag(-1, width),
                onDragUpdate: _updateDrag,
                onDragEnd: _endDrag,
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: _TrimHandle(
                edge: 1,
                selected: widget.selected,
                onDragStart: (width) => _startDrag(1, width),
                onDragUpdate: _updateDrag,
                onDragEnd: _endDrag,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TrimHandle extends StatelessWidget {
  const _TrimHandle({
    required this.edge,
    required this.selected,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final int edge;
  final bool selected;
  final ValueChanged<double> onDragStart;
  final void Function(DragUpdateDetails, double) onDragUpdate;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (_) => onDragStart(constraints.maxWidth),
          onHorizontalDragUpdate: (details) =>
              onDragUpdate(details, constraints.maxWidth),
          onHorizontalDragEnd: (_) => onDragEnd(),
          child: Container(
            width: 12,
            height: double.infinity,
            decoration: BoxDecoration(
              color: selected
                  ? Colors.white.withValues(alpha: 0.15)
                  : _editorAccent.withValues(alpha: 0.08),
              borderRadius: BorderRadius.horizontal(
                left: edge < 0 ? const Radius.circular(5) : Radius.zero,
                right: edge > 0 ? const Radius.circular(5) : Radius.zero,
              ),
            ),
            child: Center(
              child: Container(
                width: 2,
                height: 14,
                decoration: BoxDecoration(
                    color: selected ? Colors.white : _editorAccent,
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
          ),
        ),
      );
}

class _TimelineTrackLabel extends StatelessWidget {
  const _TimelineTrackLabel({
    required this.label,
    required this.icon,
    required this.color,
  });

  final String label;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 42,
        child: Row(
          children: [
            const SizedBox(width: 9),
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(
                    color: _editorMuted,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3)),
          ],
        ),
      );
}

class _DesktopTimelinePainter extends CustomPainter {
  const _DesktopTimelinePainter({
    required this.duration,
    required this.position,
  });

  final double duration;
  final double position;

  @override
  void paint(Canvas canvas, Size size) {
    final width = size.width > 1.0 ? size.width : 1.0;
    const rulerHeight = 27.0;
    final seconds = duration.ceil();
    final step = seconds > 300
        ? 60
        : seconds > 120
            ? 30
            : seconds > 40
                ? 10
                : 5;
    final tickPaint = Paint()
      ..color = const Color(0xFFE0E1E9)
      ..strokeWidth = 1;
    final labelStyle = const TextStyle(
        color: _editorMuted,
        fontSize: 9,
        fontFeatures: [FontFeature.tabularFigures()]);
    for (var second = 0; second <= seconds; second += step) {
      final x = second / duration * width;
      canvas.drawLine(
          Offset(x, rulerHeight - 7), Offset(x, size.height), tickPaint);
      final painter = TextPainter(
        text: TextSpan(
            text: _formatEditorTime(second.toDouble()), style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(canvas, Offset(x + 3, 2));
    }

    final audioRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 32, width, 28), const Radius.circular(5));
    canvas.drawRRect(audioRect, Paint()..color = const Color(0xFFF0ECF8));
    final wavePaint = Paint()
      ..color = const Color(0xFFB7A3E5).withValues(alpha: 0.85)
      ..strokeWidth = 1;
    for (var x = 3.0; x < width; x += 4) {
      final envelope =
          4 + (math.sin(x * 0.021).abs() * 8) + (math.sin(x * 0.071).abs() * 4);
      canvas.drawLine(Offset(x, 46 - envelope / 2),
          Offset(x, 46 + envelope / 2), wavePaint);
    }

    final playheadX =
        (position / duration * width).clamp(0.0, width).toDouble();
    final playheadPaint = Paint()
      ..color = _editorAccent
      ..strokeWidth = 2;
    canvas.drawLine(
        Offset(playheadX, 0), Offset(playheadX, size.height), playheadPaint);
    final head = Path()
      ..moveTo(playheadX - 5, 0)
      ..lineTo(playheadX + 5, 0)
      ..lineTo(playheadX, 7)
      ..close();
    canvas.drawPath(head, Paint()..color = _editorAccent);
  }

  @override
  bool shouldRepaint(covariant _DesktopTimelinePainter oldDelegate) =>
      oldDelegate.position != position || oldDelegate.duration != duration;
}

class _ControlsPane extends ConsumerWidget {
  const _ControlsPane({
    required this.projectId,
    required this.state,
    required this.currentTime,
    required this.selectedSegmentIndex,
    required this.onSelectSegment,
    required this.onEditWord,
    required this.onEditTiming,
    required this.onRequestTranslation,
    required this.onTranslateTo,
    required this.onChangeCaptionScript,
    this.bottomTabs = false,
  });

  final String projectId;
  final CaptionEditorState state;
  final double currentTime;
  final int? selectedSegmentIndex;
  final ValueChanged<int> onSelectSegment;
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
  final Future<void> Function(
    CaptionEditorNotifier notifier,
    String script,
  ) onChangeCaptionScript;
  final bool bottomTabs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(captionEditorProvider(projectId).notifier);
    final theme = Theme.of(context);
    final o = state.styleOverrides;
    final currentLineIndex = selectedSegmentIndex != null &&
            selectedSegmentIndex! >= 0 &&
            selectedSegmentIndex! < state.transcript!.segments.length
        ? selectedSegmentIndex!
        : state.transcript!.segments.indexWhere(
            (segment) =>
                currentTime >= segment.start && currentTime < segment.end,
          );
    final currentLine = currentLineIndex < 0
        ? null
        : state.transcript!.segments[currentLineIndex];
    final automaticCaptionFont = currentLine == null
        ? captionFontForTranscript(state.transcript!)
        : captionFontForText(currentLine.text, state.transcript!.language);
    final activeCaptionFont = currentLine?.fontFamily == 'auto'
        ? automaticCaptionFont
        : currentLine?.fontFamily ?? o.fontFamily ?? automaticCaptionFont;
    final selectedPreset =
        presetInfoFor(currentLine?.stylePreset ?? state.stylePreset);
    final effectiveY = currentLine?.positionY ??
        o.positionY ??
        _positionY(o.position ?? _presetPosition(state.stylePreset));
    final selectedPosition = effectiveY < 0.34
        ? 'top'
        : effectiveY < 0.68
            ? 'center'
            : 'bottom';

    void updateCurrentLineTransform(
        {double? x, double? y, double? scale, double? rotation}) {
      if (currentLineIndex < 0) return;
      notifier.updateSegmentTransform(
        currentLineIndex,
        x: x ?? currentLine!.positionX ?? o.positionX ?? 0.5,
        y: y ??
            currentLine!.positionY ??
            o.positionY ??
            _positionY(o.position ?? _presetPosition(state.stylePreset)),
        scale: scale ?? currentLine!.scale ?? o.scale,
        rotationDegrees:
            rotation ?? currentLine!.rotationDegrees ?? o.rotationDegrees,
      );
    }

    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          if (!bottomTabs) const _EditorToolTabs(),
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
                          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.subtitles,
                                      color: theme.colorScheme.primary,
                                      size: 18),
                                  const SizedBox(width: 8),
                                  Text('SELECTED CAPTION',
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(
                                              letterSpacing: 0.8,
                                              fontWeight: FontWeight.w700)),
                                  const Spacer(),
                                  TextButton.icon(
                                    onPressed: () => onEditWord(
                                        currentLineIndex, -1, currentLine.text),
                                    icon: const Icon(Icons.edit_outlined,
                                        size: 16),
                                    label: const Text('Edit text'),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(currentLine.text,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium),
                              const SizedBox(height: 8),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton.icon(
                                  onPressed: () => notifier
                                      .applySegmentStyleToAll(currentLineIndex),
                                  icon: const Icon(Icons.select_all, size: 16),
                                  label: const Text('Apply style to all'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                    ],
                    _EditorSectionHeading(
                      icon: Icons.subtitles_outlined,
                      title: 'Caption templates',
                      subtitle:
                          'Choose a template for the caption line shown in the preview.',
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    CaptionTemplatePicker(
                      presets: kCaptionPresets,
                      selectedPresetId:
                          currentLine?.stylePreset ?? state.stylePreset,
                      onSelected: (presetId) => currentLineIndex >= 0
                          ? notifier.updateSegmentStyle(
                              currentLineIndex,
                              stylePreset: presetId,
                            )
                          : notifier.setPreset(presetId),
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
                      subtitle:
                          'Drag the dotted caption box in the preview to place it. Pinch to scale.',
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    DropdownButtonFormField<String>(
                      value: currentLine?.fontFamily ?? o.fontFamily ?? 'auto',
                      decoration: const InputDecoration(
                        labelText: 'Font family',
                        helperText:
                            'Automatic uses the current caption text, not the spoken-language setting.',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        DropdownMenuItem(
                            value: 'auto',
                            child: Text(
                                'Automatic · ${captionFontLabel(automaticCaptionFont)}')),
                        DropdownMenuItem(
                            value: 'Caption Sans',
                            child: Text('Noto Sans · Clean')),
                        DropdownMenuItem(
                            value: 'Caption Arabic',
                            child: Text('Noto Naskh Arabic')),
                        DropdownMenuItem(
                            value: 'Caption Urdu',
                            child: Text('Noto Nastaliq Urdu')),
                        for (final font in const [
                          'Roboto',
                          'Open Sans',
                          'Lato',
                          'Montserrat',
                          'Poppins',
                          'Inter',
                        ])
                          DropdownMenuItem(value: font, child: Text(font)),
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
                      value: (currentLine?.fontSize ?? o.fontSize ?? 44)
                          .clamp(16, 120)
                          .toDouble(),
                      label: '${currentLine?.fontSize ?? o.fontSize ?? 44}',
                      onChanged: (v) => currentLineIndex >= 0
                          ? notifier.updateSegmentStyle(currentLineIndex,
                              fontSize: v.round())
                          : notifier.setStyleOverrides(
                              o.copyWith(fontSize: v.round())),
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
                      value: o.italic ?? true,
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
                      title: const Text('Motion animations'),
                      value: currentLine?.motionEnabled ?? o.motionEnabled,
                      onChanged: (v) => currentLineIndex >= 0
                          ? notifier.updateSegmentStyle(currentLineIndex,
                              motionEnabled: v)
                          : notifier
                              .setStyleOverrides(o.copyWith(motionEnabled: v)),
                    ),
                    if (selectedPreset.id == 'liquid_glass')
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Liquid glass effect'),
                        value: o.liquidGlassEnabled,
                        onChanged: (v) => notifier.setStyleOverrides(
                            o.copyWith(liquidGlassEnabled: v)),
                      ),
                    Text('Caption scale', style: theme.textTheme.titleSmall),
                    Slider(
                      min: 0.5,
                      max: 2,
                      divisions: 30,
                      value: (currentLine?.scale ?? o.scale)
                          .clamp(0.5, 2)
                          .toDouble(),
                      label:
                          '${((currentLine?.scale ?? o.scale) * 100).round()}%',
                      onChanged: (v) => updateCurrentLineTransform(scale: v),
                    ),
                    Text('Rotation', style: theme.textTheme.titleSmall),
                    Slider(
                      min: -30,
                      max: 30,
                      divisions: 60,
                      value: (currentLine?.rotationDegrees ?? o.rotationDegrees)
                          .clamp(-30, 30)
                          .toDouble(),
                      label:
                          '${(currentLine?.rotationDegrees ?? o.rotationDegrees).round()}°',
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
                          updateCurrentLineTransform(
                              x: 0.5, y: _positionY(position));
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
                      onPressed: notifier.resetCustomizations,
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
                      final sourceTrack = state.transcript!.sourceTrack ??
                          CaptionTrack(
                            language: state.transcript!.language,
                            segments: state.transcript!.segments,
                          );
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _CaptionLanguageControl(
                            transcript: state.transcript!,
                            notifier: notifier,
                            isTranslating: state.isTranslating,
                            isChangingScript: state.isChangingScript,
                            onRequestTranslation: onRequestTranslation,
                            onTranslateTo: onTranslateTo,
                            fontFamily: activeCaptionFont,
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          DropdownButtonFormField<String>(
                            value: detectedCaptionScript(
                              sourceTrack,
                              fallback: state.transcript!.captionScript,
                            ),
                            decoration: InputDecoration(
                              labelText: state.isChangingScript
                                  ? 'Changing caption text script…'
                                  : 'Caption text script',
                              prefixIcon: const Icon(Icons.text_fields),
                              border: const OutlineInputBorder(),
                            ),
                            items: [
                              const DropdownMenuItem(
                                value: 'roman',
                                child: Text('Roman / Latin letters'),
                              ),
                              DropdownMenuItem(
                                value: 'native',
                                child: Text(
                                    'Native script (${state.transcript!.sourceTrack?.language ?? state.transcript!.language})'),
                              ),
                            ],
                            onChanged: state.isTranslating ||
                                    state.isChangingScript
                                ? null
                                : (script) {
                                    if (script != null) {
                                      onChangeCaptionScript(notifier, script);
                                    }
                                  },
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            'Changes how the original spoken words are written; it does not translate them. Translations remain separate tracks.',
                            style: theme.textTheme.bodySmall,
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
                                    Icons.record_voice_over_outlined,
                                    size: 18),
                                label: const Text('Caption text'),
                                selected:
                                    state.transcript!.activeTrack == 'source',
                                onSelected: state.isTranslating ||
                                        state.isChangingScript
                                    ? null
                                    : (_) =>
                                        notifier.selectCaptionTrack('source'),
                              ),
                              for (final translation
                                  in state.transcript!.translationTracks)
                                ChoiceChip(
                                  avatar: const Icon(Icons.translate, size: 18),
                                  label: Text(translation.language),
                                  selected: state.transcript!.activeTrack ==
                                          'translation' &&
                                      state.transcript!.language
                                              .toLowerCase() ==
                                          translation.language.toLowerCase(),
                                  onSelected: state.isTranslating ||
                                          state.isChangingScript
                                      ? null
                                      : (_) => notifier.selectCaptionTrack(
                                            'translation',
                                            language: translation.language,
                                          ),
                                ),
                              ActionChip(
                                avatar: const Icon(Icons.add, size: 18),
                                label: const Text('Add translation'),
                                onPressed: state.isTranslating ||
                                        state.isChangingScript
                                    ? null
                                    : () => onRequestTranslation(
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
                                : 'Translation is shown in the preview. Download the video to render the latest captions; the original caption text stays separate.',
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
                            'Tap a word to change its emphasis. Double-tap or use its edit icon to change the text; tap a caption line to edit it.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      );
                    }
                    final segIndex = i - 1;
                    final seg = state.transcript!.segments[segIndex];
                    return _SegmentRow(
                      segment: seg,
                      selected: currentLineIndex == segIndex,
                      onSeek: () => onSelectSegment(segIndex),
                      onTapWord: (w) {
                        onSelectSegment(segIndex);
                        notifier.cycleWordStyle(segIndex, w);
                      },
                      onLongPressWord: (w) {
                        onSelectSegment(segIndex);
                        onEditWord(segIndex, w, seg.words[w].text);
                      },
                      onEditSegment: () {
                        onSelectSegment(segIndex);
                        onEditWord(segIndex, -1, seg.text);
                      },
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
          if (bottomTabs)
            Material(
              color: Colors.white,
              child: SafeArea(
                top: false,
                minimum: const EdgeInsets.only(bottom: 2),
                child: const _EditorToolTabs(),
              ),
            ),
        ],
      ),
    );
  }
}

class _EditorToolTabs extends StatelessWidget {
  const _EditorToolTabs();

  @override
  Widget build(BuildContext context) => TabBar(
        indicatorSize: TabBarIndicatorSize.label,
        indicatorColor: _editorAccent,
        labelColor: _editorAccent,
        unselectedLabelColor: _editorMuted,
        tabs: const [
          Tab(icon: Icon(Icons.tune_rounded), text: 'Style'),
          Tab(icon: Icon(Icons.subtitles_rounded), text: 'Captions'),
        ],
      );
}

class _CaptionLanguageControl extends StatelessWidget {
  const _CaptionLanguageControl({
    required this.transcript,
    required this.notifier,
    required this.isTranslating,
    required this.isChangingScript,
    required this.onRequestTranslation,
    required this.onTranslateTo,
    required this.fontFamily,
  });

  final CaptionTranscript transcript;
  final CaptionEditorNotifier notifier;
  final bool isTranslating;
  final bool isChangingScript;
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
    final activeTrack = CaptionTrack(
      language: transcript.language,
      segments: transcript.segments,
    );
    final activeScript = detectedCaptionScript(
      activeTrack,
      fallback: transcript.captionScript,
    );
    final languageLabel = transcript.language.toLowerCase() == 'urdu'
        ? 'Urdu (${activeScript == 'roman' ? 'Roman' : 'native'} script)'
        : transcript.language;
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
            'Preview uses: ${transcript.activeTrack == 'source' ? 'Caption text' : 'Translation'} · $languageLabel',
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
                child: Text(language),
              ),
            const DropdownMenuItem(
                value: 'other', child: Text('Other language…')),
          ],
          onChanged: isTranslating || isChangingScript
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
                    final existingTrack =
                        matchingTracks.isEmpty ? null : matchingTracks.first;
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
        if (isTranslating || isChangingScript) const LinearProgressIndicator(),
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

  bool get _canGenerate => _targetLanguage.length >= 2;

  bool _isAvailable(String? language) =>
      language != null &&
      captionLanguages
          .any((item) => item.toLowerCase() == language.toLowerCase());

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
    required this.selected,
    required this.onSeek,
    required this.onTapWord,
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
  final bool selected;
  final VoidCallback onSeek;
  final void Function(int wordIndex) onTapWord;
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

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: selected ? _editorAccentSoft : null,
        borderRadius: BorderRadius.circular(10),
        border: selected
            ? Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.65))
            : null,
      ),
      child: Column(
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
                onDoubleTap: onEditSegment,
                child: Text(captionTextGroups(segment.text).join('\n'),
                    style: theme.textTheme.bodyLarge))
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
                            onDoubleTap: onEditSegment,
                            child: Tooltip(
                              message:
                                  'Context weight: ${segment.words[w].weight}/100',
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: chipColor(segment.words[w].style),
                                  borderRadius:
                                      BorderRadius.circular(AppRadius.sm),
                                  border: Border.all(
                                      color: theme.dividerTheme.color ??
                                          Colors.grey),
                                ),
                                child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            segment.words[w].text,
                                            style: theme.textTheme.bodyMedium
                                                ?.copyWith(
                                              fontWeight:
                                                  segment.words[w].style ==
                                                          WordStyle.normal
                                                      ? FontWeight.w400
                                                      : FontWeight.w700,
                                            ),
                                          ),
                                          Text(
                                            '${segment.words[w].weight}/100',
                                            style: theme.textTheme.labelSmall
                                                ?.copyWith(
                                              color: theme
                                                  .colorScheme.onSurfaceVariant,
                                            ),
                                          ),
                                        ],
                                      ),
                                      IconButton(
                                        tooltip: 'Edit word text',
                                        visualDensity: VisualDensity.compact,
                                        constraints:
                                            const BoxConstraints.tightFor(
                                                width: 30, height: 30),
                                        padding: EdgeInsets.zero,
                                        iconSize: 15,
                                        icon: const Icon(Icons.edit_outlined),
                                        onPressed: () => onLongPressWord(w),
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
      ),
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

