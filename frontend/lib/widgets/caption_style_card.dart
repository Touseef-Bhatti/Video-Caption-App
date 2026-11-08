import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../models/caption.dart';

/// A compact preset card with a readable preview and clear selected state.
class CaptionStyleCard extends StatefulWidget {
  const CaptionStyleCard({
    super.key,
    required this.preset,
    required this.selected,
    required this.onTap,
    required this.width,
  });

  final CaptionPresetInfo preset;
  final bool selected;
  final VoidCallback onTap;
  final double width;

  @override
  State<CaptionStyleCard> createState() => _CaptionStyleCardState();
}

class _CaptionStyleCardState extends State<CaptionStyleCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant CaptionStyleCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected ||
        oldWidget.preset.motion != widget.preset.motion) {
      _syncAnimation();
    }
  }

  void _syncAnimation() {
    if (widget.selected && widget.preset.motion != 'none') {
      _controller.repeat(reverse: true);
    } else {
      _controller
        ..stop()
        ..value = 0;
    }
  }

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
    final selectedColor = theme.colorScheme.primary;

    return SizedBox(
      width: widget.width,
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: widget.selected
                  ? selectedColor.withValues(alpha: 0.045)
                  : Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: widget.selected ? selectedColor : _cardBorder(theme),
                width: widget.selected ? 1.7 : 1,
              ),
              boxShadow: widget.selected
                  ? [
                      BoxShadow(
                        color: selectedColor.withValues(alpha: 0.10),
                        blurRadius: 12,
                        offset: const Offset(0, 3),
                      ),
                    ]
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: SizedBox(
                    height: 62,
                    width: double.infinity,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Positioned.fill(
                            child: _PreviewBackdrop(preset: preset)),
                        AnimatedBuilder(
                          animation: _controller,
                          builder: (context, child) {
                            if (!widget.selected || preset.motion == 'none') {
                              return child!;
                            }
                            final t = _controller.value;
                            final pulse = math.sin(t * math.pi);
                            final slide =
                                preset.motion == 'slide' ? (1 - t) * 5 : 0.0;
                            final turn = preset.motion == 'impact'
                                ? (1 - t) * -0.025
                                : 0.0;
                            return Transform.translate(
                              offset: Offset(
                                slide,
                                preset.motion == 'bounce' ? -pulse * 2 : 0,
                              ),
                              child: Transform.rotate(
                                angle: turn,
                                child: Transform.scale(
                                  scale: 1 +
                                      pulse *
                                          (preset.motion == 'pop' ||
                                                  preset.motion == 'impact'
                                              ? 0.08
                                              : 0.025),
                                  child: child,
                                ),
                              ),
                            );
                          },
                          child: _CaptionSample(preset: preset, weight: weight),
                        ),
                        if (widget.selected)
                          Positioned(
                            top: 6,
                            right: 6,
                            child: Container(
                              width: 19,
                              height: 19,
                              decoration: BoxDecoration(
                                color: selectedColor,
                                shape: BoxShape.circle,
                                border: Border.all(
                                    color: Colors.white.withValues(alpha: .9)),
                              ),
                              child: const Icon(Icons.check_rounded,
                                  color: Colors.white, size: 13),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  preset.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: const Color(0xFF252433),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  preset.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    height: 1.2,
                    color: _editorMuted,
                    fontSize: 10.5,
                  ),
                ),
                const SizedBox(height: 7),
                Row(
                  children: [
                    Icon(
                      preset.motion == 'none'
                          ? Icons.pause_circle_outline_rounded
                          : Icons.play_circle_outline_rounded,
                      size: 14,
                      color: _editorMuted,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      preset.motion == 'none' ? 'Static' : 'Motion',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: _editorMuted,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    if (widget.selected)
                      Text(
                        'Selected',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: selectedColor,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _cardBorder(ThemeData theme) =>
      theme.dividerTheme.color ?? const Color(0xFFE3E4ED);
}

class _CaptionSample extends StatelessWidget {
  const _CaptionSample({required this.preset, required this.weight});

  final CaptionPresetInfo preset;
  final FontWeight weight;

  @override
  Widget build(BuildContext context) {
    final isGlass = preset.id == 'liquid_glass';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: isGlass ? null : preset.backgroundPreview,
        gradient: isGlass
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0x88FFFFFF),
                  Color(0x30C7E7FF),
                  Color(0x55E5D8FF),
                ],
              )
            : null,
        borderRadius: BorderRadius.circular(7),
        boxShadow: isGlass
            ? const [
                BoxShadow(
                  color: Color(0x6687CFFF),
                  blurRadius: 10,
                  offset: Offset(0, 2),
                ),
              ]
            : null,
        border: isGlass
            ? Border.all(color: Colors.white.withValues(alpha: 0.78))
            : preset.id == 'headline' || preset.id == 'news'
                ? Border(
                    left: BorderSide(color: preset.highlightPreview, width: 3),
                  )
                : null,
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: 'Make ',
              style: TextStyle(color: preset.primaryPreview),
            ),
            TextSpan(
              text: 'words ',
              style: TextStyle(color: preset.highlightPreview),
            ),
            TextSpan(
              text: 'move',
              style: TextStyle(color: preset.emphasisPreview),
            ),
          ],
        ),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.clip,
        style: TextStyle(fontSize: 11, fontWeight: weight),
      ),
    );
  }
}

