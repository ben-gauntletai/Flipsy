import 'package:flutter/material.dart';
import '../../../services/video_service.dart';

class BookmarkButton extends StatelessWidget {
  final String videoId;
  final bool isBookmarked;
  final VoidCallback? onBookmarkChanged;
  final bool showCount;
  final int? count;
  final Color? color;
  final double size;

  const BookmarkButton({
    super.key,
    required this.videoId,
    required this.isBookmarked,
    this.onBookmarkChanged,
    this.showCount = true,
    this.count,
    this.color,
    this.size = 24,
  });

  @override
  Widget build(BuildContext context) {
    final VideoService videoService = VideoService();

    return GestureDetector(
      onTap: () async {
        if (isBookmarked) {
          await videoService.unbookmarkVideo(videoId);
        } else {
          await videoService.bookmarkVideo(videoId);
        }
        onBookmarkChanged?.call();
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isBookmarked ? Icons.bookmark : Icons.bookmark_border,
            color: color ?? Colors.white,
            size: size,
          ),
          if (showCount && count != null) ...[
            const SizedBox(width: 4),
            Text(
              _formatCount(count!),
              style: TextStyle(
                color: color ?? Colors.white,
                fontSize: size * 0.6,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _formatCount(int count) {
    if (count < 1000) return count.toString();
    if (count < 1000000) return '${(count / 1000).toStringAsFixed(1)}K';
    return '${(count / 1000000).toStringAsFixed(1)}M';
  }
}
