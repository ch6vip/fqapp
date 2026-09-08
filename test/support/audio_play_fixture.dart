import 'dart:convert';

// Sanitized structure captured from /api/v1/audio/play. The video_model is
// JSON inside a JSON string; its duration is in seconds and video_list is
// an array, unlike several unrelated video APIs.
Map<String, dynamic> audioPlayFixture({
  String itemId = 'chapter',
  Object? duration = 664.741,
  String mediaType = 'audio',
  List<Map<String, dynamic>> streams = const [
    {'main_url': 'https://cdn.example/audio.m4a?sign=a%2fb+xyz'},
  ],
}) => {
  'code': 0,
  'message': 'success',
  'video_info': {
    'code': 0,
    'data': {
      'video_model_datas': [
        {
          'item_id': itemId,
          'item_status': 0,
          'video_model': jsonEncode({
            'status': 10,
            'message': 'success',
            'media_type': mediaType,
            'video_duration': duration,
            'video_list': streams,
          }),
        },
      ],
    },
  },
};
