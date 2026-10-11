import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/chunked_uploader.dart';
import 'core_providers.dart';
import 'project_provider.dart';

/// App-scoped on purpose: the upload screen lives inside the navigation
/// shell, so switching tabs disposes the screen -- but the upload itself
/// must keep running. The screen re-attaches to [ChunkedUploader.progress].
final chunkedUploaderProvider = Provider<ChunkedUploader>((ref) {
  final uploader = ChunkedUploader(ref.watch(apiClientProvider));
  // Refresh the project list when an upload finishes, even if the upload
  // screen was disposed in the meantime (tab switch).
  final sub = uploader.progress.listen((p) {
    if (p.status == ChunkedUploadStatus.completed) {
      ref.read(projectListProvider.notifier).refresh();
    }
  });
  ref.onDispose(() {
    sub.cancel();
    uploader.dispose();
  });
  return uploader;
});

/// The interrupted upload (if any) recorded on this device, so the upload
/// screen can offer "Resume". Invalidate after start/complete/cancel.
final pendingUploadProvider = FutureProvider.autoDispose<PendingUpload?>((ref) {
  return ref.read(chunkedUploaderProvider).loadPending();
});
