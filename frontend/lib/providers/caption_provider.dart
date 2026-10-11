import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_exception.dart';
import '../models/caption.dart';
import 'core_providers.dart';
import 'settings_provider.dart';

const Map<String, String> kVideoFormatLabels = {
  '9:16': '9:16  ·  Reel / TikTok',
  '1:1': '1:1  ·  Square',
  '4:5': '4:5  ·  Portrait',
  '16:9': '16:9  ·  YouTube',
  'original': 'Original video size',
};

class CaptionEditorState {
  const CaptionEditorState({
    this.transcript,
    this.stylePreset = 'classic',
    this.styleOverrides = const StyleOverrides(),
    this.videoFormat = 'original',
    this.isLoading = true,
    this.isSaving = false,
    this.isRendering = false,
    this.isTranslating = false,
    this.hasUnsavedChanges = false,
    this.hasUnrenderedChanges = false,
    this.canUndo = false,
    this.canRedo = false,
    this.errorMessage,
    this.lastRenderJobId,
  });

  final CaptionTranscript? transcript;
  final String stylePreset;
  final StyleOverrides styleOverrides;
  final String videoFormat;
  final bool isLoading;
  final bool isSaving;
  final bool isRendering;
  final bool isTranslating;
  final bool hasUnsavedChanges;
  final bool hasUnrenderedChanges;
  final bool canUndo;
  final bool canRedo;
  final String? errorMessage;
  final String? lastRenderJobId;

  CaptionEditorState copyWith({
    CaptionTranscript? transcript,
    String? stylePreset,
    StyleOverrides? styleOverrides,
    String? videoFormat,
    bool? isLoading,
    bool? isSaving,
    bool? isRendering,
    bool? isTranslating,
    bool? hasUnsavedChanges,
    bool? hasUnrenderedChanges,
    bool? canUndo,
    bool? canRedo,
    String? errorMessage,
    bool clearError = false,
    String? lastRenderJobId,
  }) =>
      CaptionEditorState(
        transcript: transcript ?? this.transcript,
        stylePreset: stylePreset ?? this.stylePreset,
        styleOverrides: styleOverrides ?? this.styleOverrides,
        videoFormat: videoFormat ?? this.videoFormat,
        isLoading: isLoading ?? this.isLoading,
        isSaving: isSaving ?? this.isSaving,
        isRendering: isRendering ?? this.isRendering,
        isTranslating: isTranslating ?? this.isTranslating,
        hasUnsavedChanges: hasUnsavedChanges ?? this.hasUnsavedChanges,
        hasUnrenderedChanges: hasUnrenderedChanges ?? this.hasUnrenderedChanges,
        canUndo: canUndo ?? this.canUndo,
        canRedo: canRedo ?? this.canRedo,
        errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
        lastRenderJobId: lastRenderJobId ?? this.lastRenderJobId,
      );
}

class CaptionEditorNotifier extends StateNotifier<CaptionEditorState> {
  CaptionEditorNotifier(this._ref, this.projectId)
      : super(const CaptionEditorState()) {
    load();
  }

  final Ref _ref;
  final String projectId;
  int _editRevision = 0;
  int? _renderRevision;
  String? _savedFingerprint;
  final List<_CaptionEditSnapshot> _undoStack = [];
  final List<_CaptionEditSnapshot> _redoStack = [];

  _CaptionEditSnapshot _snapshot() => _CaptionEditSnapshot(
        transcript: state.transcript,
        preset: state.stylePreset,
        overrides: state.styleOverrides,
        format: state.videoFormat,
      );

  void _recordEdit() {
    if (state.transcript == null) return;
    _undoStack.add(_snapshot());
    if (_undoStack.length > 100) _undoStack.removeAt(0);
    _redoStack.clear();
    state = state.copyWith(canUndo: true, canRedo: false);
  }

