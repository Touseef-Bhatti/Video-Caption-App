import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../providers/auth_provider.dart';
import '../../providers/project_provider.dart';
import '../../widgets/app_button.dart';
import '../../widgets/confirm_dialog.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CircleAvatar(
                  radius: 36,
                  backgroundColor: theme.colorScheme.primary.withOpacity(0.15),
                  child: Icon(Icons.person_outline, size: 36, color: theme.colorScheme.primary),
                ),
                const SizedBox(height: AppSpacing.md),
                Text(auth.userEmail ?? 'Signed in', style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
                const SizedBox(height: AppSpacing.xs),
                Text('Free plan', style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
                const SizedBox(height: AppSpacing.lg),
                ref.watch(usageProvider).maybeWhen(
                      data: (u) => Card(
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpacing.md),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Usage', style: theme.textTheme.titleMedium),
                              const SizedBox(height: AppSpacing.xs),
                              Text(
                                '${(u.monthSeconds / 60).toStringAsFixed(1)} min this month  ·  '
                                '${(u.totalSeconds / 60).toStringAsFixed(1)} min total  ·  ${u.videos} videos',
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ),
                      orElse: () => const SizedBox.shrink(),
                    ),
                const SizedBox(height: AppSpacing.xl),
                AppButton(
                  label: 'Log out',
                  variant: AppButtonVariant.secondary,
                  icon: Icons.logout,
                  onPressed: () async {
                    final ok = await showConfirmDialog(
                      context,
                      title: 'Log out?',
                      message: 'You will need to sign in again to see your projects.',
                      confirmLabel: 'Log out',
                    );
                    if (ok) await ref.read(authProvider.notifier).logout();
                  },
                  expand: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
