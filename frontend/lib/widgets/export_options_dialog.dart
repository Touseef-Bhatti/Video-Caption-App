import 'package:flutter/material.dart';

import '../models/export_options.dart';

Future<ExportOptions?> showExportOptionsDialog(BuildContext context) {
  var resolution = 720;
  var fps = 30;
  return showDialog<ExportOptions>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('Choose download format'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<int>(
              value: resolution,
              decoration: const InputDecoration(labelText: 'Resolution'),
              items: const [
                DropdownMenuItem(value: 720, child: Text('720 px max')),
                DropdownMenuItem(value: 1024, child: Text('1024 px max')),
                DropdownMenuItem(value: 2048, child: Text('2K · 2048 px max')),
                DropdownMenuItem(value: 3840, child: Text('4K · 3840 px max')),
              ],
              onChanged: (value) {
                if (value != null) setDialogState(() => resolution = value);
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              value: fps,
              decoration: const InputDecoration(labelText: 'Frame rate'),
              items: const [
                DropdownMenuItem(value: 30, child: Text('30 fps')),
                DropdownMenuItem(value: 60, child: Text('60 fps')),
                DropdownMenuItem(value: 120, child: Text('120 fps')),
              ],
              onChanged: (value) {
                if (value != null) setDialogState(() => fps = value);
              },
            ),
            const SizedBox(height: 12),
            Text(
              'MP4 video. Captions are rendered at 15 fps on a layer up to 720 px; higher frame rates repeat caption frames.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              ExportOptions(resolution: resolution, fps: fps),
            ),
            child: const Text('Render and download'),
          ),
        ],
      ),
    ),
  );
}
