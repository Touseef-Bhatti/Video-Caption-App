import 'package:flutter/material.dart';

/// Mirrors schemas.WordStyle on the backend.
enum WordStyle { normal, highlight, emphasis }

WordStyle wordStyleFromString(String s) => switch (s) {
      'highlight' => WordStyle.highlight,
      'emphasis' => WordStyle.emphasis,
      _ => WordStyle.normal,
    };

String wordStyleToString(WordStyle s) => switch (s) {
      WordStyle.highlight => 'highlight',
      WordStyle.emphasis => 'emphasis',
      WordStyle.normal => 'normal',
    };

class CaptionWord {
  CaptionWord(
      {required this.text,
      required this.start,
      required this.end,
      required this.style,
      this.emoji,
      this.weight = 50});

  final String text;
  final double start;
  final double end;
  final WordStyle style;
  final String? emoji;
  final int weight; // 20-100 context importance assigned by Gemini

  /// Manual per-word style editing (spec: "user can also manually edit
  /// those captions"): tapping a word in the editor cycles its emphasis
  /// level without touching timing or text.
  CaptionWord cycleStyle() {
    final next = switch (style) {
      WordStyle.normal => WordStyle.highlight,
      WordStyle.highlight => WordStyle.emphasis,
      WordStyle.emphasis => WordStyle.normal,
    };
    return copyWith(style: next);
  }

  CaptionWord copyWith(
          {String? text,
          double? start,
          double? end,
          WordStyle? style,
          String? emoji,
          int? weight,
          bool clearEmoji = false}) =>
      CaptionWord(
        text: text ?? this.text,
        start: start ?? this.start,
        end: end ?? this.end,
        style: style ?? this.style,
        emoji: clearEmoji ? null : (emoji ?? this.emoji),
        weight: weight ?? this.weight,
      );

  factory CaptionWord.fromJson(Map<String, dynamic> json) => CaptionWord(
        text: json['text'] as String,
        start: (json['start'] as num).toDouble(),
        end: (json['end'] as num).toDouble(),
        style: wordStyleFromString(json['style'] as String? ?? 'normal'),
        emoji: json['emoji'] as String?,
        weight: ((json['weight'] as num?)?.toInt() ?? 50).clamp(20, 100),
      );

  Map<String, dynamic> toJson() => {
        'text': text,
        'start': start,
        'end': end,
        'style': wordStyleToString(style),
        if (emoji != null) 'emoji': emoji,
        'weight': weight,
      };
}

/// Splits a caption segment into short, weight-aware display lines. The same
/// grouping is used by the editor's caption list and the shared preview/export
/// renderer so both show the same words together.
List<List<int>> captionWordGroups(List<CaptionWord> words) {
  if (words.isEmpty) return const [];

  const minWordsPerLine = 3;
  const maxWordsPerLine = 4;
  const targetWeightPerLine = 200;
  final groups = <List<int>>[];
  var group = <int>[];
  var groupWeight = 0;

  for (var i = 0; i < words.length; i++) {
    group.add(i);
    groupWeight += words[i].weight.clamp(20, 100).toInt();
    if (group.length == maxWordsPerLine ||
        (group.length >= minWordsPerLine &&
            groupWeight >= targetWeightPerLine)) {
      groups.add(group);
      group = <int>[];
      groupWeight = 0;
    }
  }
  if (group.isNotEmpty) groups.add(group);

  // Avoid a one or two word tail when the previous line has room.
  if (groups.length > 1 && groups.last.length < minWordsPerLine) {
    final previous = groups[groups.length - 2];
    while (groups.last.length < minWordsPerLine &&
        previous.length > minWordsPerLine) {
      groups.last.insert(0, previous.removeLast());
    }
  }
  return groups;
}

class CaptionSegment {
  CaptionSegment({
    required this.start,
    required this.end,
    required this.text,
    required this.weight,
    required this.words,
    this.speaker,
    this.positionX,
    this.positionY,
    this.scale,
    this.rotationDegrees,
    this.stylePreset,
    this.fontFamily,
    this.fontSize,
    this.motionEnabled,
  });

