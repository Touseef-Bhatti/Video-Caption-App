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
@JS('captionReady')
external set captionReady(JSBoolean value);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadCaptionFonts();
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
    captionLoad = ((JSString input) {
      final data = jsonDecode(input.toDart) as Map<String, dynamic>;
      if (data['renderer_version'] != captionRendererVersion) {
        throw StateError('Caption renderer version mismatch. Rebuild the renderer.');
      }
      setState(() {
        scene = data;
        transcript = CaptionTranscript.fromJson(data['caption_data'] as Map<String, dynamic>);
      });
    }).toJS;
    captionFrame = ((JSNumber seconds) => capture(seconds.toDartDouble).toJS).toJS;
    captionReady = true.toJS;
  }

  Future<JSString> capture(double seconds) async {
    setState(() => time = seconds);
    await WidgetsBinding.instance.endOfFrame;
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
      ),
    ),
  );
}
