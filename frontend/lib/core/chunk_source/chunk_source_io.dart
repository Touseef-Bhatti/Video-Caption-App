import 'dart:io';
import 'dart:typed_data';

import 'chunk_source_base.dart';

/// Reads chunks straight from disk with independent handles, allowing parallel
/// reads without sharing a seek position.
class FileChunkSource implements ChunkSource {
  FileChunkSource._(this._file, this.totalSize);

  final File _file;

  @override
  final int totalSize;

  static Future<FileChunkSource> open(String path) async {
    final file = File(path);
    return FileChunkSource._(file, await file.length());
  }

  @override
  Future<Uint8List> readChunk(int start, int length) async {
    if (start >= totalSize) return Uint8List(0);
    final toRead = (start + length) > totalSize ? totalSize - start : length;
    final raf = await _file.open();
    try {
      await raf.setPosition(start);
      return await raf.read(toRead);
    } finally {
      await raf.close();
    }
  }

  @override
  Future<void> dispose() async {}
}

/// IO implementation. Opening the file is async, so this returns a source
/// that opens lazily on first read.
ChunkSource createChunkSource({String? filePath, Uint8List? bytes, required int totalSize}) {
  if (filePath != null) return _LazyFileChunkSource(filePath, totalSize);
  if (bytes != null) return BytesChunkSource(bytes);
  throw ArgumentError('Either filePath or bytes is required.');
}

class _LazyFileChunkSource implements ChunkSource {
  _LazyFileChunkSource(this._path, this.totalSize);

  final String _path;
  FileChunkSource? _inner;

  @override
  final int totalSize;

  @override
  Future<Uint8List> readChunk(int start, int length) async {
    _inner ??= await FileChunkSource.open(_path);
    return _inner!.readChunk(start, length);
  }

  @override
  Future<void> dispose() async => _inner?.dispose();
}