  final double start;
  final double end;
  final String text;
  final double
      weight; // 0.0-1.0, Gemini's context-weight judgment for this line
  final List<CaptionWord> words;
  final String? speaker;
  final double? positionX;
  final double? positionY;
  final double? scale;
  final double? rotationDegrees;
  final String? stylePreset;
  final String? fontFamily;
  final int? fontSize;
  final bool? motionEnabled;

  CaptionSegment copyWith({
    String? text,
    double? start,
    double? end,
    List<CaptionWord>? words,
    String? speaker,
    double? positionX,
    double? positionY,
    double? scale,
    double? rotationDegrees,
    String? stylePreset,
    String? fontFamily,
    bool clearFontFamily = false,
    int? fontSize,
    bool? motionEnabled,
  }) =>
      CaptionSegment(
        start: start ?? this.start,
        end: end ?? this.end,
        text: text ?? this.text,
        weight: weight,
        words: words ?? this.words,
        speaker: speaker ?? this.speaker,
        positionX: positionX ?? this.positionX,
        positionY: positionY ?? this.positionY,
        scale: scale ?? this.scale,
        rotationDegrees: rotationDegrees ?? this.rotationDegrees,
        stylePreset: stylePreset ?? this.stylePreset,
        fontFamily: clearFontFamily ? null : (fontFamily ?? this.fontFamily),
        fontSize: fontSize ?? this.fontSize,
        motionEnabled: motionEnabled ?? this.motionEnabled,
      );

