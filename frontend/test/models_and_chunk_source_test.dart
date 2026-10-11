import 'dart:typed_data';

import 'package:caption_app/core/chunk_source/chunk_source_base.dart';
import 'package:caption_app/core/chunked_uploader.dart';
import 'package:caption_app/models/caption.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CaptionWord', () {
    test('cycleStyle goes normal -> highlight -> emphasis -> normal', () {
      var w =
          CaptionWord(text: 'hi', start: 0, end: 1, style: WordStyle.normal);
      w = w.cycleStyle();
      expect(w.style, WordStyle.highlight);
      w = w.cycleStyle();
      expect(w.style, WordStyle.emphasis);
      w = w.cycleStyle();
      expect(w.style, WordStyle.normal);
    });

    test('JSON round-trip preserves fields', () {
      final w = CaptionWord(
          text: 'x', start: 1.5, end: 2.0, style: WordStyle.emphasis);
      final back = CaptionWord.fromJson(w.toJson());
      expect(back.text, 'x');
      expect(back.start, 1.5);
      expect(back.style, WordStyle.emphasis);
    });
  });

  group('StyleOverrides', () {
    test('toJson omits unset fields', () {
      const o = StyleOverrides(primaryColor: '#FFFFFF');
      expect(o.toJson(), {'primary_color': '#FFFFFF'});
    });

    test('JSON round-trip preserves normalized drag position', () {
      const o = StyleOverrides(positionX: 0.27, positionY: 0.64);
      final back = StyleOverrides.fromJson(o.toJson());
      expect(back.positionX, 0.27);
      expect(back.positionY, 0.64);
    });
  });

  test('10 premium motion caption presets are defined', () {
    expect(kCaptionPresets.length, 10);
    expect(kCaptionPresets.every((p) => p.motion.isNotEmpty), isTrue);
  });

  group('BytesChunkSource', () {
    final data = Uint8List.fromList(List.generate(10, (i) => i));

    test('reads a middle chunk', () async {
      final s = BytesChunkSource(data);
      expect(await s.readChunk(2, 3), [2, 3, 4]);
    });

    test('final chunk may be shorter than requested', () async {
      final s = BytesChunkSource(data);
      expect(await s.readChunk(8, 5), [8, 9]);
    });

    test('reading past the end returns empty', () async {
      final s = BytesChunkSource(data);
      expect(await s.readChunk(10, 4), isEmpty);
    });
  });

  test('PendingUpload JSON round-trip', () {
    final p = PendingUpload(
      uploadId: 'u1',
      projectName: 'P',
      fileName: 'a.mp4',
      contentType: 'video/mp4',
      totalSize: 100,
      chunkSize: 10,
      totalChunks: 10,
      filePath: '/tmp/a.mp4',
    );
    final back = PendingUpload.fromJson(p.toJson());
    expect(back.uploadId, 'u1');
    expect(back.totalChunks, 10);
    expect(back.filePath, '/tmp/a.mp4');
  });
}
