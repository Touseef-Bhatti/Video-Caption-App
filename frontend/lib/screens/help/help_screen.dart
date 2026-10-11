import 'package:flutter/material.dart';

import '../../core/theme.dart';

const _faqs = <(String, String)>[
  (
    'What videos can I upload?',
    'MP4, MOV, MKV and WEBM files up to 60 minutes long. The video must have an audio track.'
  ),
  (
    'My upload was interrupted. Do I have to start over?',
    'No. Uploads are sent in small parts. Open New project and tap Resume on the unfinished upload; only the parts '
        'that did not arrive are sent. If the original file can no longer be read (common on iPhone after restarting '
        'the app, or on the web after a page reload), select the same file again and the upload continues.'
  ),
  (
    'How are captions styled?',
    'Each line gets an importance weight from the AI. Plain lines stay plain; key words in important lines are '
        'highlighted or emphasized. You can tap any word in the editor to change it, pick one of 11 templates, and '
        'change colors, size and position.'
  ),
  (
    'Can I fix a wrong word?',
    'Yes. In the editor, long-press a word to edit its text, then choose Render video to create a new export.'
  ),
  (
    'Which languages are supported?',
    'The language is detected automatically. Right-to-left languages such as Urdu and Arabic are rendered with '
        'matching fonts.'
  ),
  (
    'Who can see my videos?',
    'Only you. Videos and exports are stored privately and reached through short-lived links.'
  ),
];

class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Help')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              for (final (q, a) in _faqs)
                Card(
                  child: ExpansionTile(
                    shape: const Border(),
                    title: Text(q, style: Theme.of(context).textTheme.titleMedium),
                    childrenPadding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
                    expandedCrossAxisAlignment: CrossAxisAlignment.start,
                    children: [Text(a, style: Theme.of(context).textTheme.bodyMedium)],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
