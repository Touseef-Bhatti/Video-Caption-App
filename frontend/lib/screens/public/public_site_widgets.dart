import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/auth_provider.dart';

class SiteColors {
  SiteColors._();

  static const purple = Color(0xFF6E20E8);
  static const purpleDark = Color(0xFF4A10C6);
  static const ink = Color(0xFF17172D);
  static const muted = Color(0xFF686982);
  static const lavender = Color(0xFFF4EDFF);
  static const border = Color(0xFFE8E5F0);
  static const background = Color(0xFFFEFDFF);
}

class PublicSiteHeader extends ConsumerWidget {
  const PublicSiteHeader({super.key, this.activePath = '/', this.onNavigate});

  final String activePath;
  final ValueChanged<String>? onNavigate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final compact = MediaQuery.sizeOf(context).width < 1080;
    final authenticated =
        ref.watch(authProvider).status == AuthStatus.authenticated;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: const Border(bottom: BorderSide(color: SiteColors.border)),
        boxShadow: [
          BoxShadow(
            color: SiteColors.ink.withOpacity(.035),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1320),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: compact ? 20 : 34),
            child: Row(
              children: [
                const SiteBrand(),
                if (!compact) ...[
                  const Spacer(),
                  _NavLink(
                      label: 'Home',
                      path: '/',
                      activePath: activePath,
                      onNavigate: onNavigate),
                  _NavLink(
                      label: 'About',
                      path: '/about',
                      activePath: activePath,
                      onNavigate: onNavigate),
                  _NavLink(
                      label: 'Contact',
                      path: '/contact',
                      activePath: activePath,
                      onNavigate: onNavigate),
                  if (authenticated)
                    _NavLink(
                        label: 'Workspace',
                        path: '/dashboard',
                        activePath: activePath,
                        onNavigate: onNavigate),
                  if (authenticated)
                    _NavLink(
                        label: 'Profile',
                        path: '/profile',
                        activePath: activePath,
                        onNavigate: onNavigate),
                  const Spacer(),
                  if (authenticated)
                    _GradientButton(
                      label: 'Open workspace',
                      onPressed: () => _navigate(context, '/dashboard'),
                    )
                  else ...[
                    OutlinedButton(
                      onPressed: () => _navigate(context, '/login'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: SiteColors.ink,
                        side: const BorderSide(color: SiteColors.border),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 21, vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(11)),
                      ),
                      child: const Text('Log in'),
                    ),
                    const SizedBox(width: 10),
                    _GradientButton(
                        label: 'Get started',
                        onPressed: () => _navigate(context, '/register')),
                  ],
                ] else ...[
                  const Spacer(),
                  IconButton(
                    tooltip: 'Open navigation',
                    onPressed: () => _showMobileSidebar(context, authenticated),
                    style: IconButton.styleFrom(
                      backgroundColor: SiteColors.lavender,
                      foregroundColor: SiteColors.ink,
                      fixedSize: const Size(46, 46),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(13)),
                    ),
                    icon: const Icon(Icons.menu_rounded, size: 25),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showMobileSidebar(BuildContext context, bool authenticated) {
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close navigation menu',
      barrierColor: SiteColors.ink.withOpacity(.42),
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (dialogContext, _, __) => Align(
        alignment: Alignment.centerRight,
        child: _MobileNavigationSidebar(
          activePath: activePath,
          authenticated: authenticated,
          onNavigate: (path) {
            Navigator.of(dialogContext).pop();
            _navigate(context, path);
          },
        ),
      ),
      transitionBuilder: (_, animation, __, child) => SlideTransition(
        position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
            .animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
        child: child,
      ),
    );
  }

  void _navigate(BuildContext context, String path) {
    if (onNavigate != null) {
      onNavigate!(path);
    } else {
      context.go(path);
    }
  }
}

class _MobileNavigationSidebar extends StatelessWidget {
  const _MobileNavigationSidebar({
    required this.activePath,
    required this.authenticated,
    required this.onNavigate,
  });

