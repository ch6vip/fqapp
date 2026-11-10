import 'package:flutter/cupertino.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

/// Original settings glyphs from the UI referenced by issue #288. This maps
/// presentation only: routes, switches and persistence still use current code.
IconData classicSettingsIcon(String title, IconData fallback) =>
    switch (title) {
      '外观' => LucideIcons.palette,
      '主题' => LucideIcons.palette,
      '阅读' => LucideIcons.book_open,
      '听书' => LucideIcons.headphones,
      '短剧' => LucideIcons.film,
      '数据' => LucideIcons.database,
      '服务' => LucideIcons.cpu,
      '关于' => LucideIcons.info,
      '主题模式' => LucideIcons.sun_moon,
      'OLED 纯黑' => LucideIcons.moon,
      '播放页布局' => LucideIcons.panels_top_left,
      '正文替换' => LucideIcons.replace,
      '系统朗读' => LucideIcons.mic,
      '备份与导入' => LucideIcons.database,
      '小说离线缓存' => LucideIcons.bookmark,
      '短剧离线缓存' => LucideIcons.clapperboard,
      '书架点书直接进入阅读' => LucideIcons.book_open,
      '首页与搜索点书直接进入阅读' => LucideIcons.search,
      '后台听书与保活' => LucideIcons.headphones,
      '听书变速引擎' => LucideIcons.gauge,
      '开启应用时默认静音' => LucideIcons.volume_x,
      '切后台悬浮窗播放' => LucideIcons.picture_in_picture_2,
      '视频解码器' => LucideIcons.video,
      '清空历史' => LucideIcons.trash,
      _ => fallback,
    };
