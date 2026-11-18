import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'public_site_widgets.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) => SitePageFrame(
        activePath: '/about',
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 760;
            return SingleChildScrollView(
              child: Column(
                children: [
                  Padding(
                    padding: EdgeInsets.symmetric(
                        horizontal: compact ? 24 : 60,
                        vertical: compact ? 52 : 88),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1080),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const _Eyebrow('ABOUT CAPTIONPRO'),
                          const SizedBox(height: 22),
                          Text(
                            'Make every video\neasier to follow.',
                            style: TextStyle(
                              color: SiteColors.ink,
                              fontSize: compact ? 42 : 64,
                              height: 1.08,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -2.7,
                            ),
                          ),
                          const SizedBox(height: 20),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 720),
                            child: const Text(
                              'CaptionPro helps creators turn spoken words into clear, editable captions and export videos that are ready to share.',
                              style: TextStyle(
                                  color: SiteColors.muted,
                                  fontSize: 19,
                                  height: 1.7),
                            ),
                          ),
                          const SizedBox(height: 54),
                          Wrap(
                            spacing: 16,
                            runSpacing: 16,
                            children: const [
                              _AboutCard(
                                  icon: Icons.graphic_eq_rounded,
                                  title: 'Start with your video',
                                  text:
                                      'Upload a clip and generate a transcript without leaving your workspace.'),
                              _AboutCard(
                                  icon: Icons.edit_note_rounded,
                                  title: 'Keep creative control',
                                  text:
                                      'Review every line, adjust timing, and choose how captions look.'),
                              _AboutCard(
                                  icon: Icons.ios_share_rounded,
                                  title: 'Finish ready to share',
                                  text:
                                      'Render a captioned video and download your finished export.'),
                            ],
                          ),
                          const SizedBox(height: 48),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(28),
                            decoration: BoxDecoration(
                                color: SiteColors.lavender,
                                borderRadius: BorderRadius.circular(20)),
                            child: Wrap(
                              alignment: WrapAlignment.spaceBetween,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              spacing: 18,
                              runSpacing: 18,
                              children: [
                                const SizedBox(
                                  width: 570,
                                  child: Text(
                                      'Good captions make good videos easier to watch.',
                                      style: TextStyle(
                                          color: SiteColors.ink,
                                          fontSize: 22,
                                          fontWeight: FontWeight.w700,
                                          height: 1.35)),
                                ),
                                FilledButton.icon(
                                  onPressed: () => context.go('/register'),
                                  icon: const Icon(Icons.arrow_forward_rounded),
                                  label: const Text('Try CaptionPro'),
                                  style: FilledButton.styleFrom(
                                      backgroundColor: SiteColors.purple,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 20, vertical: 16)),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SitePageFooter(),
                ],
              ),
            );
          },
        ),
      );
}

class _Eyebrow extends StatelessWidget {
  const _Eyebrow(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
            color: SiteColors.lavender,
            borderRadius: BorderRadius.circular(99)),
        child: Text(text,
            style: const TextStyle(
                color: SiteColors.purple,
                fontSize: 11,
                letterSpacing: 1.1,
                fontWeight: FontWeight.w800)),
      );
}

class _AboutCard extends StatelessWidget {
  const _AboutCard(
      {required this.icon, required this.title, required this.text});

  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        width: 330,
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(17),
            border: Border.all(color: SiteColors.border)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: SiteColors.purple, size: 29),
            const SizedBox(height: 18),
            Text(title,
                style: const TextStyle(
                    color: SiteColors.ink,
                    fontSize: 17,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(text,
                style: const TextStyle(color: SiteColors.muted, height: 1.6)),
          ],
        ),
      );
}