  final String activePath;
  final bool authenticated;
  final ValueChanged<String> onNavigate;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return SafeArea(
      child: Material(
        color: Colors.white,
        elevation: 20,
        borderRadius: const BorderRadius.horizontal(left: Radius.circular(24)),
        child: SizedBox(
          width: width < 400 ? width - 24 : 360,
          height: double.infinity,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 24, 22, 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  const Expanded(child: SiteBrand()),
                  IconButton(
                    tooltip: 'Close navigation',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ]),
                const SizedBox(height: 12),
                const Divider(color: SiteColors.border),
                const SizedBox(height: 12),
                _SidebarLink(
                    icon: Icons.home_outlined,
                    label: 'Home',
                    path: '/',
                    activePath: activePath,
                    onTap: onNavigate),
                _SidebarLink(
                    icon: Icons.auto_awesome_outlined,
                    label: 'About',
                    path: '/about',
                    activePath: activePath,
                    onTap: onNavigate),
                _SidebarLink(
                    icon: Icons.mail_outline_rounded,
                    label: 'Contact',
                    path: '/contact',
                    activePath: activePath,
                    onTap: onNavigate),
                if (authenticated)
                  _SidebarLink(
                      icon: Icons.dashboard_outlined,
                      label: 'Workspace',
                      path: '/dashboard',
                      activePath: activePath,
                      onTap: onNavigate),
                if (authenticated)
                  _SidebarLink(
                      icon: Icons.person_outline_rounded,
                      label: 'Profile',
                      path: '/profile',
                      activePath: activePath,
                      onTap: onNavigate),
                const Spacer(),
                if (authenticated)
                  _GradientButton(
                      label: 'Open workspace',
                      onPressed: () => onNavigate('/dashboard'))
                else ...[
                  OutlinedButton(
                    onPressed: () => onNavigate('/login'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: SiteColors.ink,
                      minimumSize: const Size.fromHeight(50),
                      side: const BorderSide(color: SiteColors.border),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Log in'),
                  ),
                  const SizedBox(height: 10),
                  _GradientButton(
                      label: 'Get started',
                      onPressed: () => onNavigate('/register')),
                ],
                const SizedBox(height: 8),
                const Text('Make every word count.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: SiteColors.muted, fontSize: 12)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarLink extends StatelessWidget {
  const _SidebarLink(
      {required this.icon,
      required this.label,
      required this.path,
      required this.activePath,
      required this.onTap});

  final IconData icon;
  final String label;
  final String path;
  final String activePath;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final selected = activePath == path ||
        (path == '/dashboard' &&
            (activePath.startsWith('/dashboard') ||
                activePath.startsWith('/editor')));
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        onTap: () => onTap(path),
        leading:
            Icon(icon, color: selected ? SiteColors.purple : SiteColors.muted),
        title: Text(label,
            style: TextStyle(
                color: selected ? SiteColors.purple : SiteColors.ink,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
        selected: selected,
        selectedTileColor: SiteColors.lavender,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}

class _NavLink extends StatelessWidget {
  const _NavLink(
      {required this.label,
      required this.path,
      required this.activePath,
      this.onNavigate});

  final String label;
  final String path;
  final String activePath;
  final ValueChanged<String>? onNavigate;

  @override
  Widget build(BuildContext context) {
    final active = path == activePath ||
        (path == '/dashboard' &&
            (activePath.startsWith('/dashboard') ||
                activePath.startsWith('/editor')));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 13),
      child: TextButton(
        onPressed: () =>
            onNavigate == null ? context.go(path) : onNavigate!(path),
        style: TextButton.styleFrom(
          foregroundColor: active ? SiteColors.purple : SiteColors.muted,
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
          backgroundColor: active ? SiteColors.lavender : Colors.transparent,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: Text(label,
            style: TextStyle(
                fontWeight: active ? FontWeight.w700 : FontWeight.w500)),
      ),
    );
  }
}

class SiteBrand extends StatelessWidget {
  const SiteBrand({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: compact ? 34 : 40,
            height: compact ? 34 : 40,
            decoration: BoxDecoration(
              color: SiteColors.purple,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.play_arrow_rounded,
                color: Colors.white, size: compact ? 25 : 30),
          ),
          const SizedBox(width: 10),
          Text.rich(
            TextSpan(
              children: [
                const TextSpan(
                    text: 'Caption', style: TextStyle(color: SiteColors.ink)),
                TextSpan(
                    text: 'Pro',
                    style: TextStyle(
                        color: SiteColors.purple, fontWeight: FontWeight.w800)),
              ],
            ),
            style: TextStyle(
                fontSize: compact ? 23 : 26,
                fontWeight: FontWeight.w800,
                letterSpacing: -1),
          ),
        ],
      );
}

class _GradientButton extends StatelessWidget {
  const _GradientButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: SiteColors.purple,
          borderRadius: BorderRadius.circular(11),
          boxShadow: [
            BoxShadow(
                color: SiteColors.purple.withOpacity(.2),
                blurRadius: 16,
                offset: const Offset(0, 7))
          ],
        ),
        child: FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            backgroundColor: Colors.transparent,
            shadowColor: Colors.transparent,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 23, vertical: 15),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
          ),
          child:
              Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
      );
}

class SitePageFrame extends StatelessWidget {
  const SitePageFrame(
      {super.key, required this.activePath, required this.child});

  final String activePath;
  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: SiteColors.background,
        body: SelectionArea(
          child: Column(
            children: [
              PublicSiteHeader(activePath: activePath),
              Expanded(child: child),
            ],
          ),
        ),
      );
}

class SitePageFooter extends StatelessWidget {
  const SitePageFooter({super.key});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: SiteColors.border))),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1240),
            child: LayoutBuilder(
              builder: (context, constraints) => constraints.maxWidth < 500
                  ? const Column(children: [
                      SiteBrand(compact: true),
                      SizedBox(height: 10),
                      Text('Make every word count.',
                          style: TextStyle(color: SiteColors.muted)),
                    ])
                  : const Row(children: [
                      SiteBrand(compact: true),
                      Spacer(),
                      Text('Make every word count.',
                          style: TextStyle(color: SiteColors.muted)),
                    ]),
            ),
          ),
        ),
      );
}
