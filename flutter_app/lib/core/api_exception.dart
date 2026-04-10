class ApiException implements Exception {
  const ApiException({
    required this.statusCode,
    required this.detail,
    required this.payload,
  });

  final int statusCode;
  final String detail;
  final Map<String, dynamic>? payload;

  @override
  String toString() => 'ApiException($statusCode): $detail';
}
