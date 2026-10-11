import 'dart:typed_data';

import 'chunk_source_base.dart';

/// Default (non-IO) implementation -- used for Flutter Web.
///
/// Tradeoff, stated plainly: on web the whole picked file lives in browser
/// memory as bytes (the File System Access API is not universally
/// available), so very large videos are bounded by what the browser tab can
/// hold. Also, after a full page reload the bytes are gone, so resuming
/// requires the user to re-pick the same file; the uploader then asks the
/// server which chunks it already has and only sends the missing ones.
ChunkSource createChunkSource({String? filePath, Uint8List? bytes, required int totalSize}) {
  if (bytes == null) {
    throw UnsupportedError('Web uploads require the file bytes (pick the file with withData: true).');
  }
  return BytesChunkSource(bytes);
}
