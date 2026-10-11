import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../models/caption.dart';

/// Selectable premium preset tile with a small live motion demonstration.
class CaptionStyleCard extends StatefulWidget {
  const CaptionStyleCard({
    super.key,
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  final CaptionPresetInfo preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<CaptionStyleCard> createState() => _CaptionStyleCardState();
}

class _CaptionStyleCardState extends State<CaptionStyleCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preset = widget.preset;
    final weight = preset.bold ? FontWeight.w800 : FontWeight.w500;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: widget.onTap,
      child: Container(
        width: 184,
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: widget.selected
              ? theme.colorScheme.primary.withValues(alpha: 0.07)
              : null,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: widget.selected
                ? theme.colorScheme.primary
                : (theme.dividerTheme.color ?? Colors.grey),
            width: widget.selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 66,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  if (preset.motion == 'none') return child!;
                  final t = _controller.value;
                  final pulse = math.sin(t * math.pi);
                  final slide = preset.motion == 'slide' ? (1 - t) * 8 : 0.0;
                  final turn =
                      preset.motion == 'impact' ? (1 - t) * -0.035 : 0.0;
                  return Transform.translate(
                    offset: Offset(
                        slide, preset.motion == 'bounce' ? -pulse * 3 : 0),
                    child: Transform.rotate(
                      angle: turn,
                      child: Transform.scale(
                        scale: 1 +
                            pulse *
                                (preset.motion == 'pop' ||
                                        preset.motion == 'impact'
                                    ? 0.12
                                    : 0.04),
                        child: child,
                      ),
                    ),
                  );
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  decoration: BoxDecoration(
                    color: preset.backgroundPreview,
                    borderRadius: BorderRadius.circular(7),
                    border: preset.id == 'headline' || preset.id == 'news'
                        ? Border(
                            left: BorderSide(
                                color: preset.highlightPreview, width: 4))
                        : null,
                  ),
                  child: Text.rich(
                    TextSpan(children: [
                      if (preset.effect.isNotEmpty)
                        TextSpan(
                            text: '${preset.effect} ',
                            style: TextStyle(color: preset.emphasisPreview)),
                      TextSpan(
                          text: 'Make ',
                          style: TextStyle(color: preset.primaryPreview)),
                      TextSpan(
                          text: 'words ',
                          style: TextStyle(color: preset.highlightPreview)),
                      TextSpan(
                          text: 'move',
                          style: TextStyle(color: preset.emphasisPreview)),
                    ]),
                    style: TextStyle(fontSize: 13, fontWeight: weight),
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                    child:
                        Text(preset.label, style: theme.textTheme.titleMedium)),
                Icon(preset.motion == 'none' ? Icons.subtitles_outlined : Icons.auto_awesome,
                    size: 15),
              ],
            ),
            Text(
              preset.description,
              style: theme.textTheme.bodySmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