  void undo() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(_snapshot());
    final previous = _undoStack.removeLast();
    _editRevision++;
    state = state.copyWith(
      transcript: previous.transcript,
      stylePreset: previous.preset,
      styleOverrides: previous.overrides,
      videoFormat: previous.format,
      hasUnsavedChanges: true,
      hasUnrenderedChanges: true,
      canUndo: _undoStack.isNotEmpty,
      canRedo: true,
    );
  }

  void redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(_snapshot());
    final next = _redoStack.removeLast();
    _editRevision++;
    state = state.copyWith(
      transcript: next.transcript,
      stylePreset: next.preset,
      styleOverrides: next.overrides,
      videoFormat: next.format,
      hasUnsavedChanges: true,
      hasUnrenderedChanges: true,
      canUndo: true,
      canRedo: _redoStack.isNotEmpty,
    );
  }

  Future<void> load() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final json = await _ref
          .read(apiClientProvider)
          .get('/api/projects/$projectId/captions');
      _savedFingerprint = json['render_fingerprint'] as String?;
      state = state.copyWith(
        transcript: CaptionTranscript.fromJson(
            json['caption_data'] as Map<String, dynamic>),
        stylePreset: json['style_preset'] as String? ?? 'classic',
        styleOverrides: StyleOverrides.fromJson(
            json['style_overrides'] as Map<String, dynamic>?),
        videoFormat: json['aspect_ratio'] as String? ?? 'original',
        hasUnrenderedChanges: json['matching_export_id'] == null,
        isLoading: false,
      );
    } on ApiException catch (e) {
      state = state.copyWith(isLoading: false, errorMessage: e.message);
    }
  }

  /// Manual per-word style edit (spec: user can manually edit captions) --
  /// tapping a word in the editor cycles normal -> highlight -> emphasis.
  void cycleWordStyle(int segmentIndex, int wordIndex) {
    _editRevision++;
    final transcript = state.transcript;
    if (transcript == null) return;
    _recordEdit();
    final segments = [...transcript.segments];
    final segment = segments[segmentIndex];
    final words = [...segment.words];
    words[wordIndex] = words[wordIndex].cycleStyle();
    segments[segmentIndex] = segment.copyWith(words: words);
    state = state.copyWith(
      transcript: transcript.copyWith(segments: segments),
      hasUnsavedChanges: true,
      hasUnrenderedChanges: true,
    );
  }

  void setWordEmoji(int segmentIndex, int wordIndex, String? emoji) {
    _editRevision++;
    final transcript = state.transcript;
    if (transcript == null) return;
    _recordEdit();
    final segments = [...transcript.segments];
    final segment = segments[segmentIndex];
    final words = [...segment.words];
    words[wordIndex] = words[wordIndex].copyWith(
      emoji: emoji,
      clearEmoji: emoji == null,
    );
    segments[segmentIndex] = segment.copyWith(words: words);
    state = state.copyWith(
      transcript: transcript.copyWith(segments: segments),
      hasUnsavedChanges: true,
      hasUnrenderedChanges: true,
    );
  }

  /// Edits one word's text, keeping its timing and style. The renderer draws
  /// captions word by word, so this (not the segment text) is what changes
  /// the exported video; the segment's own text is rebuilt to match.
  void updateWordText(int segmentIndex, int wordIndex, String newText) {
    _editRevision++;
    final transcript = state.transcript;
    final cleaned = newText.trim();
    if (transcript == null || cleaned.isEmpty) return;
    _recordEdit();
    final segments = [...transcript.segments];
    final segment = segments[segmentIndex];
    final words = [...segment.words];
    words[wordIndex] = words[wordIndex].copyWith(text: cleaned);
    segments[segmentIndex] = segment.copyWith(
        words: words, text: words.map((w) => w.text).join(' '));
    state = state.copyWith(
      transcript: transcript.copyWith(segments: segments),
      hasUnsavedChanges: true,
      hasUnrenderedChanges: true,
    );
  }

  void updateSegmentText(int segmentIndex, String newText) {
    _editRevision++;
    final transcript = state.transcript;
    if (transcript == null) return;
    _recordEdit();
    final segments = [...transcript.segments];
    segments[segmentIndex] = segments[segmentIndex].copyWith(text: newText);
    state = state.copyWith(
      transcript: transcript.copyWith(segments: segments),
      hasUnsavedChanges: true,
      hasUnrenderedChanges: true,
    );
  }

  void updateSegmentTiming(int segmentIndex, double start, double end) {
    final transcript = state.transcript;
    if (transcript == null ||
        !start.isFinite ||
        !end.isFinite ||
        start < 0 ||
        end <= start) return;
    final old = transcript.segments[segmentIndex];
    if (start == old.start && end == old.end) return;
    final duration = old.end - old.start;
    if (duration <= 0) return;
    final newDuration = end - start;
    final words = old.words.map((word) {
      final wordStartRatio =
          ((word.start - old.start) / duration).clamp(0.0, 1.0);
      final wordEndRatio = ((word.end - old.start) / duration).clamp(0.0, 1.0);
      final wordStart = start + wordStartRatio * newDuration;
      final wordEnd = start + wordEndRatio * newDuration;
      return word.copyWith(start: wordStart, end: wordEnd);
    }).toList();
    _recordEdit();
    _editRevision++;
    final segments = [...transcript.segments];
    segments[segmentIndex] = old.copyWith(start: start, end: end, words: words);
    state = state.copyWith(
      transcript: transcript.copyWith(segments: segments),
      hasUnsavedChanges: true,
      hasUnrenderedChanges: true,
    );
  }

  void deleteSegment(int segmentIndex) {
    final transcript = state.transcript;
    if (transcript == null ||
        segmentIndex < 0 ||
        segmentIndex >= transcript.segments.length) return;
    _recordEdit();
    _editRevision++;
    final segments = [...transcript.segments]..removeAt(segmentIndex);
    state = state.copyWith(
      transcript: transcript.copyWith(segments: segments),
      hasUnsavedChanges: true,
      hasUnrenderedChanges: true,
    );
  }

  bool splitSegment(int segmentIndex) {
    final transcript = state.transcript;
    if (transcript == null ||
        segmentIndex < 0 ||
        segmentIndex >= transcript.segments.length) return false;
    final segment = transcript.segments[segmentIndex];
    if (segment.end - segment.start <= 0.002) return false;
    List<CaptionWord> leftWords;
    List<CaptionWord> rightWords;
    if (segment.words.length >= 2) {
      final middle = segment.words.length ~/ 2;
      leftWords = segment.words.sublist(0, middle);
      rightWords = segment.words.sublist(middle);
    } else {
      final tokens = segment.text.trim().split(RegExp(r'\s+'));
      if (tokens.length < 2) return false;
      final middle = tokens.length ~/ 2;
      leftWords = [];
      rightWords = [];
      final leftText = tokens.sublist(0, middle).join(' ');
      final rightText = tokens.sublist(middle).join(' ');
      final splitAt = (segment.start + segment.end) / 2;
      _recordEdit();
      _editRevision++;
      final segments = [...transcript.segments];
      segments.replaceRange(segmentIndex, segmentIndex + 1, [
        CaptionSegment(
            start: segment.start,
            end: splitAt,
            text: leftText,
            weight: segment.weight,
            words: leftWords,
            speaker: segment.speaker),
        CaptionSegment(
            start: splitAt,
            end: segment.end,
            text: rightText,
            weight: segment.weight,
            words: rightWords,
            speaker: segment.speaker),
      ]);
      state = state.copyWith(
          transcript: transcript.copyWith(segments: segments),
          hasUnsavedChanges: true,
          hasUnrenderedChanges: true);
      return true;
    }
    final splitAt = ((leftWords.last.end + rightWords.first.start) / 2)
        .clamp(segment.start + 0.001, segment.end - 0.001)
        .toDouble();
    final left = CaptionSegment(
        start: segment.start,
        end: splitAt,
        text: leftWords.map((word) => word.text).join(' '),
        weight: segment.weight,
        words: leftWords,
        speaker: segment.speaker);
    final right = CaptionSegment(
        start: splitAt,
        end: segment.end,
        text: rightWords.map((word) => word.text).join(' '),
        weight: segment.weight,
        words: rightWords,
        speaker: segment.speaker);
    _recordEdit();
    _editRevision++;
    final segments = [...transcript.segments];
    segments.replaceRange(segmentIndex, segmentIndex + 1, [left, right]);
    state = state.copyWith(
        transcript: transcript.copyWith(segments: segments),
        hasUnsavedChanges: true,
        hasUnrenderedChanges: true);
    return true;
  }

  void mergeSegmentWithNext(int segmentIndex) {
    final transcript = state.transcript;
    if (transcript == null ||
        segmentIndex < 0 ||
        segmentIndex + 1 >= transcript.segments.length) return;
    final first = transcript.segments[segmentIndex];
    final second = transcript.segments[segmentIndex + 1];
    _recordEdit();
    _editRevision++;
    final merged = CaptionSegment(
      start: first.start,
      end: second.end,
      text: '${first.text.trim()} ${second.text.trim()}'.trim(),
      weight: (first.weight + second.weight) / 2,
      words: [...first.words, ...second.words],
      speaker: first.speaker == second.speaker ? first.speaker : null,
    );
    final segments = [...transcript.segments];
    segments.replaceRange(segmentIndex, segmentIndex + 2, [merged]);
    state = state.copyWith(
        transcript: transcript.copyWith(segments: segments),
        hasUnsavedChanges: true,
        hasUnrenderedChanges: true);
  }

  void setPreset(String presetId) {
    if (presetId == state.stylePreset) return;
    _recordEdit();
    _editRevision++;
    state = state.copyWith(
      stylePreset: presetId,
      hasUnsavedChanges: true,
      hasUnrenderedChanges: true,
    );
  }

  void setStyleOverrides(StyleOverrides overrides) {
    if (overrides.toJson().toString() ==
        state.styleOverrides.toJson().toString()) return;
    _recordEdit();
    _editRevision++;
    state = state.copyWith(
      styleOverrides: overrides,
      hasUnsavedChanges: true,
      hasUnrenderedChanges: true,
    );
  }

  void setVideoFormat(String format) {
    if (!kVideoFormatLabels.containsKey(format) || format == state.videoFormat)
      return;
    _recordEdit();
    _editRevision++;
    state = state.copyWith(
      videoFormat: format,
      hasUnsavedChanges: true,
      hasUnrenderedChanges: true,
    );
  }

  Future<bool> translateTo(String targetLanguage) async {
    final transcript = state.transcript;
    final target = targetLanguage.trim();
    if (transcript == null || target.length < 2 || state.isTranslating)
      return false;
    if (target.toLowerCase() == transcript.language.toLowerCase()) return true;
    final revision = _editRevision;
    state = state.copyWith(isTranslating: true, clearError: true);
    try {
      final result = await _ref.read(apiClientProvider).post(
        '/api/projects/$projectId/captions/translate',
        data: {'caption_data': transcript.toJson(), 'target_language': target},
      );
      if (revision != _editRevision) {
        state = state.copyWith(
          isTranslating: false,
          errorMessage:
              'Captions changed while Gemini was working. Please try again.',
        );
        return false;
      }
      final translated = CaptionTranscript.fromJson(
          result['caption_data'] as Map<String, dynamic>);
      _recordEdit();
      _editRevision++;
      state = state.copyWith(
        transcript: translated,
        isTranslating: false,
        hasUnsavedChanges: true,
        hasUnrenderedChanges: true,
      );
      return true;
    } on ApiException catch (e) {
      state = state.copyWith(isTranslating: false, errorMessage: e.message);
      return false;
    } catch (_) {
      state = state.copyWith(
        isTranslating: false,
        errorMessage:
            'Gemini could not change the caption language. Please try again.',
      );
      return false;
    }
  }

  Future<bool> save() async {
    final transcript = state.transcript;
    if (transcript == null) return false;
    final revision = _editRevision;
    state = state.copyWith(isSaving: true, clearError: true);
    try {
      final result = await _ref
          .read(apiClientProvider)
          .put('/api/projects/$projectId/captions', data: {
        'style_preset': state.stylePreset,
        'caption_data': transcript.toJson(),
        'style_overrides': state.styleOverrides.toJson(),
        'aspect_ratio': state.videoFormat,
      });
      if (revision == _editRevision) {
        _savedFingerprint = result['render_fingerprint'] as String?;
      }
      state = state.copyWith(
          isSaving: false, hasUnsavedChanges: revision != _editRevision);
      return true;
    } on ApiException catch (e) {
      state = state.copyWith(isSaving: false, errorMessage: e.message);
      return false;
    }
  }

  /// Saves any pending edits, then re-renders the final video from the
  /// saved caption data -- never re-invokes Gemini (section 56), so this
  /// is fast and free of extra AI cost. Returns the new job id so the
  /// caller can navigate to the processing screen.
  Future<String?> saveAndRerender() async {
    if (state.isRendering || state.isSaving) return null;
    final revision = _editRevision;
    if (state.hasUnsavedChanges) {
      final saved = await save();
      if (!saved) return null;
    }
    if (revision != _editRevision) return null;
    _renderRevision = revision;
    state = state.copyWith(isRendering: true, clearError: true);
    try {
      final quality = _ref.read(settingsProvider).defaultExportQuality;
      final json = await _ref
          .read(apiClientProvider)
          .post('/api/projects/$projectId/render', data: {
        'quality': quality,
        'aspect_ratio': state.videoFormat,
      });
      final jobId = json['job_id'] as String;
      state = state.copyWith(
        isRendering: true,
        hasUnrenderedChanges: true,
        lastRenderJobId: jobId,
      );
      return jobId;
    } on ApiException catch (e) {
      state = state.copyWith(isRendering: false, errorMessage: e.message);
      return null;
    }
  }

  /// Enqueueing is not completion. A failed/cancelled job never makes an older
  /// export downloadable, and edits made during a job stay dirty.
  Future<void> finishRender(String jobId, {required bool completed}) async {
    if (state.lastRenderJobId != jobId) return;
    state = state.copyWith(isRendering: false);
    if (!completed || _renderRevision != _editRevision) return;
    try {
      final json = await _ref
          .read(apiClientProvider)
          .get('/api/projects/$projectId/captions');
      if (_renderRevision == _editRevision) {
        state = state.copyWith(
            hasUnrenderedChanges: json['matching_export_id'] == null ||
                json['render_fingerprint'] != _savedFingerprint);
      }
    } on ApiException catch (e) {
      state = state.copyWith(errorMessage: e.message);
    }
  }

  Future<String?> matchingExportId() async {
    if (state.hasUnsavedChanges ||
        state.hasUnrenderedChanges ||
        state.isRendering) return null;
    final revision = _editRevision;
    final json = await _ref
        .read(apiClientProvider)
        .get('/api/projects/$projectId/captions');
    if (revision != _editRevision) return null;
    if (json['render_fingerprint'] != _savedFingerprint) return null;
    return json['matching_export_id'] as String?;
  }
}

class _CaptionEditSnapshot {
  const _CaptionEditSnapshot({
    required this.transcript,
    required this.preset,
    required this.overrides,
    required this.format,
  });

  final CaptionTranscript? transcript;
  final String preset;
  final StyleOverrides overrides;
  final String format;
}

final captionEditorProvider = StateNotifierProvider.family<
    CaptionEditorNotifier, CaptionEditorState, String>(
  (ref, projectId) => CaptionEditorNotifier(ref, projectId),
);
