import 'package:flutter/material.dart';

import '../core/eyedropper/eyedropper.dart';
import '../core/theme.dart';
import '../models/caption.dart';

const _swatches = <String>[
  '#FFFFFF',
  '#000000',
  '#FFD700',
  '#FF6600',
  '#FF3B30',
  '#34C759',
  '#0A84FF',
  '#5E5CE6',
  '#FF2D92',
  '#00E5FF',
  '#B8860B',
  '#9E9E9E',
];

/// Premium color control: quick swatches, full HSV picker, browser screen
/// eyedropper (Chrome/Edge), and a validated #RRGGBB field.
class ColorField extends StatefulWidget {
  const ColorField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String? value;
  final ValueChanged<String> onChanged;

  @override
  State<ColorField> createState() => _ColorFieldState();
}

class _ColorFieldState extends State<ColorField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.value ?? '');
  bool _invalid = false;

  static final _hexPattern = RegExp(r'^#[0-9A-Fa-f]{6}$');

  @override
  void didUpdateWidget(covariant ColorField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value && widget.value != _controller.text) {
      _controller.text = widget.value ?? '';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _apply(String hex) {
    final normalized = hex.startsWith('#') ? hex : '#$hex';
    if (!_hexPattern.hasMatch(normalized)) return;
    final value = normalized.toUpperCase();
    _controller.text = value;
    setState(() => _invalid = false);
    widget.onChanged(value);
  }

  void _submit(String text) {
    final normalized = text.startsWith('#') ? text : '#$text';
    if (_hexPattern.hasMatch(normalized)) {
      _apply(normalized);
    } else {
      setState(() => _invalid = text.isNotEmpty);
    }
  }

  Future<void> _openPicker() async {
    final initial = widget.value != null && _hexPattern.hasMatch(widget.value!)
        ? colorFromHex(widget.value!)
        : Colors.white;
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _ColorPickerDialog(initial: initial),
    );
    if (result != null) _apply(result);
  }

  Future<void> _pickFromScreen() async {
    final result = await pickScreenColor();
    if (result != null) _apply(result);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = widget.value != null && _hexPattern.hasMatch(widget.value!)
        ? colorFromHex(widget.value!)
        : Colors.transparent;
    return SizedBox(
      width: 190,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.label, style: theme.textTheme.bodySmall),
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: selected,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  border: Border.all(color: theme.dividerColor),
                ),
              ),
              const SizedBox(width: 6),
              Tooltip(
                message: 'Open full color picker',
                child: IconButton.filledTonal(
                  onPressed: _openPicker,
                  icon: const Icon(Icons.palette_outlined, size: 19),
                ),
              ),
              if (supportsScreenColorPicker) ...[
                const SizedBox(width: 4),
                Tooltip(
                  message: 'Pick a color from your screen',
                  child: IconButton.filledTonal(
                    onPressed: _pickFromScreen,
                    icon: const Icon(Icons.colorize_outlined, size: 19),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final hex in _swatches)
                GestureDetector(
                  onTap: () => _apply(hex),
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: colorFromHex(hex),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: widget.value?.toUpperCase() == hex
                            ? theme.colorScheme.primary
                            : Colors.grey.shade400,
                        width: widget.value?.toUpperCase() == hex ? 3 : 1,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _controller,
            maxLength: 7,
            onChanged: _submit,
            decoration: InputDecoration(
              counterText: '',
              hintText: '#RRGGBB',
              isDense: true,
              errorText: _invalid ? 'Use #RRGGBB' : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _ColorPickerDialog extends StatefulWidget {
  const _ColorPickerDialog({required this.initial});

  final Color initial;

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  late HSVColor _hsv = HSVColor.fromColor(widget.initial);

  void _pick(Offset local, Size size) {
    final saturation = (local.dx / size.width).clamp(0.0, 1.0);
    final value = (1 - local.dy / size.height).clamp(0.0, 1.0);
    setState(() => _hsv = _hsv.withSaturation(saturation).withValue(value));
  }

  @override
  Widget build(BuildContext context) {
    final color = _hsv.toColor();
    return AlertDialog(
      title: const Text('Pick any color'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                const height = 190.0;
                final size = Size(constraints.maxWidth, height);
                return GestureDetector(
                  onTapDown: (d) => _pick(d.localPosition, size),
                  onPanUpdate: (d) => _pick(d.localPosition, size),
                  child: CustomPaint(
                    size: size,
                    painter: _SaturationValuePainter(hue: _hsv.hue),
                    foregroundPainter: _PickerMarkerPainter(
                      position: Offset(
                        _hsv.saturation * size.width,
                        (1 - _hsv.value) * size.height,
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                const Text('Hue'),
                Expanded(
                  child: Slider(
                    min: 0,
                    max: 360,
                    value: _hsv.hue,
                    onChanged: (v) => setState(() => _hsv = _hsv.withHue(v)),
                  ),
                ),
              ],
            ),
            Container(
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Text(
                colorToHex(color),
                style: TextStyle(
                  color: _hsv.value > 0.58 ? Colors.black : Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, colorToHex(color)),
          child: const Text('Use color'),
        ),
      ],
    );
  }
}

class _SaturationValuePainter extends CustomPainter {
  const _SaturationValuePainter({required this.hue});

  final double hue;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final hueColor = HSVColor.fromAHSV(1, hue, 1, 1).toColor();
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [Colors.white, hueColor],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(covariant _SaturationValuePainter oldDelegate) =>
      oldDelegate.hue != hue;
}

class _PickerMarkerPainter extends CustomPainter {
  const _PickerMarkerPainter({required this.position});

  final Offset position;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawCircle(position, 8, Paint()..color = Colors.white);
    canvas.drawCircle(
      position,
      8,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _PickerMarkerPainter oldDelegate) =>
      oldDelegate.position != position;
}
