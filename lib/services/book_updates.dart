import '../models/book_detail.dart';
import '../models/media_item.dart';
import 'api_client.dart';

typedef BookDirectoryLoader = Future<List<Chapter>> Function(String bookId);
typedef BookChapterCountLoader = Future<int> Function(String bookId);

Future<List<Chapter>> loadBookDirectory(String bookId) async =>
    (await ApiClient.instance.directoryChapters(
      bookId,
    )).expand((volume) => volume).toList(growable: false);

Future<int> loadBookChapterCount(String bookId) async =>
    BookDetail.fromPayload(await ApiClient.instance.detail(bookId)).serialCount;
