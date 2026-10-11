import 'dart:io';
import 'dart:typed_data';

import 'chunk_source_base.dart';

/// Reads chunks straight from disk with a RandomAccessFile, so a multi-GB
/// video is never loaded into memory -- only one chunk (a few MB) at a time.
class FileChunkSource implements ChunkSource {
  FileChunkSource._(this._raf, this.totalSize);

  final RandomAccessFile _raf;

  @override
  final int totalSize;

  static Future<FileChunkSource> open(String path) async {
    final file = File(path);
    final raf = await file.open();
    return FileChunkSource._(raf, await raf.length());
  }

  @override
  Future<Uint8List> readChunk(int start, int length) async {
    if (start >= totalSize) return Uint8List(0);
    await _raf.setPosition(start);
    final toRead = (start + length) > totalSize ? totalSize - start : length;
    return _raf.read(toRead);
  }

  @override
  Future<void> dispose() => _raf.close();
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
