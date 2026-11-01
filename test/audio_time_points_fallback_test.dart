import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 真人讲书的 `/timepoints` 先问 `req_type=2`（音频时间轴）；这一版上游对
/// 部分书直接回 `101002 NOVEL_DATA_GET_ERROR`。客户端必须回落一次到
/// `req_type=3`，并记住这一章已经回落，否则每次打开都要白跑一次失败请求。
void main() {
  Map<String, dynamic> timeline() => {
    'code': 0,
    'para_match_data': {
      'audio_para_match_data': {
        'chapter': [
          {
            'start_time': 0,
            'end_time': 2000,
            'start_para': 0,
            'start_para_off': 0,
            'end_para': 0,
            'end_para_off': 6,
            'item_id': 7257740371885556000,
            'item_title': '第1章 大巴',
          },
        ],
      },
      'item_ids': {
        'chapter': {'0': 7257740371885556000},
      },
    },
  };

  http.Response respond(Object body) => http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  test('req_type=2 falls back to 3 once per chapter', () async {
    final requests = <String?>[];
    final transport = MockClient((request) async {
      final reqType = request.url.queryParameters['req_type'];
      requests.add(reqType);
      if (reqType == '2') {
        return respond({'code': 101002, 'message': 'NOVEL_DATA_GET_ERROR'});
      }
      return respond(timeline());
    });
    addTearDown(transport.close);
    final api = ApiClient(client: transport, baseUrl: 'http://localhost:9000');

    final first = await api.chapterTimePoints('book', 'chapter', reqType: 2);
    expect(first.isNotEmpty, isTrue);
    // 回落拿到的是完整的点：起始、结束和原著章节都解析出来了。
    expect(first.points.single.endTime, 2000);
    expect(first.points.single.startParaOff, 0);
    expect(requests, ['2', '3']);

    // 回落被记住：同一章第二次直接取 3，不再碰会失败的 2。
    final second = await api.chapterTimePoints('book', 'chapter', reqType: 2);
    expect(second.isNotEmpty, isTrue);
    expect(requests, ['2', '3', '3']);
  });

  test('a working req_type=2 timeline is used without asking 3', () async {
    final requests = <String?>[];
    final transport = MockClient((request) async {
      requests.add(request.url.queryParameters['req_type']);
      return respond(timeline());
    });
    addTearDown(transport.close);
    final api = ApiClient(client: transport, baseUrl: 'http://localhost:9000');

    final track = await api.chapterTimePoints('book', 'chapter', reqType: 2);
    expect(track.isNotEmpty, isTrue);
    expect(requests, ['2']);
  });
}
