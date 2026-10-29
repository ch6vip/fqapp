import 'package:flutter/material.dart';

import '../home/home_design.dart';

/// 分屏外壳顶部那条状态栏底的底色。
///
/// 浅色主题的画布是 `#F6F6F6`，压在黑视频上会露出一条白边；B 站播放页
/// 顶部是深底白图标，所以这里跟视频同色铺黑。深色主题的画布本身就是深
/// 底，沿用画布即可；墨水屏保持白底黑图标。
Color splitStatusBarColor(HomePalette palette) =>
    palette.eink || palette.dark ? palette.canvas : Colors.black;
