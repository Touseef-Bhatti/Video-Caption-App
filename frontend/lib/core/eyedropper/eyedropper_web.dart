import 'dart:js_interop';

@JS('EyeDropper')
external JSFunction? get _eyeDropperConstructor;

@JS('EyeDropper')
extension type _EyeDropper._(JSObject _) implements JSObject {
  external factory _EyeDropper();
  external JSPromise<_EyeDropperResult> open();
}

extension type _EyeDropperResult(JSObject _) implements JSObject {
  external String get sRGBHex;
}

bool get supportsScreenColorPicker => _eyeDropperConstructor != null;

Future<String?> pickScreenColor() async {
  if (!supportsScreenColorPicker) return null;
  try {
    final result = await _EyeDropper().open().toDart;
    return result.sRGBHex.toUpperCase();
  } catch (_) {
    // The browser rejects the promise when the user presses Escape.
    return null;
  }
}
