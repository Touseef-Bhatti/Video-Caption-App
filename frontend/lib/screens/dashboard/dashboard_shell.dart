import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';

class Breakpoints {
  Breakpoints._();
  static const tablet = 700.0;
  static const desktop = 1100.0;
}

class _Destination {
  const _Destination(this.path, this.label, this.icon);
  final String path;
  final String label;
  final IconData icon;
}

const _destinations = [
  _Destination('/dashboard', 'Projects', Icons.folder_outlined),
  _Destination('/upload', 'New', Icons.add_circle_outline),
  _Destination('/settings', 'Settings', Icons.settings_outlined),
  _Destination('/profile', 'Profile', Icons.person_outline),
  _Destination('/help', 'Help', Icons.help_outline),
];

/// Persistent navigation: a sidebar on tablet/desktop, a bottom bar on phones.
class DashboardShell extends StatelessWidget {
  const DashboardShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  int get _index {
    final i = _destinations.indexWhere((d) => location.startsWith(d.path));
    return i < 0 ? 0 : i;
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final wide = width >= Breakpoints.tablet;

    if (!wide) {
      return Scaffold(
        body: SafeArea(child: child),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => context.go(_destinations[i].path),
          destinations: [
            for (final d in _destinations) NavigationDestination(icon: Icon(d.icon), label: d.label),
          ],
        ),
      );
    }

    final extended = width >= Breakpoints.desktop;
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            NavigationRail(
              extended: extended,
              selectedIndex: _index,
              backgroundColor: theme.cardTheme.color,
              onDestinationSelected: (i) => context.go(_destinations[i].path),
              leading: Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.closed_caption_outlined, color: theme.colorScheme.primary),
                    if (extended) ...[
                      const SizedBox(width: AppSpacing.sm),
                      Text('Captions', style: theme.textTheme.titleLarge),
                    ],
                  ],
                ),
              ),
              destinations: [
                for (final d in _destinations)
                  NavigationRailDestination(icon: Icon(d.icon), label: Text(d.label)),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}
