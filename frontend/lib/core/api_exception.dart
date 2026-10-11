/// A normalized API error -- every call site gets a user-safe `message`
/// regardless of whether the failure was a 4xx with a `detail` body, a
/// network error, or a timeout, so screens never have to branch on
/// Dio-specific exception types.
class ApiException implements Exception {
  ApiException({required this.message, this.statusCode});

  final String message;
  final int? statusCode;

  bool get isUnauthorized => statusCode == 401;
  bool get isNetworkError => statusCode == null;

  @override
  String toString() => message;
}
