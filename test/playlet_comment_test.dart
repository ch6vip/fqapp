import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/playlet_comment.dart';

/// 短剧评论/热评/弹幕的解析用例。
///
/// 形状取自官方 `POST /novel/commentapi/comment/list/:group_id/v1/` 的响应：
/// `data.data_list[i].comment.common.content.text` + `data.common_list_info`，
/// 热评由客户端从 `data_type` 筛出（`a13/w.java:351-426`）。
void main() {
  Map<String, dynamic> entry({
    String id = 'c1',
    String text = '好看',
    int dataType = UgcRelativeType.comment,
    String parentId = '',
    int roleType = 0,
    int digg = 3,
    int offset = 0,
  }) => {
    'comment': {
      'comment_id': id,
      'common': {
        'content': {'text': text},
        'create_timestamp': 1700000000,
        'user_info': {
          'base_info': {'user_name': '小明', 'user_avatar': 'https://a.test/a.png'},
        },
      },
      'stat': {'digg_count': digg, 'reply_count': 1},
      'expand': {
      'playlet_role_type': roleType,
      // 官方字段名（CommentExpand 的 @SerializedName("offset_time")）。
      'offset_time': offset,
    },
    },
    'mix_data': {
      'data_type': dataType,
      if (parentId.isNotEmpty)
        'parent': {
          'comment': {'comment_id': parentId},
        },
    },
  };

  test('parses a comment list page with counters and cursor', () {
    final page = PlayletCommentPage.fromPayload({
      'code': 0,
      'data': {
        'common_list_info': {
          'total': 12,
          'has_more': true,
          'cursor': 'CURSOR-1',
        },
        'data_list': [entry()],
      },
    });
    expect(page.comments, hasLength(1));
    final comment = page.comments.single;
    expect(comment.id, 'c1');
    expect(comment.text, '好看');
    expect(comment.userName, '小明');
    expect(comment.diggCount, 3);
    expect(comment.dataType, UgcRelativeType.comment);
    expect(comment.createdAt, isNotNull);
    expect(page.totalCount, 12);
    expect(page.hasMore, isTrue);
    expect(page.cursor, 'CURSOR-1');
  });

  test('hot comments are the client-side filter over the same list', () {
    // 官方没有 hot_comment 字段：热评 = dataType in {Comment, Reply}。
    final page = PlayletCommentPage.fromPayload({
      'code': 0,
      'data': {
        'common_list_info': {'total': 3},
        'data_list': [
          entry(id: 'keep-1', dataType: UgcRelativeType.comment),
          entry(id: 'skip', dataType: UgcRelativeType.seriesVideo),
          entry(
            id: 'keep-2',
            dataType: UgcRelativeType.reply,
            parentId: 'parent-9',
          ),
        ],
      },
    });
    expect(page.comments, hasLength(3));
    expect(page.hotComments.map((c) => c.id), ['keep-1', 'keep-2']);
    expect(page.hotComments.last.parentCommentId, 'parent-9');
  });

  test('a reply hot comment carries the parent id used for navigation', () {
    final page = PlayletCommentPage.fromPayload({
      'code': 0,
      'data': {
        'common_list_info': {'total': 1},
        'data_list': [
          entry(
            id: 'reply-1',
            dataType: UgcRelativeType.reply,
            parentId: 'comment-7',
          ),
        ],
      },
    });
    // 官方点击联动：Reply 用 parentCommentId + commentId 组 hot_comment_id/hot_reply_id。
    final hot = page.hotComments.single;
    expect(hot.dataType, UgcRelativeType.reply);
    expect(hot.parentCommentId, 'comment-7');
    expect(hot.id, 'reply-1');
  });

  test('empty text entries are dropped and business errors yield an empty page', () {
    final page = PlayletCommentPage.fromPayload({
      'code': 0,
      'data': {
        'common_list_info': {'total': 5},
        'data_list': [entry(text: '   '), entry(id: 'ok')],
      },
    });
    expect(page.comments.map((c) => c.id), ['ok']);
    expect(
      PlayletCommentPage.fromPayload({'code': 103001, 'data': null}).comments,
      isEmpty,
    );
  });

  test('the empty-state copy follows the official count rule', () {
    // gx1/n0.java:698-708：计数 >0 -> 无相关剧评；==0 -> 期待你的第一条剧评。
    const withComments = PlayletCommentPage(totalCount: 3);
    const withoutComments = PlayletCommentPage();
    expect(withComments.emptyText, '无相关剧评');
    expect(withoutComments.emptyText, '期待你的第一条剧评');
  });

  test('the entry label falls back to 评论 when the count is zero', () {
    expect(PlayletCommentPage.entryLabel(0), '评论');
    expect(PlayletCommentPage.entryLabel(12000), '1.2万');
    expect(PlayletCommentPage.entryLabel(88), '88');
  });

  test('the legacy offset key is still accepted', () {
    // 历史兜底拼写：`offset` 不是官方字段名，但早期实现用过；
    // 官方字段是 `expand.offset_time`。
    final page = PlayletCommentPage.fromDanmakuPayload({
      'code': 0,
      'data': {
        'common_list_info': {'total': 1},
        'data_list': [
          {
            'comment': {
              'comment_id': 'd2',
              'common': {
                'content': {'text': '兜底'},
              },
              'expand': {'offset': 900},
            },
            'mix_data': {'data_type': UgcRelativeType.seriesVideo},
          },
        ],
      },
    });
    expect(page.comments, hasLength(1));
    expect(page.comments.single.offsetMs, 900);
  });

  test('parses danmaku with the millisecond offset', () {
    final page = PlayletCommentPage.fromDanmakuPayload({
      'code': 0,
      'data': {
        'common_list_info': {'total': 1, 'has_more': false},
        'data_list': [
          entry(id: 'd1', text: '前方高能', dataType: UgcRelativeType.seriesVideo, offset: 12500),
        ],
      },
    });
    expect(page.comments.single.offsetMs, 12500);
    expect(page.hasMore, isFalse);
  });

  test('hot prefixes follow playlet_role_type', () {
    // 官方映射：0=主演说、1=演员说、其他=热评（InfoPanelHotCommentView.z2()）。
    const lead = PlayletComment(playletRoleType: 0);
    const actor = PlayletComment(playletRoleType: 1);
    const plain = PlayletComment(playletRoleType: 2);
    expect(lead.rolePrefix, '主演说：');
    expect(actor.rolePrefix, '演员说：');
    expect(plain.rolePrefix, '热评：');
  });

  test('official copy constants match the decompiled strings', () {
    expect(shareCopyLinkLabel, '复制链接');
    expect(shareCopiedToast, '链接已复制，快去分享吧');
    expect(shareUnavailableToast, '网络错误，请重试');
    expect(danmakuEnabledToast, '弹幕已开启');
    expect(danmakuDisabledToast, '弹幕已关闭，长按视频可开启');
    expect(danmakuHint, '发条友善的弹幕吧');
  });
}