class _PreviewBackdrop extends StatelessWidget {
  const _PreviewBackdrop({required this.preset});

  final CaptionPresetInfo preset;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: preset.id == 'liquid_glass'
              ? const [Color(0xFF45546B), Color(0xFF75689B), Color(0xFF335B68)]
              : const [Color(0xFF252735), Color(0xFF41455A)],
        ),
      ),
      child: CustomPaint(
        painter: _PreviewTexturePainter(),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _PreviewTexturePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white.withValues(alpha: 0.07);
    canvas.drawCircle(Offset(size.width * .14, size.height * .2), 23, paint);
    canvas.drawCircle(Offset(size.width * .88, size.height * .78), 30, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

const _editorMuted = Color(0xFF73758B);

class CaptionTemplatePicker extends StatefulWidget {
  const CaptionTemplatePicker({
    super.key,
    required this.presets,
    required this.selectedPresetId,
    required this.onSelected,
  });

  final List<CaptionPresetInfo> presets;
  final String selectedPresetId;
  final ValueChanged<String> onSelected;

  @override
  State<CaptionTemplatePicker> createState() => _CaptionTemplatePickerState();
}

class _CaptionTemplatePickerState extends State<CaptionTemplatePicker> {
  String _query = '';
  String _motionFilter = 'All';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query = _query.trim().toLowerCase();
    final presets = widget.presets.where((preset) {
      final matchesQuery = query.isEmpty ||
          preset.label.toLowerCase().contains(query) ||
          preset.description.toLowerCase().contains(query);
      final matchesMotion = _motionFilter == 'All' ||
          (_motionFilter == 'Motion'
              ? preset.motion != 'none'
              : preset.motion == 'none');
      return matchesQuery && matchesMotion;
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          onChanged: (value) => setState(() => _query = value),
          decoration: InputDecoration(
            hintText: 'Search templates',
            prefixIcon: const Icon(Icons.search_rounded, size: 19),
            isDense: true,
            filled: true,
            fillColor: const Color(0xFFF8F8FC),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(11),
              borderSide: const BorderSide(color: Color(0xFFE3E4ED)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(11),
              borderSide: const BorderSide(color: Color(0xFFE3E4ED)),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 7,
          children: [
            for (final filter in ['All', 'Motion', 'Static'])
              ChoiceChip(
                label: Text(filter),
                selected: _motionFilter == filter,
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                labelStyle: theme.textTheme.labelMedium?.copyWith(
                  color: _motionFilter == filter
                      ? theme.colorScheme.primary
                      : _editorMuted,
                  fontWeight: FontWeight.w600,
                ),
                backgroundColor: Colors.white,
                selectedColor: theme.colorScheme.primary.withValues(alpha: .08),
                side: BorderSide(
                  color: _motionFilter == filter
                      ? theme.colorScheme.primary.withValues(alpha: .55)
                      : const Color(0xFFE3E4ED),
                ),
                onSelected: (_) => setState(() => _motionFilter = filter),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '${presets.length} ${presets.length == 1 ? 'template' : 'templates'}',
          style: theme.textTheme.labelSmall?.copyWith(color: _editorMuted),
        ),
        const SizedBox(height: 8),
        if (presets.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 22),
            child: Column(
              children: [
                const Icon(Icons.search_off_rounded,
                    size: 28, color: _editorMuted),
                const SizedBox(height: 6),
                Text('No templates found',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: _editorMuted)),
              ],
            ),
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              const spacing = 10.0;
              final cardWidth = ((constraints.maxWidth - spacing) / 2)
                  .clamp(116.0, 210.0)
                  .toDouble();
              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: [
                  for (final preset in presets)
                    CaptionStyleCard(
                      preset: preset,
                      width: cardWidth,
                      selected: preset.id == widget.selectedPresetId,
                      onTap: () => widget.onSelected(preset.id),
                    ),
                ],
              );
            },
          ),
      ],
    );
  }
}
