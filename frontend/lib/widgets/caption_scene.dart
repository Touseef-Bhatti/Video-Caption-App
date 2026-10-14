import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/caption.dart';

const captionFramesPerSecond = 30;
const captionRendererVersion = 'flutter-scene-v3';

String captionPosition(String id) =>
    {'classic', 'neon', 'social', 'comic'}.contains(presetInfoFor(id).id)
        ? 'center'
        : 'bottom';

String captionFontForLanguage(String language) {
  final normalized = language.toLowerCase().trim();
  if (normalized == 'urdu') return 'Caption Urdu';
  if ({'arabic', 'persian', 'farsi'}.contains(normalized)) {
    return 'Caption Arabic';
  }
  return 'Caption Sans';
}

String captionFontForTranscript(CaptionTranscript transcript) {
  final text = transcript.segments.map((segment) => segment.text).join(' ');
  return captionFontForText(text, transcript.language);
}

String captionFontForText(String text, String language) {
  final hasArabicScript = RegExp(r'[\u0600-\u06FF\u0750-\u077F]')
      .hasMatch(text);
  if (!hasArabicScript) return 'Caption Sans';
  return captionFontForLanguage(language);
}

bool captionTranscriptIsRtl(CaptionTranscript transcript) {
  final text = transcript.segments.map((segment) => segment.text).join(' ');
  return captionTextIsRtl(text, transcript.language);
}

bool captionTextIsRtl(String text, String language) {
  if (text.isNotEmpty) {
    final hasRtlScript = RegExp(r'[\u0590-\u08FF]').hasMatch(text);
    final hasLatinScript = RegExp(r'[A-Za-z]').hasMatch(text);
    if (hasRtlScript && !hasLatinScript) return true;
    if (hasLatinScript) return false;
    return hasRtlScript;
  }
  return {'urdu', 'arabic', 'persian', 'farsi', 'hebrew'}
      .contains(language.toLowerCase().trim());
}

String captionFontLabel(String family) => switch (family) {
      'Caption Urdu' => 'Noto Nastaliq Urdu',
      'Caption Arabic' => 'Noto Naskh Arabic',
      _ => 'Noto Sans',
    };

double captionPositionY(String position) => switch (position) {
      'top' => 0.17,
      'center' => 0.52,
      _ => 0.82,
    };

/// The ONLY caption drawing implementation, used by the editor and the
/// headless export entrypoint. Layout uses a 1080-high design canvas; resizing
/// the editor scales the entire composition, never reflows or restyles it.
class CaptionScene extends StatelessWidget {
  const CaptionScene({
    super.key,
    required this.transcript,
    required this.presetId,
    required this.overrides,
    required this.time,
    this.onTransformChanged,
  });

  final CaptionTranscript transcript;
  final String presetId;
  final StyleOverrides overrides;
  final double time;
  final void Function(double x, double y, double scale, double rotationDegrees)? onTransformChanged;

