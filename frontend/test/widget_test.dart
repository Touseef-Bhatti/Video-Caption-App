import 'package:caption_app/models/caption.dart';
import 'package:caption_app/widgets/caption_scene.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final transcript = CaptionTranscript(language: 'English', segments: [
    CaptionSegment(start: 0, end: 2, text: 'Hello friend', weight: 0.9, words: [
      CaptionWord(text: 'Hello', start: 0.2, end: 0.8, style: WordStyle.highlight),
      CaptionWord(text: 'friend', start: 1, end: 1.8, style: WordStyle.emphasis),
    ]),
  ]);

  Widget scene(double time, {double width = 360, double height = 640,
      StyleOverrides overrides = const StyleOverrides(), String preset = 'classic'}) =>
      MaterialApp(home: Center(child: SizedBox(width: width, height: height,
        child: CaptionScene(transcript: transcript, presetId: preset,
          overrides: overrides, time: time))));

  testWidgets('captions stay visible between word windows and keep their colors', (tester) async {
    await tester.pumpWidget(scene(0.9));
    expect(find.text('Hello'), findsOneWidget);
    expect(find.text('friend'), findsOneWidget);
    expect(tester.widget<Text>(find.text('Hello')).style!.color,
        presetInfoFor('classic').highlightPreview);
    await tester.pumpWidget(scene(2));
    expect(find.text('Hello'), findsNothing);
  });

  testWidgets('resizing the preview preserves normalized text geometry', (tester) async {
    await tester.pumpWidget(scene(0.5, width: 180, height: 320));
    final small = tester.getRect(find.text('Hello'));
    await tester.pumpWidget(scene(0.5, width: 270, height: 480));
    final large = tester.getRect(find.text('Hello'));
    expect(large.width / small.width, closeTo(1.5, 0.001));
    expect(large.height / small.height, closeTo(1.5, 0.001));
  });

  testWidgets('all presets accept explicit colors, size, and dragged placement', (tester) async {
    for (final preset in kCaptionPresets) {
      await tester.pumpWidget(scene(0.5, preset: preset.id,
        overrides: const StyleOverrides(highlightColor: '#123456', fontSize: 70,
          positionX: 0.3, positionY: 0.4, bold: false)));
      final text = tester.widget<Text>(find.text('Hello'));
      expect(text.style!.color, const Color(0xff123456));
      expect(text.style!.fontSize, 70);
      expect(tester.takeException(), isNull);
    }
  });

  test('legacy presets resolve consistently', () {
    expect(presetInfoFor('dynamic').id, 'classic');
    expect(presetInfoFor('elegant').id, 'cinematic');
  });
}
