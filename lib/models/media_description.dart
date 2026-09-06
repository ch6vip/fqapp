/// Reads the optional description from normalized or legacy detail responses.
String extractMediaDescription(Map<String, dynamic>? payload) {
  if (payload == null) return '';
  dynamic data = payload['data'] ?? payload;
  if (data is Map && data['data'] is Map) data = data['data'];
  if (data is! Map) return '';
  for (final key in [
    'abstract',
    'description',
    'desc',
    'book_desc',
    'introduction',
  ]) {
    final value = data[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return '';
}
