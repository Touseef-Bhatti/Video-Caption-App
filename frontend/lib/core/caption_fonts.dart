import 'package:flutter/services.dart';

/// Preview and export await identical, bundled fonts before drawing captions.
Future<void> loadCaptionFonts({Set<String>? families}) async {
  final available = {
    'Caption Sans': ['NotoSans-Regular.ttf', 'NotoSans-Bold.ttf'],
    'Caption Arabic': ['NotoNaskhArabic-Regular.ttf'],
    'Caption Urdu': ['NotoNastaliqUrdu-Regular.ttf'],
    'Roboto': ['Roboto-Variable.ttf'],
    'Open Sans': ['OpenSans-Variable.ttf'],
    'Lato': ['Lato-Regular.ttf', 'Lato-Bold.ttf'],
    'Montserrat': ['Montserrat-Variable.ttf'],
    'Poppins': ['Poppins-Regular.ttf', 'Poppins-Bold.ttf'],
    'Inter': ['Inter-Variable.ttf'],
    'Caption Symbols': ['NotoSansSymbols2-Regular.ttf'],
    'Caption Emoji': ['NotoColorEmoji.ttf'],
  };
  final requested = families ?? available.keys.toSet();
  for (final entry in available.entries.where((entry) => requested.contains(entry.key))) {
    final loader = FontLoader(entry.key);
    for (final file in entry.value) {
      loader.addFont(rootBundle.load('assets/fonts/$file'));
    }
    await loader.load();
  }
}
