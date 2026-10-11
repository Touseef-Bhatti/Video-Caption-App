import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'api_exception.dart';
import 'chunk_source/chunk_source.dart';

enum ChunkedUploadStatus { idle, initializing, uploading, completing, completed, cancelled, failed }

class ChunkedUploadProgress {
  const ChunkedUploadProgress({
    this.status = ChunkedUploadStatus.idle,
    this.uploadedChunks = 0,
    this.totalChunks = 0,
    this.bytesUploaded = 0,
    this.totalBytes = 0,
    this.retryingChunk,
    this.errorMessage,
    this.projectId,
    this.jobId,
    this.uploadId,
    this.needsReselect = false,
  });

  /// True when the failure is "the original file can't be read anymore"
  /// (moved/purged, or a lost iOS security-scoped path): the UI should ask
  /// the user to pick the same file again, then call resume().
  final bool needsReselect;

  final ChunkedUploadStatus status;
  final int uploadedChunks;
  final int totalChunks;
  final int bytesUploaded;
  final int totalBytes;

  /// Non-null while a failed chunk is waiting out its backoff before retry.
  final int? retryingChunk;
  final String? errorMessage;
  final String? projectId;
  final String? jobId;
  final String? uploadId;

  double get fraction => totalBytes == 0 ? 0 : (bytesUploaded / totalBytes).clamp(0.0, 1.0);
  bool get isFinished =>
      status == ChunkedUploadStatus.completed ||
      status == ChunkedUploadStatus.cancelled ||
      status == ChunkedUploadStatus.failed;
}

/// A locally persisted record of an unfinished upload. It holds only
/// identifying info -- *which* chunks already arrived is always asked of the
/// server (GET /status), never trusted from local state, so this record can
/// never drift out of sync with what the server really has.
class PendingUpload {
  PendingUpload({
    required this.uploadId,
    required this.projectName,
    required this.fileName,
    required this.contentType,
    required this.totalSize,
    required this.chunkSize,
    required this.totalChunks,
    this.filePath,
  });

  final String uploadId;
  final String projectName;
  final String fileName;
  final String contentType;
  final int totalSize;
  final int chunkSize;
  final int totalChunks;

  /// Null on web: there is no re-openable path there, so resuming after a
  /// page reload requires the user to pick the same file again.
  final String? filePath;

  Map<String, dynamic> toJson() => {
        'upload_id': uploadId,
        'project_name': projectName,
        'file_name': fileName,
        'content_type': contentType,
        'total_size': totalSize,
        'chunk_size': chunkSize,
        'total_chunks': totalChunks,
        'file_path': filePath,
      };

  factory PendingUpload.fromJson(Map<String, dynamic> j) => PendingUpload(
        uploadId: j['upload_id'] as String,
        projectName: j['project_name'] as String,
        fileName: j['file_name'] as String,
        contentType: j['content_type'] as String,
        totalSize: (j['total_size'] as num).toInt(),
        chunkSize: (j['chunk_size'] as num).toInt(),
        totalChunks: (j['total_chunks'] as num).toInt(),
        filePath: j['file_path'] as String?,
      );
}

class UploadCancelledException implements Exception {
  @override
  String toString() => 'Upload cancelled.';
}

/// Resumable upload client for the backend's /api/uploads/* flow.
///
///  - start(): init -> PUT every chunk (each retried with exponential
///    backoff) -> complete.
///  - resume(): asks the server which chunk indices it already has and sends
///    only the missing ones -- the "internet dropped at 90%" case.
///  - cancel(): stops the loop, tells the server to delete the partial
///    chunks, and forgets the local record.
///
/// iOS caveat: the path file_picker returns on iOS can point at a temporary
/// copy the OS may purge, or a security-scoped URL that is only valid for
/// the session that picked it. If that file is gone when resuming after an
/// app restart, [resume] throws and the UI must ask the user to re-pick the
/// same file (resume then proceeds from the server's chunk list, so no
/// completed work is lost).
class ChunkedUploader {
  ChunkedUploader(this._api);

  final ApiClient _api;

  static const _prefsKey = 'chunked_upload_pending_v1';
  static const maxAttemptsPerChunk = 5;

  final _progress = StreamController<ChunkedUploadProgress>.broadcast();
  Stream<ChunkedUploadProgress> get progress => _progress.stream;

  ChunkedUploadProgress _state = const ChunkedUploadProgress();
  ChunkedUploadProgress get state => _state;

  bool _cancelRequested = false;
  CancelToken? _inFlight;

  void _emit(ChunkedUploadProgress s) {
    _state = s;
    if (!_progress.isClosed) _progress.add(s);
  }

