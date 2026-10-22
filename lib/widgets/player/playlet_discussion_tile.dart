import 'package:flutter/material.dart';

import '../comment_images.dart';
import '../home/home_design.dart';

/// 剧评与回复共用官方的头像、昵称、正文和计数布局；账号写操作不在本页提供。
class PlayletDiscussionTile extends StatelessWidget {
  const PlayletDiscussionTile({
    super.key,
    required this.text,
    this.imageUrls = const [],
    required this.userName,
    required this.userAvatar,
    required this.published,
    required this.diggCount,
    this.replyCount,
    this.onReplies,
    this.highlighted = false,
  });

  final String text;
  final List<String> imageUrls;
  final String userName;
  final String userAvatar;
  final String published;
  final int diggCount;
  final int? replyCount;
  final VoidCallback? onReplies;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Container(
      color: highlighted ? const Color(0x14FA6725) : null,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: palette.dark
                ? palette.soft
                : const Color(0xFFEDEDF0),
            foregroundImage: userAvatar.isEmpty
                ? null
                : NetworkImage(userAvatar),
            child: userAvatar.isEmpty
                ? Text(
                    userName.isEmpty ? '?' : userName.characters.first,
                    style: const TextStyle(fontSize: 13),
                  )
                : null,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  userName.isEmpty ? '匿名用户' : userName,
                  style: TextStyle(fontSize: 13, color: palette.muted),
                ),
                const SizedBox(height: 4),
                if (text.isNotEmpty)
                  Text(
                    text,
                    style: TextStyle(fontSize: 15, color: palette.ink),
                  ),
                if (imageUrls.isNotEmpty) ...[
                  if (text.isNotEmpty) const SizedBox(height: 8),
                  CommentImages(imageUrls: imageUrls),
                ],
                const SizedBox(height: 6),
                Wrap(
                  spacing: 16,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (published.isNotEmpty)
                      Text(
                        published,
                        style: TextStyle(fontSize: 12, color: palette.muted),
                      ),
                    Semantics(
                      label: '$diggCount 个赞',
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.thumb_up_alt_outlined,
                            size: 14,
                            color: palette.muted,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '$diggCount',
                            style: TextStyle(fontSize: 12, color: palette.muted),
                          ),
                        ],
                      ),
                    ),
                    if (replyCount != null)
                      TextButton(
                        onPressed: onReplies,
                        style: TextButton.styleFrom(
                          foregroundColor: palette.muted,
                          minimumSize: const Size(48, 48),
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                        ),
                        child: Text(
                          '$replyCount 条回复',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
