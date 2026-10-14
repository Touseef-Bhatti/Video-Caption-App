import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_exception.dart';
import '../../core/caption_languages.dart';
import '../../core/chunked_uploader.dart';
import '../../core/theme.dart';
import '../../providers/upload_provider.dart';
import '../../widgets/app_button.dart';
import '../../widgets/upload_card.dart';

const _mimeByExtension = {
  'mp4': 'video/mp4',
  'mov': 'video/quicktime',
  'mkv': 'video/x-matroska',
  'webm': 'video/webm',
};

String _formatBytes(int b) {
  const mb = 1024 * 1024;
  if (b >= 1024 * mb) return '${(b / (1024 * mb)).toStringAsFixed(2)} GB';
  return '${(b / mb).toStringAsFixed(1)} MB';
}

class UploadScreen extends ConsumerStatefulWidget {
  const UploadScreen({super.key});

  @override
  ConsumerState<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends ConsumerState<UploadScreen> {
  final _nameController = TextEditingController();
  late final ChunkedUploader _uploader = ref.read(chunkedUploaderProvider);
  StreamSubscription<ChunkedUploadProgress>? _sub;
  late ChunkedUploadProgress _progress = _uploader.state;

  PlatformFile? _picked;
  String? _localError;
  String _captionLanguage = 'auto';
  String _customCaptionLanguage = '';

  bool get _busy =>
      _progress.status == ChunkedUploadStatus.initializing ||
      _progress.status == ChunkedUploadStatus.uploading ||
      _progress.status == ChunkedUploadStatus.completing;

  @override
  void initState() {
    super.initState();
    // Re-attach to an upload that kept running while this tab was away.
    _sub = _uploader.progress.listen((p) {
      if (!mounted) return;
      setState(() => _progress = p);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _nameController.dispose();
    super.dispose();
  }

  Future<PlatformFile?> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: _mimeByExtension.keys.toList(),
      withData: kIsWeb, // web has no path; IO streams from disk by path
    );
    if (result == null || result.files.isEmpty) return null;
    return result.files.single;
  }

  Future<void> _choose() async {
    final f = await _pickFile();
    if (f == null) return;
    setState(() {
      _picked = f;
      _localError = null;
      if (_nameController.text.trim().isEmpty) {
        _nameController.text = f.name.replaceFirst(RegExp(r'\.[^.]+$'), '');
      }
    });
  }

  String? _contentTypeFor(PlatformFile f) =>
      _mimeByExtension[(f.extension ?? '').toLowerCase()];

  Future<void> _start() async {
    final file = _picked;
    if (file == null) return;
    final contentType = _contentTypeFor(file);
    if (contentType == null) {
      setState(() => _localError =
          'Unsupported format. Please choose MP4, MOV, MKV or WEBM.');
      return;
    }
    final name = _nameController.text.trim().isEmpty
        ? file.name
        : _nameController.text.trim();
    final captionLanguage = _captionLanguage == 'other'
        ? _customCaptionLanguage.trim()
        : _captionLanguage;
    if (_captionLanguage == 'other' && captionLanguage.isEmpty) {
      setState(() => _localError = 'Enter the language name to continue.');
      return;
    }
    setState(() => _localError = null);
    try {
      final result = await _uploader.start(
        projectName: name,
        fileName: file.name,
        contentType: contentType,
        totalSize: file.size,
        captionLanguage: captionLanguage,
        filePath: kIsWeb ? null : file.path,
        bytes: file.bytes,
      );
      await _afterRun(result);
    } on ApiException {
      // The uploader already emitted a failed state with the message.
    }
    if (mounted) ref.invalidate(pendingUploadProvider);
  }

  Future<void> _resume(PendingUpload pending, {PlatformFile? file}) async {
    setState(() => _localError = null);
    try {
      final result = await _uploader.resume(
        pending,
        filePath: kIsWeb ? null : file?.path,
        bytes: file?.bytes,
        pickedSize: file?.size,
      );
      await _afterRun(result);
    } on ApiException catch (e) {
      if (mounted) setState(() => _localError = e.message);
    }
    if (mounted) ref.invalidate(pendingUploadProvider);
  }

  /// Resume needing a file: picks one first (web always; IO when the saved path is gone).
  Future<void> _resumeWithPick(PendingUpload pending) async {
    final f = await _pickFile();
    if (f == null) return;
    await _resume(pending, file: f);
  }

  Future<void> _afterRun(ChunkedUploadProgress result) async {
    if (!mounted)
      return; // user left this tab; the uploader finished on its own
    if (result.status == ChunkedUploadStatus.completed &&
        result.jobId != null) {
      context.go('/processing/${result.jobId}');
    }
  }

  Future<void> _cancel() async {
    await _uploader.cancel();
    if (!mounted) return;
    setState(() {
      _picked = null;
      _progress = _uploader.state;
    });
    ref.invalidate(pendingUploadProvider);
  }

  Future<void> _discard(PendingUpload pending) async {
    await _uploader.discardPending(pending);
    ref.invalidate(pendingUploadProvider);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pending = ref.watch(pendingUploadProvider).valueOrNull;
    final failed = _progress.status == ChunkedUploadStatus.failed;
    final showPendingBanner = pending != null && !_busy;

    return Scaffold(
      appBar: AppBar(title: const Text('New project')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (showPendingBanner) ...[
                  _PendingBanner(
                    pending: pending,
                    onResume: () => (kIsWeb || pending.filePath == null)
                        ? _resumeWithPick(pending)
                        : _resume(pending),
                    onPickAgain: () => _resumeWithPick(pending),
                    onDiscard: () => _discard(pending),
                    needsReselect: _progress.needsReselect,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                ],
                UploadCard(
                  onPick: _choose,
                  enabled: !_busy,
                  fileName: _picked?.name,
                  fileSizeLabel:
                      _picked == null ? null : _formatBytes(_picked!.size),
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _nameController,
                  enabled: !_busy,
                  decoration: const InputDecoration(hintText: 'Project name'),
                ),
                const SizedBox(height: AppSpacing.md),
                DropdownButtonFormField<String>(
                  value: _captionLanguage,
                  decoration: const InputDecoration(
                    labelText: 'Spoken language',
                    helperText:
                        'Transcribe the speech in its spoken language. This does not translate it.',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem(
                        value: 'auto', child: Text('Detect automatically')),
                    for (final language in captionLanguages)
                      DropdownMenuItem(value: language, child: Text(language)),
                    const DropdownMenuItem(
                        value: 'other', child: Text('Other language…')),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) =>
                          setState(() => _captionLanguage = value ?? 'auto'),
                ),
                if (_captionLanguage == 'other') ...[
                  const SizedBox(height: AppSpacing.sm),
                  TextField(
                    enabled: !_busy,
                    decoration:
                        const InputDecoration(labelText: 'Spoken language'),
                    onChanged: (value) => _customCaptionLanguage = value,
                  ),
                ],
                const SizedBox(height: AppSpacing.sm),
                Text(
                  'Captions keep the spoken language and wording. You can translate them later in the editor.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: AppSpacing.lg),
                if (_busy ||
                    (_progress.status == ChunkedUploadStatus.failed &&
                        _progress.totalBytes > 0))
                  _ProgressPanel(progress: _progress),
                if (_localError != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(_localError!,
                      style: const TextStyle(color: AppColors.danger)),
                ],
                const SizedBox(height: AppSpacing.lg),
                if (_busy)
                  AppButton(
                    label: 'Cancel upload',
                    variant: AppButtonVariant.secondary,
                    icon: Icons.close,
                    onPressed: _cancel,
                    expand: true,
                  )
                else if (failed && pending != null && _picked != null)
                  Row(
                    children: [
                      Expanded(
                        child: AppButton(
                          label: 'Resume upload',
                          icon: Icons.play_arrow,
                          onPressed: () => _resume(pending, file: _picked),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      AppButton(
                          label: 'Start over',
                          variant: AppButtonVariant.secondary,
                          onPressed: _cancel),
                    ],
                  )
                else
                  AppButton(
                    label: 'Upload and generate captions',
                    icon: Icons.closed_caption_outlined,
                    onPressed: _picked == null ? null : _start,
                    expand: true,
                  ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  'Large files upload in small pieces. If your connection drops, you can resume where it stopped.',
                  style: theme.textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProgressPanel extends StatelessWidget {
  const _ProgressPanel({required this.progress});
  final ChunkedUploadProgress progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failed = progress.status == ChunkedUploadStatus.failed;
    final label = switch (progress.status) {
      ChunkedUploadStatus.initializing => 'Preparing upload...',
      ChunkedUploadStatus.completing => 'Verifying your video...',
      ChunkedUploadStatus.failed =>
        progress.errorMessage ?? 'Upload interrupted.',
      _ =>
        'Uploading  ·  ${_formatBytes(progress.bytesUploaded)} of ${_formatBytes(progress.totalBytes)}',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          child: LinearProgressIndicator(
            value: progress.status == ChunkedUploadStatus.initializing
                ? null
                : progress.fraction,
            minHeight: 8,
            color: failed ? AppColors.danger : null,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(label,
            style: failed
                ? const TextStyle(color: AppColors.danger)
                : theme.textTheme.bodySmall),
        if (progress.retryingChunk != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
                'Connection issue -- retrying part ${progress.retryingChunk! + 1} of ${progress.totalChunks}...',
                style: theme.textTheme.bodySmall),
          ),
        if (progress.status == ChunkedUploadStatus.uploading)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
                '${progress.uploadedChunks} of ${progress.totalChunks} parts sent',
                style: theme.textTheme.bodySmall),
          ),
      ],
    );
  }
}

class _PendingBanner extends StatelessWidget {
  const _PendingBanner({
    required this.pending,
    required this.onResume,
    required this.onPickAgain,
    required this.onDiscard,
    required this.needsReselect,
  });

  final PendingUpload pending;
  final VoidCallback onResume;
  final VoidCallback onPickAgain;
  final VoidCallback onDiscard;
  final bool needsReselect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.history, color: theme.colorScheme.primary),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                    child: Text('Unfinished upload',
                        style: theme.textTheme.titleMedium)),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text('${pending.fileName}  ·  ${_formatBytes(pending.totalSize)}',
                style: theme.textTheme.bodySmall),
            if (needsReselect)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                    'Select the same file again to continue -- parts already sent are kept.',
                    style: theme.textTheme.bodySmall),
              ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                AppButton(
                    label: needsReselect ? 'Select file' : 'Resume',
                    onPressed: needsReselect ? onPickAgain : onResume),
                const SizedBox(width: AppSpacing.sm),
                AppButton(
                    label: 'Discard',
                    variant: AppButtonVariant.text,
                    onPressed: onDiscard),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
