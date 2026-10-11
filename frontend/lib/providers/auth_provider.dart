import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_exception.dart';
import 'core_providers.dart';

enum AuthStatus { unknown, authenticated, unauthenticated }

class AuthState {
  const AuthState({this.status = AuthStatus.unknown, this.isLoading = false, this.errorMessage, this.userEmail});

  final AuthStatus status;
  final bool isLoading;
  final String? errorMessage;
  final String? userEmail;

  AuthState copyWith({
    AuthStatus? status,
    bool? isLoading,
    String? errorMessage,
    bool clearError = false,
    String? userEmail,
  }) =>
      AuthState(
        status: status ?? this.status,
        isLoading: isLoading ?? this.isLoading,
        errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
        userEmail: userEmail ?? this.userEmail,
      );
}

class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier(this._ref) : super(const AuthState()) {
    _ref.read(apiClientProvider).onUnauthorized = () {
      state = const AuthState(status: AuthStatus.unauthenticated);
    };
    _restoreSession();
  }

  final Ref _ref;

  Future<void> _restoreSession() async {
    final token = await _ref.read(tokenStorageProvider).readToken();
    if (token == null) {
      state = state.copyWith(status: AuthStatus.unauthenticated);
      return;
    }
    try {
      final me = await _ref.read(apiClientProvider).get('/api/auth/me');
      state = state.copyWith(status: AuthStatus.authenticated, userEmail: me['email'] as String?);
    } on ApiException {
      // Token is present but no longer valid (expired/revoked) -- fall back
      // to logged-out rather than looping on a dead token.
      await _ref.read(tokenStorageProvider).clearToken();
      state = state.copyWith(status: AuthStatus.unauthenticated);
    }
  }

  Future<bool> login(String email, String password) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final res = await _ref.read(apiClientProvider).post('/api/auth/login', data: {
        'email': email,
        'password': password,
      });
      await _ref.read(tokenStorageProvider).writeToken(res['access_token'] as String);
      state = state.copyWith(status: AuthStatus.authenticated, isLoading: false, userEmail: email);
      return true;
    } on ApiException catch (e) {
      state = state.copyWith(isLoading: false, errorMessage: e.message);
      return false;
    }
  }

  Future<bool> register(String email, String password) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final res = await _ref.read(apiClientProvider).post('/api/auth/register', data: {
        'email': email,
        'password': password,
      });
      await _ref.read(tokenStorageProvider).writeToken(res['access_token'] as String);
      state = state.copyWith(status: AuthStatus.authenticated, isLoading: false, userEmail: email);
      return true;
    } on ApiException catch (e) {
      state = state.copyWith(isLoading: false, errorMessage: e.message);
      return false;
    }
  }

  Future<bool> forgotPassword(String email) async {
    try {
      await _ref.read(apiClientProvider).post('/api/auth/forgot-password', data: {'email': email});
      return true;
    } on ApiException {
      return false;
    }
  }

  Future<void> logout() async {
    await _ref.read(tokenStorageProvider).clearToken();
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  void clearError() => state = state.copyWith(clearError: true);
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) => AuthNotifier(ref));