  factory CaptionSegment.fromJson(Map<String, dynamic> json) => CaptionSegment(
        start: (json['start'] as num).toDouble(),
        end: (json['end'] as num).toDouble(),
        text: json['text'] as String,
        speaker: json['speaker'] as String?,
        positionX: (json['position_x'] as num?)?.toDouble(),
        positionY: (json['position_y'] as num?)?.toDouble(),
        scale: (json['scale'] as num?)?.toDouble(),
        rotationDegrees: (json['rotation_degrees'] as num?)?.toDouble(),
        stylePreset: json['style_preset'] as String?,
        fontFamily: json['font_family'] as String?,
        fontSize: (json['font_size'] as num?)?.toInt(),
        motionEnabled: json['motion_enabled'] as bool?,
        weight: (json['weight'] as num?)?.toDouble() ?? 0.5,
        words: (json['words'] as List<dynamic>? ?? [])
            .map((w) => CaptionWord.fromJson(w as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'start': start,
        'end': end,
        'text': text,
        if (speaker != null) 'speaker': speaker,
        'weight': weight,
        if (positionX != null) 'position_x': positionX,
        if (positionY != null) 'position_y': positionY,
        if (scale != null) 'scale': scale,
        if (rotationDegrees != null) 'rotation_degrees': rotationDegrees,
        if (stylePreset != null) 'style_preset': stylePreset,
        if (fontFamily != null) 'font_family': fontFamily,
        if (fontSize != null) 'font_size': fontSize,
        if (motionEnabled != null) 'motion_enabled': motionEnabled,
        'words': words.map((w) => w.toJson()).toList(),
      };
}

class CaptionTranscript {
  CaptionTranscript({
    required this.language,
    required this.segments,
    this.sourceTrack,
    List<CaptionTrack> translationTracks = const [],
    CaptionTrack? translationTrack,
    this.activeTrack = 'source',
    this.activeTranslationLanguage,
  }) : translationTracks = _mergeTranslationTracks(
          translationTracks,
          translationTrack,
        );

  final String language;
  final List<CaptionSegment> segments;
  final CaptionTrack? sourceTrack;
  final List<CaptionTrack> translationTracks;
  final String activeTrack;
  final String? activeTranslationLanguage;

  CaptionTrack? get activeTranslationTrack {
    final selectedLanguage = activeTranslationLanguage ??
        (activeTrack == 'translation' ? language : null);
    if (selectedLanguage != null) {
      for (final track in translationTracks) {
        if (track.language.toLowerCase() == selectedLanguage.toLowerCase()) {
          return track;
        }
      }
    }
    return translationTracks.isEmpty ? null : translationTracks.last;
  }

  /// Compatibility helper for older editor call sites and saved payloads.
  CaptionTrack? get translationTrack => activeTranslationTrack;

  CaptionTranscript copyWith({
    String? language,
    List<CaptionSegment>? segments,
    CaptionTrack? sourceTrack,
    List<CaptionTrack>? translationTracks,
    CaptionTrack? translationTrack,
    String? activeTrack,
    String? activeTranslationLanguage,
  }) {
    final nextSegments = segments ?? this.segments;
    final nextLanguage = language ?? this.language;
    final nextActiveTrack = activeTrack ?? this.activeTrack;
    var nextSource = sourceTrack ?? this.sourceTrack;
    var nextTranslations = translationTracks ?? this.translationTracks;
    if (translationTrack != null) {
      nextTranslations = _mergeTranslationTracks(nextTranslations, translationTrack);
    }
    final nextTranslationLanguage = activeTranslationLanguage ??
        this.activeTranslationLanguage ??
        (nextActiveTrack == 'translation' ? nextLanguage : null);
    if (segments != null) {
      final active = CaptionTrack(language: nextLanguage, segments: nextSegments);
      if (nextActiveTrack == 'translation') {
        nextTranslations = _mergeTranslationTracks(nextTranslations, active);
      } else {
        nextSource = active;
      }
    }
    return CaptionTranscript(
      language: nextLanguage,
      segments: nextSegments,
      sourceTrack: nextSource,
      translationTracks: nextTranslations,
      activeTrack: nextActiveTrack,
      activeTranslationLanguage: nextTranslationLanguage,
    );
  }

  factory CaptionTranscript.fromJson(Map<String, dynamic> json) {
    final activeTrack = json['active_track'] as String? ?? 'source';
    final savedTracks = (json['translation_tracks'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(CaptionTrack.fromJson)
        .toList();
    final legacyTrack = json['translation_track'] is Map<String, dynamic>
        ? CaptionTrack.fromJson(json['translation_track'] as Map<String, dynamic>)
        : null;
    return CaptionTranscript(
        language: json['language'] as String,
        segments: (json['segments'] as List<dynamic>? ?? [])
            .map((s) => CaptionSegment.fromJson(s as Map<String, dynamic>))
            .toList(),
        sourceTrack: json['source_track'] is Map<String, dynamic>
            ? CaptionTrack.fromJson(json['source_track'] as Map<String, dynamic>)
            : (activeTrack == 'translation'
                ? null
                : CaptionTrack.fromActiveJson(json)),
        translationTracks: savedTracks,
        translationTrack: legacyTrack,
        activeTrack: activeTrack,
        activeTranslationLanguage:
            json['active_translation_language'] as String? ??
                (activeTrack == 'translation'
                    ? json['language'] as String?
                    : null),
      );
  }

  Map<String, dynamic> toJson() {
    final activeTranslation = activeTranslationTrack;
    return {
        'language': language,
        'segments': segments.map((s) => s.toJson()).toList(),
        if (sourceTrack != null) 'source_track': sourceTrack!.toJson(),
        if (translationTracks.isNotEmpty)
          'translation_tracks':
              translationTracks.map((track) => track.toJson()).toList(),
        if (activeTranslation != null)
          'translation_track': activeTranslation.toJson(),
        'active_track': activeTrack,
        if (activeTranslation != null)
          'active_translation_language': activeTranslation.language,
      };
  }

  static List<CaptionTrack> _mergeTranslationTracks(
    List<CaptionTrack> tracks,
    CaptionTrack? replacement,
  ) {
    final merged = [...tracks];
    if (replacement == null) return merged;
    final index = merged.indexWhere((track) =>
        track.language.toLowerCase() == replacement.language.toLowerCase());
    if (index < 0) {
      merged.add(replacement);
    } else {
      merged[index] = replacement;
    }
    return merged;
  }
}

class CaptionTrack {
  const CaptionTrack({required this.language, required this.segments});

  final String language;
  final List<CaptionSegment> segments;

  factory CaptionTrack.fromActiveJson(Map<String, dynamic> json) => CaptionTrack(
        language: json['language'] as String,
        segments: (json['segments'] as List<dynamic>? ?? [])
            .map((s) => CaptionSegment.fromJson(s as Map<String, dynamic>))
            .toList(),
      );

  factory CaptionTrack.fromJson(Map<String, dynamic> json) =>
      CaptionTrack.fromActiveJson(json);

  Map<String, dynamic> toJson() => {
        'language': language,
        'segments': segments.map((s) => s.toJson()).toList(),
      };
}

/// Mirrors schemas.StyleOverrides. Color values stay as #RRGGBB on the wire
/// and are converted to Flutter [Color] by the shared preview/export scene.
class StyleOverrides {
  const StyleOverrides({
    this.primaryColor,
    this.highlightColor,
    this.emphasisColor,
    this.backgroundColor,
    this.backgroundOpacity,
    this.fontSize,
    this.fontFamily,
    this.letterSpacing,
    this.italic,
    this.bold,
    this.position,
    this.positionX,
    this.positionY,
    this.scale = 1,
    this.rotationDegrees = 0,
    this.emojisEnabled = true,
    this.motionEnabled = true,
  });

  final String? primaryColor;
  final String? highlightColor;
  final String? emphasisColor;
  final String? backgroundColor;
  final double? backgroundOpacity;
  final int? fontSize;
  final String? fontFamily;
  final double? letterSpacing;
  final bool? italic;
  final bool? bold;
  final String? position; // "top" | "center" | "bottom"
  final double? positionX; // normalized 0.0-1.0 caption center
  final double? positionY; // normalized 0.0-1.0 caption center
  final double scale;
  final double rotationDegrees;
  final bool emojisEnabled;
  final bool motionEnabled;

  StyleOverrides copyWith({
    String? primaryColor,
    String? highlightColor,
    String? emphasisColor,
    String? backgroundColor,
    double? backgroundOpacity,
    int? fontSize,
    String? fontFamily,
    bool clearFontFamily = false,
    double? letterSpacing,
    bool? italic,
    bool? bold,
    String? position,
    double? positionX,
    double? positionY,
    double? scale,
    double? rotationDegrees,
    bool? emojisEnabled,
    bool? motionEnabled,
  }) =>
      StyleOverrides(
        primaryColor: primaryColor ?? this.primaryColor,
        highlightColor: highlightColor ?? this.highlightColor,
        emphasisColor: emphasisColor ?? this.emphasisColor,
        backgroundColor: backgroundColor ?? this.backgroundColor,
        backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
        fontSize: fontSize ?? this.fontSize,
        fontFamily: clearFontFamily ? null : (fontFamily ?? this.fontFamily),
        letterSpacing: letterSpacing ?? this.letterSpacing,
        italic: italic ?? this.italic,
        bold: bold ?? this.bold,
        position: position ?? this.position,
        positionX: positionX ?? this.positionX,
        positionY: positionY ?? this.positionY,
        scale: scale ?? this.scale,
        rotationDegrees: rotationDegrees ?? this.rotationDegrees,
        emojisEnabled: emojisEnabled ?? this.emojisEnabled,
        motionEnabled: motionEnabled ?? this.motionEnabled,
      );

  factory StyleOverrides.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const StyleOverrides();
    return StyleOverrides(
      primaryColor: json['primary_color'] as String?,
      highlightColor: json['highlight_color'] as String?,
      emphasisColor: json['emphasis_color'] as String?,
      backgroundColor: json['background_color'] as String?,
      backgroundOpacity: (json['background_opacity'] as num?)?.toDouble(),
      fontSize: (json['font_size'] as num?)?.toInt(),
      fontFamily: json['font_family'] as String?,
      letterSpacing: (json['letter_spacing'] as num?)?.toDouble(),
      italic: json['italic'] as bool?,
      bold: json['bold'] as bool?,
      position: json['position'] as String?,
      positionX: (json['position_x'] as num?)?.toDouble(),
      positionY: (json['position_y'] as num?)?.toDouble(),
      scale: (json['scale'] as num?)?.toDouble() ?? 1,
      rotationDegrees: (json['rotation_degrees'] as num?)?.toDouble() ?? 0,
      emojisEnabled: json['emojis_enabled'] as bool? ?? true,
      motionEnabled: json['motion_enabled'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
        if (primaryColor != null) 'primary_color': primaryColor,
        if (highlightColor != null) 'highlight_color': highlightColor,
        if (emphasisColor != null) 'emphasis_color': emphasisColor,
        if (backgroundColor != null) 'background_color': backgroundColor,
        if (backgroundOpacity != null) 'background_opacity': backgroundOpacity,
        if (fontSize != null) 'font_size': fontSize,
        if (fontFamily != null) 'font_family': fontFamily,
        if (letterSpacing != null) 'letter_spacing': letterSpacing,
        if (italic != null) 'italic': italic,
        if (bold != null) 'bold': bold,
        if (position != null) 'position': position,
        if (positionX != null) 'position_x': positionX,
        if (positionY != null) 'position_y': positionY,
        if (scale != 1) 'scale': scale,
        if (rotationDegrees != 0) 'rotation_degrees': rotationDegrees,
        'emojis_enabled': emojisEnabled,
        'motion_enabled': motionEnabled,
      };
}

Color colorFromHex(String hex) {
  final h = hex.replaceFirst('#', '');
  return Color(int.parse('FF$h', radix: 16));
}

String colorToHex(Color color) =>
    '#${color.value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

/// A caption preset rendered by CaptionScene in both the live editor and the
/// export worker. Static and animated presets share the same visual model.
class CaptionPresetInfo {
  const CaptionPresetInfo({
    required this.id,
    required this.label,
    required this.description,
    required this.primaryPreview,
    required this.highlightPreview,
    required this.emphasisPreview,
    required this.backgroundPreview,
    required this.bold,
    required this.motion,
    this.effect = '',
  });

  final String id;
  final String label;
  final String description;
  final Color primaryPreview;
  final Color highlightPreview;
  final Color emphasisPreview;
  final Color backgroundPreview;
  final bool bold;
  final String motion;
  final String effect;
}

const List<CaptionPresetInfo> kCaptionPresets = [
  CaptionPresetInfo(
    id: 'classic',
    label: 'Viral Pop',
    description: 'Bold creator captions with weight-driven word pops.',
    primaryPreview: Color(0xFFFFFFFF),
    highlightPreview: Color(0xFFFFD700),
    emphasisPreview: Color(0xFFFF6600),
    backgroundPreview: Color(0xB8000000),
    bold: true,
    motion: 'pop',
    effect: '✦',
  ),
  CaptionPresetInfo(
    id: 'neon',
    label: 'Neon Pulse',
    description: 'Electric cyan and pink with a soft rhythmic pulse.',
    primaryPreview: Color(0xFFFFFFFF),
    highlightPreview: Color(0xFF00E5FF),
    emphasisPreview: Color(0xFFFF2D92),
    backgroundPreview: Color(0xD91A0C2E),
    bold: true,
    motion: 'pulse',
    effect: '✧',
  ),
  CaptionPresetInfo(
    id: 'headline',
    label: 'Golden Headline',
    description: 'Animated orange lower-third inspired by broadcast graphics.',
    primaryPreview: Color(0xFFFFFFFF),
    highlightPreview: Color(0xFFFFF1C1),
    emphasisPreview: Color(0xFFFFFFFF),
    backgroundPreview: Color(0xEFFF6A00),
    bold: true,
    motion: 'slide',
    effect: '◆',
  ),
  CaptionPresetInfo(
    id: 'social',
    label: 'Social Bounce',
    description: 'Friendly short-form captions with a lively bounce.',
    primaryPreview: Color(0xFFFFFFFF),
    highlightPreview: Color(0xFFFFF000),
    emphasisPreview: Color(0xFFFFA200),
    backgroundPreview: Color(0xB8000000),
    bold: true,
    motion: 'bounce',
    effect: '🔥',
  ),
  CaptionPresetInfo(
    id: 'karaoke',
    label: 'Karaoke Flow',
    description: 'Smooth word-by-word color and scale progression.',
    primaryPreview: Color(0xFFC8C8C8),
    highlightPreview: Color(0xFFFFD700),
    emphasisPreview: Color(0xFFFF8A00),
    backgroundPreview: Color(0xC7000000),
    bold: true,
    motion: 'karaoke',
    effect: '♪',
  ),
  CaptionPresetInfo(
    id: 'comic',
    label: 'Comic Impact',
    description: 'Punchline words hit hard with comic-style impact motion.',
    primaryPreview: Color(0xFFFFFFFF),
    highlightPreview: Color(0xFFFFD700),
    emphasisPreview: Color(0xFFFF3B30),
    backgroundPreview: Color(0xD91B1B22),
    bold: true,
    motion: 'impact',
    effect: '💥',
  ),
  CaptionPresetInfo(
    id: 'creator',
    label: 'Creator Card',
    description: 'Polished creator-style card with coral focus words.',
    primaryPreview: Color(0xFFFFFFFF),
    highlightPreview: Color(0xFFFF6B6B),
    emphasisPreview: Color(0xFFFF2D92),
    backgroundPreview: Color(0xD91E1E24),
    bold: true,
    motion: 'zoom',
    effect: '●',
  ),
  CaptionPresetInfo(
    id: 'news',
    label: 'Motion News',
    description: 'Clean orange broadcast bar with fast slide accents.',
    primaryPreview: Color(0xFFFFFFFF),
    highlightPreview: Color(0xFFFFF4D6),
    emphasisPreview: Color(0xFFFFD166),
    backgroundPreview: Color(0xF2E85D04),
    bold: true,
    motion: 'slide',
    effect: '⚡',
  ),
  CaptionPresetInfo(
    id: 'minimal',
    label: 'Soft Minimal',
    description: 'Quiet premium captions with restrained fade motion.',
    primaryPreview: Color(0xFFFFFFFF),
    highlightPreview: Color(0xFFB8FFE3),
    emphasisPreview: Color(0xFFFFFFFF),
    backgroundPreview: Color(0x8F000000),
    bold: false,
    motion: 'fade',
  ),
  CaptionPresetInfo(
    id: 'cinematic',
    label: 'Cinematic Glow',
    description: 'Elegant warm type with a subtle reveal and star accent.',
    primaryPreview: Color(0xFFEDEDED),
    highlightPreview: Color(0xFFFFD98A),
    emphasisPreview: Color(0xFFFFB347),
    backgroundPreview: Color(0x99000000),
    bold: false,
    motion: 'cinematic',
    effect: '✦',
  ),
  CaptionPresetInfo(
      id: 'podcast_interview',
      label: 'Podcast Interview',
      description: 'Quiet interview captions with an optional speaker tag.',
      primaryPreview: Color(0xFFF7F5F0),
      highlightPreview: Color(0xFFE7C98C),
      emphasisPreview: Color(0xFFFFE5B8),
      backgroundPreview: Color(0xD9222529),
      bold: false,
      motion: 'none'),
  CaptionPresetInfo(
      id: 'simple_white',
      label: 'Simple White',
      description: 'Plain white text with a soft shadow.',
      primaryPreview: Color(0xFFFFFFFF),
      highlightPreview: Color(0xFFFFFFFF),
      emphasisPreview: Color(0xFFFFFFFF),
      backgroundPreview: Color(0x00000000),
      bold: false,
      motion: 'none'),
  CaptionPresetInfo(
      id: 'clean_dark',
      label: 'Clean Dark',
      description: 'Readable white type on a quiet dark panel.',
      primaryPreview: Color(0xFFFFFFFF),
      highlightPreview: Color(0xFFFFFFFF),
      emphasisPreview: Color(0xFFFFFFFF),
      backgroundPreview: Color(0x99000000),
      bold: false,
      motion: 'none'),
  CaptionPresetInfo(
      id: 'soft_pastel',
      label: 'Soft Pastel',
      description: 'Gentle lavender tones for a calm look.',
      primaryPreview: Color(0xFFFFFFFF),
      highlightPreview: Color(0xFFE8D9FF),
      emphasisPreview: Color(0xFFFFE4EF),
      backgroundPreview: Color(0xB82A2038),
      bold: false,
      motion: 'none'),
  CaptionPresetInfo(
      id: 'warm_aesthetic',
      label: 'Warm Aesthetic',
      description: 'Warm cream text with subtle amber accents.',
      primaryPreview: Color(0xFFFFF5E6),
      highlightPreview: Color(0xFFFFD79A),
      emphasisPreview: Color(0xFFFFBD87),
      backgroundPreview: Color(0x99000000),
      bold: false,
      motion: 'none'),
  CaptionPresetInfo(
      id: 'elegant_gold',
      label: 'Elegant Gold',
      description: 'Understated gold accents on charcoal.',
      primaryPreview: Color(0xFFF7F1E8),
      highlightPreview: Color(0xFFE8C878),
      emphasisPreview: Color(0xFFFFE9A8),
      backgroundPreview: Color(0xA8000000),
      bold: false,
      motion: 'none'),
  CaptionPresetInfo(
      id: 'paper_note',
      label: 'Paper Note',
      description: 'Dark ink on a warm paper card.',
      primaryPreview: Color(0xFF29251F),
      highlightPreview: Color(0xFF70552C),
      emphasisPreview: Color(0xFF9B4D34),
      backgroundPreview: Color(0xEFFFFFF0),
      bold: false,
      motion: 'none'),
  CaptionPresetInfo(
      id: 'soft_shadow',
      label: 'Soft Shadow',
      description: 'Simple captions without a background panel.',
      primaryPreview: Color(0xFFFFFFFF),
      highlightPreview: Color(0xFFFFE38A),
      emphasisPreview: Color(0xFFFFD1A8),
      backgroundPreview: Color(0x00000000),
      bold: true,
      motion: 'none'),
  CaptionPresetInfo(
      id: 'sage_minimal',
      label: 'Sage Minimal',
      description: 'Muted sage highlights with light type.',
      primaryPreview: Color(0xFFF8FAF7),
      highlightPreview: Color(0xFFCBE2D0),
      emphasisPreview: Color(0xFFEAF3D8),
      backgroundPreview: Color(0x990F2118),
      bold: false,
      motion: 'none'),
  CaptionPresetInfo(
      id: 'rose_elegant',
      label: 'Rose Elegant',
      description: 'Soft rose accents with refined spacing.',
      primaryPreview: Color(0xFFFFF8FA),
      highlightPreview: Color(0xFFF3BDD0),
      emphasisPreview: Color(0xFFFFDCE8),
      backgroundPreview: Color(0xA8251720),
      bold: false,
      motion: 'none'),
  CaptionPresetInfo(
      id: 'mono_clean',
      label: 'Mono Clean',
      description: 'Modern monochrome type for tutorials and explainers.',
      primaryPreview: Color(0xFFFFFFFF),
      highlightPreview: Color(0xFFD7D7D7),
      emphasisPreview: Color(0xFFFFFFFF),
      backgroundPreview: Color(0xB8171717),
      bold: true,
      motion: 'none'),
  CaptionPresetInfo(
      id: 'blue_quiet',
      label: 'Blue Quiet',
      description: 'Cool blue accents in a low-key dark card.',
      primaryPreview: Color(0xFFF6FAFF),
      highlightPreview: Color(0xFFB9DFFF),
      emphasisPreview: Color(0xFFE2F3FF),
      backgroundPreview: Color(0xA8142638),
      bold: false,
      motion: 'none'),
];

final Map<String, String> kCaptionPresetLabels = {
  for (final p in kCaptionPresets) p.id: p.label,
};

CaptionPresetInfo presetInfoFor(String id) {
  const aliases = {
    'clean': 'minimal',
    'bold': 'comic',
    'highlight': 'creator',
    'dynamic': 'classic',
    'elegant': 'cinematic'
  };
  final resolved = aliases[id] ?? id;
  return kCaptionPresets.firstWhere((p) => p.id == resolved,
      orElse: () => kCaptionPresets.first);
}
