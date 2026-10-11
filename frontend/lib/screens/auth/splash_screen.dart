import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Shown while the stored session is being validated; the router redirects
/// away as soon as auth state resolves.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.closed_caption_outlined, size: 48, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: AppSpacing.lg),
            const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
          ],
        ),
      ),
    );
  }
}
