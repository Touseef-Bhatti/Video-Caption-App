// Private, offline export entrypoint. It has no auth, storage or API access.
import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'core/caption_fonts.dart';

import 'models/caption.dart';
import 'widgets/caption_scene.dart';

@JS('captionLoad')
external set captionLoad(JSFunction value);
@JS('captionFrame')
external set captionFrame(JSFunction value);
@JS('captionSetTime')
external set captionSetTime(JSFunction value);
@JS('captionReady')
external set captionReady(JSBoolean value);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _Renderer());
}

class _Renderer extends StatefulWidget {
  const _Renderer();
  @override
  State<_Renderer> createState() => _RendererState();
}

class _RendererState extends State<_Renderer> {
  final boundary = GlobalKey();
  Map<String, dynamic>? scene;
  CaptionTranscript? transcript;
  double time = 0;

  @override
  void initState() {
    super.initState();
    captionLoad = ((JSString input) => applyScene(input.toDart).toJS).toJS;
    captionFrame = ((JSNumber seconds) => capture(seconds.toDartDouble).toJS).toJS;
    captionSetTime =
        ((JSNumber seconds) => setFrameTime(seconds.toDartDouble).toJS).toJS;
    captionReady = true.toJS;
  }

  Future<void> applyScene(String input) async {
    final data = jsonDecode(input) as Map<String, dynamic>;
    if (data['renderer_version'] != captionRendererVersion) {
      throw StateError('Caption renderer version mismatch. Rebuild the renderer.');
    }
    final nextTranscript = CaptionTranscript.fromJson(
        data['caption_data'] as Map<String, dynamic>);
    final overrides = StyleOverrides.fromJson(
        data['style_overrides'] as Map<String, dynamic>?);
    final fonts = <String>{};
    final words = <String>[for (final segment in nextTranscript.segments) segment.text]
        .join(' ');
    for (final segment in nextTranscript.segments) {
      final languageFont = captionFontForText(segment.text, nextTranscript.language);
      final font = segment.fontFamily == 'auto'
          ? languageFont
          : segment.fontFamily ?? overrides.fontFamily ?? languageFont;
      if ({
        'Caption Sans', 'Caption Arabic', 'Caption Urdu', 'Roboto', 'Open Sans',
        'Lato', 'Montserrat', 'Poppins', 'Inter'
      }.contains(font)) fonts.add(font);
    }
    if (fonts.isEmpty) fonts.add('Caption Sans');
    if (RegExp(r'[\u2600-\u27BF]').hasMatch(words)) {
      fonts.add('Caption Symbols');
    }
    if (RegExp(r'[\u{1F000}-\u{1FAFF}]', unicode: true).hasMatch(words)) {
      fonts.add('Caption Emoji');
    }
    await loadCaptionFonts(families: fonts);
    setState(() {
      scene = data;
      transcript = nextTranscript;
    });
  }

  Future<void> setFrameTime(double seconds) async {
    setState(() => time = seconds);
    await WidgetsBinding.instance.endOfFrame;
  }

  Future<JSString> capture(double seconds) async {
    await setFrameTime(seconds);
    final renderObject = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await renderObject.toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      return base64Encode(bytes!.buffer.asUint8List()).toJS;
    } finally {
      image.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: RepaintBoundary(
      key: boundary,
      child: transcript == null ? const SizedBox.expand() : CaptionScene(
        transcript: transcript!,
        presetId: scene!['style_preset'] as String,
        overrides: StyleOverrides.fromJson(scene!['style_overrides'] as Map<String, dynamic>?),
        time: time,
        canvasScale: (scene!['canvas_scale'] as num?)?.toDouble() ?? 1,
      ),
    ),
  );
}

