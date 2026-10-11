import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/auth_provider.dart';
import '../screens/auth/forgot_password_screen.dart';
import '../screens/auth/login_screen.dart';
import '../screens/auth/register_screen.dart';
import '../screens/auth/splash_screen.dart';
import '../screens/dashboard/dashboard_screen.dart';
import '../screens/dashboard/dashboard_shell.dart';
import '../screens/editor/caption_editor_screen.dart';
import '../screens/export/export_screen.dart';
import '../screens/help/help_screen.dart';
import '../screens/preview/preview_screen.dart';
import '../screens/processing/processing_screen.dart';
import '../screens/profile/profile_screen.dart';
import '../screens/settings/settings_screen.dart';
import '../screens/upload/upload_screen.dart';

const _publicPaths = {'/splash', '/login', '/register', '/forgot-password'};

/// Bridges Riverpod auth state changes into go_router's refresh mechanism so
/// the redirect re-runs on login/logout without rebuilding the whole router.
class _AuthRefresh extends ChangeNotifier {
  _AuthRefresh(Ref ref) {
    ref.listen<AuthState>(authProvider, (_, __) => notifyListeners());
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _AuthRefresh(ref);

  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: refresh,
    redirect: (context, state) {
      final status = ref.read(authProvider).status;
      final path = state.matchedLocation;

      if (status == AuthStatus.unknown) return path == '/splash' ? null : '/splash';
      if (status == AuthStatus.unauthenticated) {
        return _publicPaths.contains(path) && path != '/splash' ? null : '/login';
      }
      // authenticated
      if (_publicPaths.contains(path)) return '/dashboard';
      return null;
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, __) => const SplashScreen()),
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      GoRoute(path: '/register', builder: (_, __) => const RegisterScreen()),
      GoRoute(path: '/forgot-password', builder: (_, __) => const ForgotPasswordScreen()),
      ShellRoute(
        builder: (context, state, child) => DashboardShell(location: state.matchedLocation, child: child),
        routes: [
          GoRoute(path: '/dashboard', builder: (_, __) => const DashboardScreen()),
          GoRoute(path: '/upload', builder: (_, __) => const UploadScreen()),
          GoRoute(path: '/settings', builder: (_, __) => const SettingsScreen()),
          GoRoute(path: '/profile', builder: (_, __) => const ProfileScreen()),
          GoRoute(path: '/help', builder: (_, __) => const HelpScreen()),
        ],
      ),
      GoRoute(
        path: '/processing/:jobId',
        builder: (_, state) => ProcessingScreen(jobId: state.pathParameters['jobId']!),
      ),
      GoRoute(
        path: '/editor/:projectId',
        builder: (_, state) => CaptionEditorScreen(projectId: state.pathParameters['projectId']!),
      ),
      GoRoute(
        path: '/preview/:projectId',
        builder: (_, state) => PreviewScreen(projectId: state.pathParameters['projectId']!),
      ),
      GoRoute(
        path: '/export/:projectId',
        builder: (_, state) => ExportScreen(projectId: state.pathParameters['projectId']!),
      ),
    ],
  );
});
