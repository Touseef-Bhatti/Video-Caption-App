import 'package:flutter/services.dart';

/// Preview and export await identical, bundled fonts before drawing captions.
Future<void> loadCaptionFonts() async {
  for (final entry in {
    'Caption Sans': ['NotoSans-Regular.ttf', 'NotoSans-Bold.ttf'],
    'Caption Arabic': ['NotoNaskhArabic-Regular.ttf'],
    'Caption Urdu': ['NotoNastaliqUrdu-Regular.ttf'],
    'Caption Symbols': ['NotoSansSymbols2-Regular.ttf'],
    'Caption Emoji': ['NotoColorEmoji.ttf'],
  }.entries) {
    final loader = FontLoader(entry.key);
    for (final file in entry.value) {
      loader.addFont(rootBundle.load('assets/fonts/$file'));
    }
    await loader.load();
  }
}
