import 'package:flutter/material.dart';

/// Upstream comment bodies encode emoji as `[微笑]`-style bracket tokens.
///
/// The official client finds them with `\[[A-Z一-龥]+\]`
/// (`is4/i.java`, `com/dragon/community/kmp/utils/a.java`) and replaces each
/// known token with a bundled 120x120 webp (`jp4/j0.java` maps the token id to
/// a drawable; `apktool/assets/emoji_config.json` holds the 53 tokens).
final RegExp commentEmojiPattern = RegExp(r'\[[A-Z一-龥]+\]');

/// Token to bundled asset, extracted from the official client.
///
/// The asset numbers follow `emoji_config.json`; the images are the official
/// `drawable-xxhdpi` webp files, copied as-is like `assets/images/bubble/` and
/// `assets/images/drama/`.
const Map<String, String> commentEmojiAssets = {
  '[微笑]': 'assets/images/emoji/emoji_01.webp',
  '[偷笑]': 'assets/images/emoji/emoji_02.webp',
  '[笑]': 'assets/images/emoji/emoji_03.webp',
  '[什么]': 'assets/images/emoji/emoji_04.webp',
  '[害羞]': 'assets/images/emoji/emoji_05.webp',
  '[爱慕]': 'assets/images/emoji/emoji_06.webp',
  '[飞吻]': 'assets/images/emoji/emoji_07.webp',
  '[奸笑]': 'assets/images/emoji/emoji_08.webp',
  '[尬笑]': 'assets/images/emoji/emoji_09.webp',
  '[思考]': 'assets/images/emoji/emoji_10.webp',
  '[撇嘴]': 'assets/images/emoji/emoji_11.webp',
  '[做鬼脸]': 'assets/images/emoji/emoji_12.webp',
  '[酷]': 'assets/images/emoji/emoji_13.webp',
  '[翻白眼]': 'assets/images/emoji/emoji_14.webp',
  '[惊呆]': 'assets/images/emoji/emoji_15.webp',
  '[震惊]': 'assets/images/emoji/emoji_16.webp',
  '[送心]': 'assets/images/emoji/emoji_17.webp',
  '[委屈]': 'assets/images/emoji/emoji_18.webp',
  '[快哭了]': 'assets/images/emoji/emoji_19.webp',
  '[笑哭]': 'assets/images/emoji/emoji_20.webp',
  '[哭]': 'assets/images/emoji/emoji_21.webp',
  '[大笑]': 'assets/images/emoji/emoji_22.webp',
  '[舔屏]': 'assets/images/emoji/emoji_23.webp',
  '[怒]': 'assets/images/emoji/emoji_24.webp',
  '[捂脸]': 'assets/images/emoji/emoji_25.webp',
  '[吐]': 'assets/images/emoji/emoji_26.webp',
  '[恐惧]': 'assets/images/emoji/emoji_27.webp',
  '[抓狂]': 'assets/images/emoji/emoji_28.webp',
  '[敬礼]': 'assets/images/emoji/emoji_29.webp',
  '[石化]': 'assets/images/emoji/emoji_30.webp',
  '[OK]': 'assets/images/emoji/emoji_31.webp',
  '[赞]': 'assets/images/emoji/emoji_32.webp',
  '[爱心]': 'assets/images/emoji/emoji_33.webp',
  '[伤心]': 'assets/images/emoji/emoji_34.webp',
  '[KISS]': 'assets/images/emoji/emoji_35.webp',
  '[懂了]': 'assets/images/emoji/emoji_36.webp',
  '[探究]': 'assets/images/emoji/emoji_37.webp',
  '[重拳出击]': 'assets/images/emoji/emoji_38.webp',
  '[吃瓜]': 'assets/images/emoji/emoji_39.webp',
  '[盯]': 'assets/images/emoji/emoji_40.webp',
  '[你细品]': 'assets/images/emoji/emoji_41.webp',
  '[赶稿中]': 'assets/images/emoji/emoji_42.webp',
  '[注意]': 'assets/images/emoji/emoji_43.webp',
  '[饱了]': 'assets/images/emoji/emoji_44.webp',
  '[码住]': 'assets/images/emoji/emoji_45.webp',
  '[学会了]': 'assets/images/emoji/emoji_46.webp',
  '[顶帖]': 'assets/images/emoji/emoji_47.webp',
  '[求爆更]': 'assets/images/emoji/emoji_48.webp',
  '[求关注]': 'assets/images/emoji/emoji_49.webp',
  '[我也强推]': 'assets/images/emoji/emoji_50.webp',
  '[雀食神作]': 'assets/images/emoji/emoji_51.webp',
  '[已种草]': 'assets/images/emoji/emoji_52.webp',
  '[书架加一]': 'assets/images/emoji/emoji_53.webp',
};

bool hasCommentEmoji(String text) => commentEmojiPattern.hasMatch(text);

/// Splits [text] into plain and inline-image spans.
///
/// Unknown bracket tokens stay literal; only the official set is replaced.
/// [fontSize] is the surrounding text size; the image matches the official
/// 1.4x ratio (`is4/i.java` sizes it at `sp(16) * 1.4`).
List<InlineSpan> commentEmojiSpans(String text, {required double fontSize}) {
  final size = fontSize * 1.4;
  final spans = <InlineSpan>[];
  var start = 0;
  for (final match in commentEmojiPattern.allMatches(text)) {
    if (match.start > start) {
      spans.add(TextSpan(text: text.substring(start, match.start)));
    }
    final token = match.group(0)!;
    final asset = commentEmojiAssets[token];
    spans.add(
      asset == null
          ? TextSpan(text: token)
          : WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Image.asset(
                asset,
                width: size,
                height: size,
                semanticLabel: token,
                filterQuality: FilterQuality.medium,
              ),
            ),
    );
    start = match.end;
  }
  if (start < text.length) spans.add(TextSpan(text: text.substring(start)));
  return spans;
}

/// Comment body with bracket emoji rendered as inline images.
///
/// Without a token it stays a plain [Text] so existing layout, selection and
/// `find.text` lookups are unchanged.
class CommentEmojiText extends StatelessWidget {
  const CommentEmojiText({super.key, required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    if (!hasCommentEmoji(text)) return Text(text, style: style);
    return Text.rich(
      TextSpan(
        style: style,
        children: commentEmojiSpans(text, fontSize: style.fontSize ?? 16),
      ),
    );
  }
}
