import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'public_site_widgets.dart';

class ContactScreen extends StatelessWidget {
  const ContactScreen({super.key});

  @override
  Widget build(BuildContext context) => SitePageFrame(
        activePath: '/contact',
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 760;
            return SingleChildScrollView(
              child: Column(
                children: [
                  Padding(
                    padding: EdgeInsets.symmetric(
                        horizontal: compact ? 24 : 60,
                        vertical: compact ? 50 : 82),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1080),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 8),
                            decoration: BoxDecoration(
                                color: SiteColors.lavender,
                                borderRadius: BorderRadius.circular(99)),
                            child: const Text('CONTACT',
                                style: TextStyle(
                                    color: SiteColors.purple,
                                    fontSize: 11,
                                    letterSpacing: 1.1,
                                    fontWeight: FontWeight.w800)),
                          ),
                          const SizedBox(height: 22),
                          Text('How can we help?',
                              style: TextStyle(
                                  color: SiteColors.ink,
                                  fontSize: compact ? 40 : 60,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -2.4)),
                          const SizedBox(height: 16),
                          const SizedBox(
                            width: 720,
                            child: Text(
                                'Choose the topic that best matches what you need. We’ll point you to the right place.',
                                style: TextStyle(
                                    color: SiteColors.muted,
                                    fontSize: 18,
                                    height: 1.65)),
                          ),
                          const SizedBox(height: 42),
                          Wrap(
                            spacing: 18,
                            runSpacing: 18,
                            children: [
                              _ContactCard(
                                icon: Icons.video_settings_outlined,
                                title: 'Help with a project',
                                description:
                                    'Get help with uploads, captions, editing, or exporting a video.',
                                action: 'Open help center',
                                onPressed: () => context.go('/help'),
                              ),
                              _ContactCard(
                                icon: Icons.manage_accounts_outlined,
                                title: 'Account support',
                                description:
                                    'Review your account and usage details in your profile.',
                                action: 'Go to profile',
                                onPressed: () => context.go('/profile'),
                              ),
                              _ContactCard(
                                icon: Icons.lightbulb_outline_rounded,
                                title: 'Ideas and feedback',
                                description:
                                    'Sign in to your workspace and use Help to share feedback about the app.',
                                action: 'Log in to continue',
                                onPressed: () => context.go('/login'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 38),
                          Container(
                            padding: const EdgeInsets.all(22),
                            decoration: BoxDecoration(
                                color: const Color(0xFFF8F6FC),
                                borderRadius: BorderRadius.circular(15),
                                border: Border.all(color: SiteColors.border)),
                            child: const Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(Icons.lock_outline_rounded,
                                    color: SiteColors.purple),
                                SizedBox(width: 12),
                                Expanded(
                                    child: Text(
                                        'Your uploaded videos and projects are private to your account.',
                                        style: TextStyle(
                                            color: SiteColors.ink,
                                            height: 1.5))),
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

class _ContactCard extends StatelessWidget {
  const _ContactCard(
      {required this.icon,
      required this.title,
      required this.description,
      required this.action,
      required this.onPressed});

  final IconData icon;
  final String title;
  final String description;
  final String action;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Container(
        width: 340,
        constraints: const BoxConstraints(minHeight: 230),
        padding: const EdgeInsets.all(23),
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: SiteColors.border)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                    color: SiteColors.lavender,
                    borderRadius: BorderRadius.circular(13)),
                child: Icon(icon, color: SiteColors.purple)),
            const SizedBox(height: 18),
            Text(title,
                style: const TextStyle(
                    color: SiteColors.ink,
                    fontSize: 18,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(description,
                style: const TextStyle(color: SiteColors.muted, height: 1.55)),
            const Spacer(),
            TextButton.icon(
                onPressed: onPressed,
                icon: const Icon(Icons.arrow_forward_rounded, size: 17),
                label: Text(action)),
          ],
        ),
      );
}
