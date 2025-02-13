import 'package:flutter/material.dart';
import '../../../models/video.dart';

class SubtitlesOverlay extends StatelessWidget {
  final List<TranscriptionSegment> segments;
  final Duration currentPosition;
  final bool visible;

  const SubtitlesOverlay({
    super.key,
    required this.segments,
    required this.currentPosition,
    required this.visible,
  });

  TranscriptionSegment? _findCurrentSegment() {
    if (segments.isEmpty) return null;

    final currentSeconds = currentPosition.inMilliseconds / 1000;

    // Binary search for efficiency
    int low = 0;
    int high = segments.length - 1;

    while (low <= high) {
      final mid = (low + high) ~/ 2;
      final segment = segments[mid];

      if (currentSeconds >= segment.start && currentSeconds <= segment.end) {
        return segment;
      }

      if (currentSeconds < segment.start) {
        high = mid - 1;
      } else {
        low = mid + 1;
      }
    }

    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();

    final currentSegment = _findCurrentSegment();
    if (currentSegment == null) return const SizedBox.shrink();

    return Positioned(
      left: 0,
      right: 0,
      bottom: 80, // Position above the timeline
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.6),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            currentSegment.text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}
