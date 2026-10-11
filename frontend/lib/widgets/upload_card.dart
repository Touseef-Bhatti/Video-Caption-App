import 'package:flutter/material.dart';

import '../core/theme.dart';

/// The drop-zone-style card on the upload screen. On web, also accepts the
/// tap to open the picker; drag-and-drop is intentionally not faked here.
class UploadCard extends StatelessWidget {
  const UploadCard({super.key, required this.onPick, this.fileName, this.fileSizeLabel, this.enabled = true});

  final VoidCallback onPick;
  final String? fileName;
  final String? fileSizeLabel;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasFile = fileName != null;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.lg),
      onTap: enabled ? onPick : null,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl, horizontal: AppSpacing.lg),
        decoration: BoxDecoration(
          border: Border.all(color: theme.dividerTheme.color ?? Colors.grey),
          borderRadius: BorderRadius.circular(AppRadius.lg),
          color: theme.cardTheme.color,
        ),
        child: Column(
          children: [
            Icon(hasFile ? Icons.check_circle_outline : Icons.upload_file_outlined,
                size: 44, color: theme.colorScheme.primary),
            const SizedBox(height: AppSpacing.md),
            Text(hasFile ? fileName! : 'Choose a video to caption',
                style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.xs),
            Text(
              hasFile ? (fileSizeLabel ?? '') : 'MP4, MOV, MKV or WEBM · up to 60 minutes',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
