import 'package:dio/dio.dart';

import 'api_exception.dart';
import 'storage/token_storage.dart';

/// The backend base URL. Passed at build/run time:
///   flutter run --dart-define=API_BASE_URL=http://localhost:8000
/// Never hardcoded to a production value and never reads GEMINI_API_KEY or
/// any backend secret -- those live only on the server (section 20/53).
const String kApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://localhost:8000',
);

/// Thin wrapper around Dio: attaches the JWT to every request, normalizes
/// every failure into an ApiException with a user-safe message, and calls
/// [onUnauthorized] exactly once per 401 so the auth layer can force a
/// logout without this class knowing anything about Riverpod or routing.
class ApiClient {
  ApiClient({required TokenStorage tokenStorage})
      : _tokenStorage = tokenStorage,
        dio = Dio(BaseOptions(
          baseUrl: kApiBaseUrl,
          connectTimeout: const Duration(seconds: 20),
          // Long receive timeout: an in-progress chunk/direct upload on a
          // slow connection should not be killed by a short client timeout.
          receiveTimeout: const Duration(minutes: 10),
          sendTimeout: const Duration(minutes: 10),
        )) {
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        final token = await _tokenStorage.readToken();
        if (token != null) {
          options.headers['Authorization'] = 'Bearer $token';
        }
        handler.next(options);
      },
      onError: (error, handler) async {
        if (error.response?.statusCode == 401) {
          await _tokenStorage.clearToken();
          onUnauthorized?.call();
        }
        handler.next(error);
      },
    ));
  }

  final Dio dio;
  final TokenStorage _tokenStorage;

  /// Set once by the auth provider so a 401 anywhere in the app routes back
  /// to the login screen, without this class depending on go_router.
  void Function()? onUnauthorized;

  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query}) async {
    try {
      final res = await dio.get(path, queryParameters: query);
      return _asMap(res.data);
    } on DioException catch (e) {
      throw _toApiException(e);
    }
  }

  Future<List<dynamic>> getList(String path, {Map<String, dynamic>? query}) async {
    try {
      final res = await dio.get(path, queryParameters: query);
      return res.data is List ? res.data as List<dynamic> : <dynamic>[];
    } on DioException catch (e) {
      throw _toApiException(e);
    }
  }

  Future<Map<String, dynamic>> post(String path, {Object? data}) async {
    try {
      final res = await dio.post(path, data: data);
      return _asMap(res.data);
    } on DioException catch (e) {
      throw _toApiException(e);
    }
  }

  Future<Map<String, dynamic>> put(String path, {Object? data}) async {
    try {
      final res = await dio.put(path, data: data);
      return _asMap(res.data);
    } on DioException catch (e) {
      throw _toApiException(e);
    }
  }

  Future<void> delete(String path) async {
    try {
      await dio.delete(path);
    } on DioException catch (e) {
      throw _toApiException(e);
    }
  }

  Map<String, dynamic> _asMap(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    return <String, dynamic>{};
  }

  ApiException _toApiException(DioException e) {
    final status = e.response?.statusCode;
    final body = e.response?.data;
    String message;
    if (body is Map && body['detail'] is String) {
      message = body['detail'] as String;
    } else if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      message = 'The request timed out. Please check your connection and try again.';
    } else if (e.type == DioExceptionType.connectionError) {
      message = "Couldn't reach the server. Please check your connection.";
    } else {
      message = 'Something went wrong. Please try again.';
    }
    return ApiException(message: message, statusCode: status);
  }
}
