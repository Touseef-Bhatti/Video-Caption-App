import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/caption_fonts.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadCaptionFonts();
  runApp(const ProviderScope(child: CaptionApp()));
}
