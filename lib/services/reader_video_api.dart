part of 'api_client.dart';

extension ReaderVideoApi on ApiClient {
  Future<ReaderVideoMatch> readerVideoMatch(String bookId) async {
    final response = await _get(
      _url('/api/v1/books/${Uri.encodeComponent(bookId)}/video-match', {}),
    );
    final status = response.statusCode;
    final bytes = response.bodyBytes;
    return decodeResponseBody(
      bytes.length,
      () => ReaderVideoMatch.fromPayload(_decodeEnvelope(status, bytes)),
    );
  }
}