  @override
  Widget build(BuildContext context) {
    final t = (time * captionFramesPerSecond + 0.000001).floor() /
        captionFramesPerSecond;
    CaptionSegment? segment;
    for (final candidate in transcript.segments) {
      if (t >= candidate.start && t < candidate.end) {
        segment = candidate;
        break;
      }
    }
    if (segment == null) return const SizedBox.expand();
    final seg = segment;
    final activePresetId = seg.stylePreset ?? presetId;
    final preset = presetInfoFor(activePresetId);
    final x = (seg.positionX ?? overrides.positionX ?? 0.5).clamp(0.05, 0.95);
    final y = (seg.positionY ?? overrides.positionY ??
            captionPositionY(overrides.position ?? captionPosition(activePresetId)))
        .clamp(0.05, 0.95);
    final lineScale = seg.scale ?? overrides.scale;
    final lineRotation = seg.rotationDegrees ?? overrides.rotationDegrees;
    final words = seg.words.isEmpty
        ? _wordsFromSegment(seg)
        : seg.words;
    final active = words.indexWhere((w) => t >= w.start && t < w.end);
    final wordRows = captionWordGroups(words);
    var visibleRowIndex = wordRows.lastIndexWhere(
      (indices) => t >= words[indices.first].start,
    );
    if (visibleRowIndex < 0) visibleRowIndex = 0;
    final visibleWords = wordRows.isEmpty ? <int>[] : wordRows[visibleRowIndex];
    final rtl = captionTextIsRtl(seg.text, transcript.language);
    final languageFont = captionFontForText(seg.text, transcript.language);
    final font = seg.fontFamily == 'auto'
        ? languageFont
        : seg.fontFamily ?? overrides.fontFamily ?? languageFont;
    final size = (seg.fontSize ?? overrides.fontSize ?? 44).toDouble();
    final motionEnabled = seg.motionEnabled ?? overrides.motionEnabled;
    // Existing panel spacing, normalized with the old 18px / 44 size ratio.
    const unit = 44 / 18;

    Color colorFor(WordStyle style, int wordIndex) {
      if (presetInfoFor(activePresetId).id == 'karaoke') {
        if (wordIndex == active) return overrides.highlightColor != null
            ? colorFromHex(overrides.highlightColor!) : preset.highlightPreview;
        if (wordIndex < active) return preset.highlightPreview;
        return overrides.primaryColor != null
            ? colorFromHex(overrides.primaryColor!) : preset.primaryPreview;
      }
      final hex = switch (style) {
        WordStyle.normal => overrides.primaryColor,
        WordStyle.highlight => overrides.highlightColor,
        WordStyle.emphasis => overrides.emphasisColor,
      };
      return hex != null ? colorFromHex(hex) : switch (style) {
        WordStyle.normal => preset.primaryPreview,
        WordStyle.highlight => preset.highlightPreview,
        WordStyle.emphasis => preset.emphasisPreview,
      };
    }

    double phase(CaptionWord w) =>
        ((t - w.start) / math.max(0.12, w.end - w.start)).clamp(0.0, 1.0);
    double scale(CaptionWord w, int i) {
      if (!motionEnabled || preset.motion == 'none' || i != active) return 1;
      final strength = switch (w.style) {
        WordStyle.emphasis => 0.46,
        WordStyle.highlight => 0.27,
        WordStyle.normal => 0.08,
      };
      return 1 + math.sin(phase(w) * math.pi) * (w.weight / 100) * strength *
          (preset.motion == 'impact' ? 1.22 : 1);
    }
    Offset offset(CaptionWord w, int i) {
      if (!motionEnabled || preset.motion == 'none' || i != active) return Offset.zero;
      final p = phase(w);
      final envelope = math.sin(p * math.pi);
      return switch (preset.motion) {
        'bounce' => Offset(0, -7 * unit * envelope),
        'impact' => Offset(math.sin(p * math.pi * 6) * 2.5 * unit, 0),
        'slide' => Offset((1 - p) * 7 * unit, 0),
        _ => Offset.zero,
      };
    }

    return LayoutBuilder(builder: (context, frame) {
      final designWidth = frame.maxWidth / frame.maxHeight * 1080;
      final basePanel = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: designWidth * 0.88),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12 * unit, vertical: 7 * unit),
          decoration: BoxDecoration(
            color: overrides.backgroundColor != null
                ? colorFromHex(overrides.backgroundColor!).withValues(
                    alpha: (overrides.backgroundOpacity ?? 0.75)
                        .clamp(0.0, 1.0).toDouble())
                : preset.backgroundPreview,
            borderRadius: BorderRadius.circular(
                (preset.id == 'headline' || preset.id == 'news' ? 4 : 6) * unit),
            border: preset.id == 'headline' || preset.id == 'news'
                ? Border(left: BorderSide(color: preset.highlightPreview, width: 5 * unit))
                : null,
            boxShadow: preset.id == 'neon'
                ? [BoxShadow(color: preset.highlightPreview.withValues(alpha: 0.38), blurRadius: 12 * unit)]
                : null,
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
              for (final i in visibleWords) ...[
                if (i != visibleWords.first) SizedBox(width: 4 * unit),
                if (i == active && motionEnabled && preset.motion != 'none' && preset.effect.isNotEmpty &&
                    words[i].weight >= 70 && words[i].style != WordStyle.normal)
                  Transform.scale(
                    scale: scale(words[i], i),
                    child: Text(preset.effect,
                        style: TextStyle(color: preset.emphasisPreview, fontSize: size)),
                  ),
                Transform.translate(
                  offset: offset(words[i], i),
                  child: Transform.scale(
                    scale: scale(words[i], i),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(words[i].text,
                          style: TextStyle(color: colorFor(words[i].style, i), fontSize: size,
                              letterSpacing: overrides.letterSpacing ?? 0,
                              fontStyle: (overrides.italic ?? false) ? FontStyle.italic : FontStyle.normal,
                              fontWeight: (overrides.bold ?? preset.bold)
                                  ? FontWeight.w800 : FontWeight.w500)),
                      if (overrides.emojisEnabled && words[i].emoji != null)
                        Text(' ${words[i].emoji}', style: TextStyle(fontSize: size)),
                    ]),
                  ),
                ),
              ],
              ],
            ),
          ),
        ),
      );
      final panel = preset.id == 'podcast_interview'
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (seg.speaker?.trim().isNotEmpty == true)
                  Container(
                    margin: EdgeInsets.only(bottom: 3 * unit),
                    padding: EdgeInsets.symmetric(horizontal: 8 * unit, vertical: 2 * unit),
                    decoration: BoxDecoration(
                      color: preset.highlightPreview,
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(seg.speaker!, style: TextStyle(
                      color: Colors.black87, fontSize: size * 0.62,
                      fontWeight: FontWeight.w700,
                    )),
                  ),
                basePanel,
              ],
            )
          : basePanel;
      return FittedBox(
        fit: BoxFit.fill,
        child: SizedBox(
          width: designWidth,
          height: 1080,
          child: Directionality(
            textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
            child: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.noScaling),
              child: DefaultTextStyle(
                style: TextStyle(fontFamily: font, fontSize: size, height: 1.25,
                    letterSpacing: overrides.letterSpacing ?? 0,
                    fontStyle: (overrides.italic ?? false) ? FontStyle.italic : FontStyle.normal,
                    fontFamilyFallback: const ['Caption Sans', 'Caption Arabic',
                      'Caption Urdu', 'Caption Symbols', 'Caption Emoji']),
                child: Stack(clipBehavior: Clip.hardEdge, children: [
                  Positioned(
                    left: designWidth * x,
                    top: 1080 * y,
                    child: FractionalTranslation(
                      translation: const Offset(-0.5, -0.5),
                      child: _CaptionGestureTransform(
                          enabled: onTransformChanged != null,
                          centerX: x,
                          centerY: y,
                          scale: lineScale,
                          rotationDegrees: lineRotation,
                          canvasWidth: frame.maxWidth,
                          canvasHeight: frame.maxHeight,
                          onChanged: onTransformChanged,
                          child: CustomPaint(
                          foregroundPainter: onTransformChanged == null
                              ? null
                              : const _DottedSelectionPainter(),
                          child: Transform.translate(
                          offset: motionEnabled && preset.motion == 'slide'
                              ? Offset((1 - ((t - seg.start) / 0.28).clamp(0.0, 1.0)) * 24 * unit, 0)
                              : Offset.zero,
                          child: Opacity(
                            opacity: motionEnabled && preset.motion != 'none' ? ((t - seg.start) /
                                (preset.motion == 'cinematic' ? 0.42 : 0.18)).clamp(0.15, 1.0) : 1,
                            child: panel,
                          )),
                          ),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      );
    });
  }
}

List<CaptionWord> _wordsFromSegment(CaptionSegment segment) {
  final tokens = segment.text.trim().split(RegExp(r'\s+'))
    ..removeWhere((token) => token.isEmpty);
  if (tokens.isEmpty) return const [];
  final totalChars = tokens.fold<int>(0, (sum, token) => sum + token.length);
  final duration = segment.end - segment.start;
  var elapsedChars = 0;
  final words = <CaptionWord>[];
  for (final token in tokens) {
    final start = segment.start + duration * elapsedChars / totalChars;
    elapsedChars += token.length;
    final end = segment.start + duration * elapsedChars / totalChars;
    words.add(CaptionWord(
      text: token,
      start: start,
      end: end,
      style: WordStyle.normal,
      weight: 50,
    ));
  }
  return words;
}

class _DottedSelectionPainter extends CustomPainter {
  const _DottedSelectionPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    const dash = 5.0;
    const gap = 4.0;
    for (var x = 0.0; x < size.width; x += dash + gap) {
      final endX = math.min(x + dash, size.width).toDouble();
      canvas.drawLine(Offset(x, 0), Offset(endX, 0), paint);
      canvas.drawLine(Offset(x, size.height), Offset(endX, size.height), paint);
    }
    for (var y = 0.0; y < size.height; y += dash + gap) {
      final endY = math.min(y + dash, size.height).toDouble();
      canvas.drawLine(Offset(0, y), Offset(0, endY), paint);
      canvas.drawLine(Offset(size.width, y), Offset(size.width, endY), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _DottedSelectionPainter oldDelegate) => false;
}

class _CaptionGestureTransform extends StatefulWidget {
  const _CaptionGestureTransform({
    required this.enabled,
    required this.centerX,
    required this.centerY,
    required this.scale,
    required this.rotationDegrees,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.onChanged,
    required this.child,
  });

  final bool enabled;
  final double centerX;
  final double centerY;
  final double scale;
  final double rotationDegrees;
  final double canvasWidth;
  final double canvasHeight;
  final void Function(double, double, double, double)? onChanged;
  final Widget child;

  @override
  State<_CaptionGestureTransform> createState() => _CaptionGestureTransformState();
}

class _CaptionGestureTransformState extends State<_CaptionGestureTransform> {
  bool _gesturing = false;
  late double _startX = widget.centerX;
  late double _startY = widget.centerY;
  late double _currentX = widget.centerX;
  late double _currentY = widget.centerY;
  late double _startScale = widget.scale;
  late double _startRotation = widget.rotationDegrees;

  @override
  void didUpdateWidget(covariant _CaptionGestureTransform oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_gesturing && (oldWidget.centerX != widget.centerX || oldWidget.centerY != widget.centerY ||
        oldWidget.scale != widget.scale || oldWidget.rotationDegrees != widget.rotationDegrees)) {
      _startX = widget.centerX;
      _startY = widget.centerY;
      _currentX = widget.centerX;
      _currentY = widget.centerY;
      _startScale = widget.scale;
      _startRotation = widget.rotationDegrees;
    }
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onScaleStart: widget.enabled ? (_) {
          _gesturing = true;
          _startX = widget.centerX;
          _startY = widget.centerY;
          _currentX = widget.centerX;
          _currentY = widget.centerY;
          _startScale = widget.scale;
          _startRotation = widget.rotationDegrees;
        } : null,
        onScaleUpdate: widget.enabled ? (details) {
          _currentX = (_currentX + details.focalPointDelta.dx / widget.canvasWidth)
              .clamp(0.05, 0.95).toDouble();
          _currentY = (_currentY + details.focalPointDelta.dy / widget.canvasHeight)
              .clamp(0.05, 0.95).toDouble();
          widget.onChanged?.call(
            _currentX,
            _currentY,
            (_startScale * details.scale).clamp(0.5, 2.0).toDouble(),
            (_startRotation + details.rotation * 180 / math.pi).clamp(-30, 30).toDouble(),
          );
        } : null,
        onScaleEnd: widget.enabled ? (_) => _gesturing = false : null,
        child: Transform.rotate(
          angle: widget.rotationDegrees * math.pi / 180,
          child: Transform.scale(scale: widget.scale, child: widget.child),
        ),
      );
}
