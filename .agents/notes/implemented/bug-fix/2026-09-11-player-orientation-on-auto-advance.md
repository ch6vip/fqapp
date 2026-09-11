# Agent Note: 全屏播放的方向不再被"未知视频尺寸"判成竖屏

Status: implemented

## Problem

真机反馈：短剧用横屏全屏播放时，**自动播放下一集会把画面切回竖屏，锁定也无效**。

`VideoPlayerChrome._applySystemUi` 按视频宽高决定全屏方向：

```dart
final landscape =
    (widget.player?.videoWidth ?? 9) > (widget.player?.videoHeight ?? 16);
await SystemChrome.setPreferredOrientations(
  landscape ? [landscapeLeft, landscapeRight] : [portraitUp, portraitDown],
);
```

问题在**新剧集的 player 还没有尺寸**。`NativePlayer._videoWidth` 初值为 **0**，只有收到 `videoSize` 事件后才被赋值（`native_player.dart`）。于是换集瞬间：

1. 自动连播创建新的 `NativePlayer`，`_player` 指向它；
2. `didUpdateWidget` 看到 `oldWidget.player != widget.player`，且 `_fullScreen` 为真 → 调 `_applySystemUi()`；
3. 此时 `videoWidth == 0`、`videoHeight == 0`，`0 > 0` 为假 → **判定竖屏 → 强制 `portraitUp/portraitDown`**。

横屏播放因此被掰回竖屏。而"锁定没用"是因为 `_locked` 只影响控件与翻页（`canPage`），从不参与方向决策 —— 锁定状态照样会执行上面的强制旋转。

另外，真实尺寸随后到达时**没有任何代码重新应用方向**：`videoSizeStream` 只触发重建（布局会重算，见 `PlayerVideoLayout.calculate` 对 0×0 有回退），但 `_applySystemUi` 只在换 player 与切全屏时被调用。所以即便尺寸后来对了，方向也不会自己纠正。

## Decision

把"尺寸未知"当成**没有答案**，而不是竖屏；等尺寸到达后再应用真实方向。

- 新增 `_orientationsForVideo`：返回该视频应有的方向列表，**尺寸 ≤0 时返回 `null`**（未知）。
- `_applySystemUi` 在 `null` 时只做沉浸式全屏，**不调用** `setPreferredOrientations` —— 保持设备当前方向，也就是用户自己转过去的方向。
- 新增 `_adoptVideoOrientation()`，在 `didUpdateWidget` 中调用：尺寸已知且与上次应用的不同则重新应用方向，让横屏剧集真正进入横屏。
- 锁定参与方向决策：`_locked` 时不改方向（换集也不改），**解锁时再应用** —— 这样"锁定"才真的锁得住用户选定的方向。

### 一个自己踩到的实现坑

判断"尺寸是否变化"不能比较 widget：

```dart
// 错误：player 自己 mutate 尺寸，oldWidget.player 与 widget.player 是同一对象
if (oldWidget.player?.videoWidth != widget.player?.videoWidth) ...
```

`NativePlayer` 是在**同一实例**上更新 `_videoWidth`，所以比较 widget 世代时两边读到的是同一个新值，永远相等，重应用永不触发。改为记录**上次应用时的尺寸**（`_appliedVideoSize`）来比对。

这个错误是被自己写的测试当场抓到的 —— 测试先通过"换集不强制竖屏"，但"尺寸到达后应用横屏"失败（`Expected: not null / Actual: <null>`），才暴露出比较方式不成立。

## Alternatives considered

- **尺寸未知时默认横屏**：能治好这次的横屏场景，但会把竖屏短剧在换集时甩成横屏，只是把 bug 换个方向。否掉。
- **尺寸未知时保持"进入全屏那一刻算出的方向"**：需要缓存首次判断结果，而首次判断本身可能就发生在尺寸未知时（自动连播进入下一集正好如此），缓存下来的仍是错的。否掉。
- **等尺寸到达再进全屏**：视频加载前黑屏等待，劣化首帧体验，且自动连播时每集都要等。否掉。
- **用 `MediaQuery` 的当前方向代替视频宽高**：这样"方向"就永远等于当前方向，全屏永远不会主动转向横屏，横屏剧集在竖屏下进入全屏会保持竖屏。否掉。
- **只在换集时跳过方向应用**：能缓解本次现象，但尺寸到达后仍不会应用正确方向，横屏剧集要等下一次切全屏才转过来。选择用尺寸事件驱动重应用。
- **让锁定也冻结系统 UI 模式**：锁定已经隐藏控件；再冻结沉浸模式没有收益，反而可能在锁定期间留下系统栏。只让锁定冻结方向。

## Consequences

- 横屏全屏播放时自动连播下一集**保持横屏**，不再被掰回竖屏。
- 竖屏短剧仍然竖屏；横屏剧集在尺寸到达后自动转为横屏（此前要手动切一次全屏）。
- 锁定期间方向不再变化，解锁时才允许按视频方向调整 —— 与用户对"锁定"的预期一致。
- 尺寸未知时不再触碰方向，因此也不会与用户手动旋转打架。
- 方向请求带记忆（`_appliedOrientations` + `_appliedVideoSize`），尺寸没变就不会重复下发旋转指令，避免每帧重建都触发一次平台调用。
- 退出全屏仍然释放方向（`setPreferredOrientations([])`），恢复跟随设备。
- 布局不受影响：`PlayerVideoLayout.calculate` 本来就对 0×0 回退到 9:16 并据此给面板比例。

## Verification

- 新增 `test/player_orientation_test.dart`（4 项），用 `SystemChannels.platform` 的 mock 记录每一次 `SystemChrome.setPreferredOrientations`：
  - **换集不强制竖屏**：横屏全屏 → 换成 0×0 的新 player → 断言最近一次请求不是竖屏；
  - **尺寸到达后应用**：0×0 进入全屏（不下发任何方向）→ 尺寸变为 1920×1080 → 断言下发横屏；
  - 竖屏视频（1080×1920）全屏时下发竖屏；
  - 退出全屏时下发空列表（恢复跟随设备）。
- **反证**：把 `lib/widgets/video_player_chrome.dart` 暂存回改动前（`git stash push`）再跑同一批测试，前两项**失败**且信息正好是本次现象 —— `an episode change never forces portrait` 得到 `Actual: <true>`（确实强制了竖屏），`the real orientation is applied once the size arrives` 得到 `Actual: ['DeviceOrientation.portraitUp', 'DeviceOrientation.portraitDown']`（0×0 被判成竖屏）。恢复改动后 4 项全绿。
- 回归：`player_auto_advance_test.dart`、`player_page_stability_test.dart`、`player_page_loading_test.dart`、`video_player_chrome_test.dart`、`player_rendering_test.dart` 等播放器测试全部通过。
- `flutter analyze` 无问题；`flutter test` **808 项通过**（改动前 804）。
- 未做真机验证：本结论来自真机反馈，修复后需要复验"横屏看短剧连播是否保持横屏"。
