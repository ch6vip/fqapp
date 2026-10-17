/// Legacy reviews carry URL strings; the comment service carries `web_url` maps.
List<String> parseCommentImageUrls(dynamic images) {
  if (images is! List) return const [];
  final urls = <String>[];
  for (final image in images) {
    final value = image is Map ? image['web_url'] : image;
    if (value is! String) continue;
    final url = value.trim();
    final uri = Uri.tryParse(url);
    if (uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty) {
      urls.add(url);
    }
  }
  return List.unmodifiable(urls);
}
