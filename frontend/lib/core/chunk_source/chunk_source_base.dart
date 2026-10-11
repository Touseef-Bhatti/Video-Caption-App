import 'dart:typed_data';

/// Reads arbitrary byte ranges out of a picked file so the chunked
/// uploader can PUT one fixed-size slice at a time -- including re-reading
/// a single chunk by index on a retry, without re-reading everything
/// before it.
abstract class ChunkSource {
  int get totalSize;

  /// Reads up to [length] bytes starting at [start]. Returns fewer bytes
  /// only for the final chunk, where [start] + [length] runs past the end.
  Future<Uint8List> readChunk(int start, int length);

  Future<void> dispose();
}

/// In-memory source. Used on Flutter Web (no filesystem path exists there;
/// file_picker hands back the whole file as bytes) and as a fallback on IO
/// platforms if a picker returns bytes instead of a path.
class BytesChunkSource implements ChunkSource {
  BytesChunkSource(this._bytes);

  final Uint8List _bytes;

  @override
  int get totalSize => _bytes.length;

  @override
  Future<Uint8List> readChunk(int start, int length) async {
    if (start >= _bytes.length) return Uint8List(0);
    final end = (start + length) > _bytes.length ? _bytes.length : start + length;
    return Uint8List.sublistView(_bytes, start, end);
  }

  @override
  Future<void> dispose() async {}
}