  // ---------------------------------------------------------------- persistence
  Future<PendingUpload?> loadPending() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return null;
      return PendingUpload.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null; // corrupt or unreadable record: treat as nothing pending
    }
  }

  Future<void> _savePending(PendingUpload p) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(p.toJson()));
  }

  Future<void> clearPending() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }

  // ---------------------------------------------------------------- public API
  /// Starts a brand-new upload. Returns the final (completed) progress, or
  /// throws [UploadCancelledException] / [ApiException].
  Future<ChunkedUploadProgress> start({
    required String projectName,
    required String fileName,
    required String contentType,
    required int totalSize,
    String captionLanguage = 'auto',
    String? translateTo,
    String? filePath,
    Uint8List? bytes,
  }) async {
    _cancelRequested = false;
    _emit(ChunkedUploadProgress(status: ChunkedUploadStatus.initializing, totalBytes: totalSize));

    final Map<String, dynamic> init;
    try {
      init = await _api.post('/api/uploads/init', data: {
        'file_name': fileName,
        'content_type': contentType,
        'total_size_bytes': totalSize,
        'project_name': projectName,
        'caption_language': captionLanguage,
        'translate_to': translateTo,
      });
    } on ApiException catch (e) {
      _emit(ChunkedUploadProgress(status: ChunkedUploadStatus.failed, errorMessage: e.message, totalBytes: totalSize));
      rethrow;
    }

    final pending = PendingUpload(
      uploadId: init['upload_id'] as String,
      projectName: projectName,
      fileName: fileName,
      contentType: contentType,
      totalSize: totalSize,
      chunkSize: (init['chunk_size_bytes'] as num).toInt(),
      totalChunks: (init['total_chunks'] as num).toInt(),
      filePath: filePath, // null on web
    );
    await _savePending(pending);

    return _run(pending, filePath: filePath, bytes: bytes);
  }

  /// Resumes a [PendingUpload]. On IO the persisted path is reused if the
  /// file still exists; otherwise (or on web) pass [filePath]/[bytes] from a
  /// fresh pick of the same file -- its size must match the original.
  Future<ChunkedUploadProgress> resume(
    PendingUpload pending, {
    String? filePath,
    Uint8List? bytes,
    int? pickedSize,
  }) async {
    _cancelRequested = false;
    if (pickedSize != null && pickedSize != pending.totalSize) {
      throw ApiException(message: "That isn't the same file as the interrupted upload (size differs).");
    }
    return _run(pending, filePath: filePath ?? pending.filePath, bytes: bytes);
  }

  Future<void> cancel() async {
    _cancelRequested = true;
    _inFlight?.cancel('cancelled by user');
    final id = _state.uploadId;
    if (id != null) {
      try {
        await _api.delete('/api/uploads/$id');
      } on ApiException {
        // Best effort: the server's periodic sweep removes abandoned sessions anyway.
      }
    }
    await clearPending();
    _emit(ChunkedUploadProgress(
      status: ChunkedUploadStatus.cancelled,
      uploadId: id,
      totalBytes: _state.totalBytes,
      totalChunks: _state.totalChunks,
    ));
  }

  /// Discards a stale pending record and its server-side chunks.
  Future<void> discardPending(PendingUpload pending) async {
    try {
      await _api.delete('/api/uploads/${pending.uploadId}');
    } on ApiException {
      // already gone / expired
    }
    await clearPending();
  }

  void dispose() {
    _progress.close();
  }

  // ---------------------------------------------------------------- core loop
  Future<ChunkedUploadProgress> _run(PendingUpload p, {String? filePath, Uint8List? bytes}) async {
    ChunkSource source;
    try {
      source = createChunkSource(filePath: filePath, bytes: bytes, totalSize: p.totalSize);
    } catch (_) {
      return _fail(p, 'The original file is no longer available. Please select it again to continue.',
          needsReselect: true);
    }

    try {
      // Ask the server what it already has -- the source of truth for resume.
      Set<int> received;
      try {
        final status = await _api.get('/api/uploads/${p.uploadId}/status');
        received = (status['received_chunks'] as List<dynamic>).map((e) => (e as num).toInt()).toSet();
      } on ApiException catch (e) {
        if (e.statusCode == 404) {
          await clearPending();
          return _fail(p, 'This upload has expired. Please start it again.');
        }
        rethrow;
      }

      int bytesDone = 0;
      for (final i in received) {
        bytesDone += _chunkLength(p, i);
      }
      _emit(ChunkedUploadProgress(
        status: ChunkedUploadStatus.uploading,
        uploadId: p.uploadId,
        uploadedChunks: received.length,
        totalChunks: p.totalChunks,
        bytesUploaded: bytesDone,
        totalBytes: p.totalSize,
      ));

      for (var i = 0; i < p.totalChunks; i++) {
        if (_cancelRequested) throw UploadCancelledException();
        if (received.contains(i)) continue;

        final Uint8List data;
        try {
          data = await source.readChunk(i * p.chunkSize, p.chunkSize);
        } catch (_) {
          return _fail(p, 'The original file is no longer available. Please select it again to continue.',
              needsReselect: true);
        }
        await _putChunkWithRetry(p, i, data);

        received.add(i);
        bytesDone += data.length;
        _emit(ChunkedUploadProgress(
          status: ChunkedUploadStatus.uploading,
          uploadId: p.uploadId,
          uploadedChunks: received.length,
          totalChunks: p.totalChunks,
          bytesUploaded: bytesDone,
          totalBytes: p.totalSize,
        ));
      }

      if (_cancelRequested) throw UploadCancelledException();

      _emit(ChunkedUploadProgress(
        status: ChunkedUploadStatus.completing,
        uploadId: p.uploadId,
        uploadedChunks: p.totalChunks,
        totalChunks: p.totalChunks,
        bytesUploaded: p.totalSize,
        totalBytes: p.totalSize,
      ));
      final done = await _api.post('/api/uploads/${p.uploadId}/complete');
      await clearPending();
      final result = ChunkedUploadProgress(
        status: ChunkedUploadStatus.completed,
        uploadId: p.uploadId,
        uploadedChunks: p.totalChunks,
        totalChunks: p.totalChunks,
        bytesUploaded: p.totalSize,
        totalBytes: p.totalSize,
        projectId: done['project_id'] as String,
        jobId: done['job_id'] as String,
      );
      _emit(result);
      return result;
    } on UploadCancelledException {
      // cancel() already emitted the cancelled state and cleaned up.
      return _state;
    } on ApiException catch (e) {
      // Validation failures at /complete (422) are final: the server already
      // deleted the chunks, so the pending record is useless.
      if (e.statusCode == 422 || e.statusCode == 413 || e.statusCode == 415) await clearPending();
      return _fail(p, e.message);
    } finally {
      await source.dispose();
    }
  }

  int _chunkLength(PendingUpload p, int index) {
    final start = index * p.chunkSize;
    final remaining = p.totalSize - start;
    return remaining < p.chunkSize ? remaining : p.chunkSize;
  }

  ChunkedUploadProgress _fail(PendingUpload p, String message, {bool needsReselect = false}) {
    final s = ChunkedUploadProgress(
      needsReselect: needsReselect,
      status: ChunkedUploadStatus.failed,
      uploadId: p.uploadId,
      totalChunks: p.totalChunks,
      totalBytes: p.totalSize,
      bytesUploaded: _state.bytesUploaded,
      uploadedChunks: _state.uploadedChunks,
      errorMessage: message,
    );
    _emit(s);
    return s;
  }

  Future<void> _putChunkWithRetry(PendingUpload p, int index, Uint8List data) async {
    var attempt = 0;
    while (true) {
      if (_cancelRequested) throw UploadCancelledException();
      _inFlight = CancelToken();
      try {
        await _api.dio.put(
          '/api/uploads/${p.uploadId}/chunks/$index',
          data: data,
          options: Options(headers: {
            Headers.contentTypeHeader: 'application/octet-stream',
          }),
          cancelToken: _inFlight,
        );
        return;
      } on DioException catch (e) {
        if (CancelToken.isCancel(e)) throw UploadCancelledException();
        final status = e.response?.statusCode;
        // 4xx other than 408/429 are the client's fault and will not fix
        // themselves on retry (bad index, wrong size, expired session, auth).
        final retryable = status == null || status >= 500 || status == 408 || status == 429;
        attempt++;
        if (!retryable || attempt >= maxAttemptsPerChunk) {
          final body = e.response?.data;
          final msg = (body is Map && body['detail'] is String)
              ? body['detail'] as String
              : 'Upload interrupted. Check your connection and resume.';
          throw ApiException(message: msg, statusCode: status);
        }
        _emit(ChunkedUploadProgress(
          status: ChunkedUploadStatus.uploading,
          uploadId: p.uploadId,
          uploadedChunks: _state.uploadedChunks,
          totalChunks: p.totalChunks,
          bytesUploaded: _state.bytesUploaded,
          totalBytes: p.totalSize,
          retryingChunk: index,
        ));
        final backoff = Duration(seconds: (1 << (attempt - 1)).clamp(1, 30));
        await Future<void>.delayed(backoff);
      }
    }
  }
}
