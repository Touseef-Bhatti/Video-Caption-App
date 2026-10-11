import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Centered, width-capped card layout shared by login/register/forgot-password.
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({super.key, required this.title, required this.subtitle, required this.child});

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.closed_caption_outlined, size: 40, color: theme.colorScheme.primary),
                  const SizedBox(height: AppSpacing.lg),
                  Text(title, style: theme.textTheme.headlineMedium, textAlign: TextAlign.center),
                  const SizedBox(height: AppSpacing.sm),
                  Text(subtitle, style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
                  const SizedBox(height: AppSpacing.xl),
                  child,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
