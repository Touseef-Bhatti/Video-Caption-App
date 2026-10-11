import 'dart:typed_data';

import 'chunk_source_base.dart';
import 'chunk_source_web.dart' if (dart.library.io) 'chunk_source_io.dart' as impl;

export 'chunk_source_base.dart' show ChunkSource;

/// Picks the platform implementation at compile time: disk-backed on
/// Android/iOS/desktop (dart:io available), in-memory on web.
/// Pass [filePath] on IO platforms and [bytes] on web.
ChunkSource createChunkSource({String? filePath, Uint8List? bytes, required int totalSize}) =>
    impl.createChunkSource(filePath: filePath, bytes: bytes, totalSize: totalSize);
