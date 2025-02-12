import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:video_player/video_player.dart';
import 'dart:async';

class AudioStateManager {
  static int? _currentlyPlayingIndex;
  static bool _globalMute = false;
  static bool _isTransitioning = false; // Add lock for state transitions

  static int? get currentlyPlayingIndex => _currentlyPlayingIndex;
  static bool get isGloballyMuted => _globalMute;

  // Attempt to claim audio focus, returns true if successful
  static bool requestAudioFocus(int index) {
    if (_isTransitioning) return false;
    _isTransitioning = true;

    try {
      // Only grant focus if no other video is playing or this video already has focus
      if (_currentlyPlayingIndex == null || _currentlyPlayingIndex == index) {
        _currentlyPlayingIndex = index;
        return true;
      }
      return false;
    } finally {
      _isTransitioning = false;
    }
  }

  static void releaseAudioFocus(int index) {
    if (_isTransitioning) return;
    _isTransitioning = true;

    try {
      // Only release if this video has focus
      if (_currentlyPlayingIndex == index) {
        _currentlyPlayingIndex = null;
      }
    } finally {
      _isTransitioning = false;
    }
  }

  static bool shouldPlayAudio(int index) {
    return !_globalMute && _currentlyPlayingIndex == index;
  }

  static void setGlobalMute(bool mute) {
    if (_isTransitioning) return;
    _isTransitioning = true;

    try {
      _globalMute = mute;
      if (mute) {
        _currentlyPlayingIndex = null;
      }
    } finally {
      _isTransitioning = false;
    }
  }

  // Clean up when leaving the feed
  static void reset() {
    _currentlyPlayingIndex = null;
    _globalMute = false;
    _isTransitioning = false;
  }
}

class VideoTimeline extends StatefulWidget {
  final VideoPlayerController controller;
  final List<String> steps;
  final List<double> timestamps;
  final double height;
  final Color? color;
  final Color? backgroundColor;

  const VideoTimeline({
    super.key,
    required this.controller,
    required this.steps,
    required this.timestamps,
    this.height = 32.0,
    this.color,
    this.backgroundColor,
  });

  @override
  State<VideoTimeline> createState() => _VideoTimelineState();
}

class _VideoTimelineState extends State<VideoTimeline>
    with SingleTickerProviderStateMixin {
  late ValueNotifier<Duration> _positionNotifier;
  bool _isDragging = false;
  bool _isShowingStep = false;
  bool _isHovering = false;
  double? _hoverPosition;
  double? _previewPosition;
  Timer? _seekTimer;
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _slideAnimation;
  Timer? _hideTextTimer;

  @override
  void initState() {
    super.initState();
    _positionNotifier = ValueNotifier<Duration>(Duration.zero);
    widget.controller.addListener(_updatePosition);

    // Add minimal debug logging for initial values
    Future.delayed(Duration.zero, () {
      if (mounted && widget.controller.value.isInitialized) {
        print(
            'VideoTimeline: duration=${widget.controller.value.duration.inSeconds}s, steps=${widget.steps.length}, timestamps=${widget.timestamps.length}');
      }
    });

    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _fadeController,
        curve: Curves.easeOut,
      ),
    );
    _slideAnimation = Tween<double>(begin: 4.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _fadeController,
        curve: Curves.easeOut,
      ),
    );
  }

  @override
  void dispose() {
    _seekTimer?.cancel();
    _hideTextTimer?.cancel();
    print('VideoTimeline disposing');
    widget.controller.removeListener(_updatePosition);
    _positionNotifier.dispose();
    _fadeController.dispose();
    super.dispose();
  }

  void _updatePosition() {
    if (!mounted || _isDragging) return;
    _positionNotifier.value = widget.controller.value.position;
  }

  void _showStepText() {
    _hideTextTimer?.cancel();
    setState(() => _isShowingStep = true);
    _fadeController.forward();
  }

  void _hideStepText() {
    _hideTextTimer?.cancel();
    _hideTextTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) {
        _fadeController.reverse().then((_) {
          if (mounted) {
            setState(() => _isShowingStep = false);
          }
        });
      }
    });
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "${duration.inHours > 0 ? '${twoDigits(duration.inHours)}:' : ''}$twoDigitMinutes:$twoDigitSeconds";
  }

  Color _getMarkerColor(int index, Color primaryColor) {
    final totalSteps = _fullTimestamps.length;

    // Different colors for conclusion only
    if (index == totalSteps - 1) {
      return Colors.red.withOpacity(0.9); // Conclusion marker
    } else {
      return primaryColor
          .withOpacity(0.9); // Regular step marker - increased opacity
    }
  }

  Widget _buildMarker(int index, double progress, Color markerColor,
      BoxConstraints constraints) {
    final isIntro = index == 0;
    final isConclusion = index == _fullTimestamps.length - 1;
    final isHovered = _hoverPosition != null &&
        (_hoverPosition! * constraints.maxWidth -
                    constraints.maxWidth * progress)
                .abs() <
            10;

    return Positioned(
      left: constraints.maxWidth * progress - 6,
      top: _isHovering ? 1 : 2,
      child: Tooltip(
        message: _fullSteps[index],
        waitDuration: const Duration(milliseconds: 500),
        showDuration: const Duration(seconds: 2),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.9),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Colors.white24, width: 1),
        ),
        textStyle: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
        preferBelow: false,
        verticalOffset: -24,
        child: MouseRegion(
          onEnter: (_) => setState(() => _showStepText()),
          onExit: (_) => setState(() => _hideStepText()),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: isHovered ? 14 : 12,
            height: isHovered ? 14 : 12,
            decoration: BoxDecoration(
              color: markerColor,
              shape: isIntro || isConclusion
                  ? BoxShape.rectangle
                  : BoxShape.circle,
              borderRadius:
                  (isIntro || isConclusion) ? BorderRadius.circular(3) : null,
              border: Border.all(
                color: Colors.white,
                width: isHovered ? 2 : 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: markerColor.withOpacity(0.5),
                  blurRadius: isHovered ? 6 : 3,
                  spreadRadius: isHovered ? 2 : 0,
                ),
                if (isHovered)
                  BoxShadow(
                    color: Colors.white.withOpacity(0.3),
                    blurRadius: 4,
                    spreadRadius: 1,
                  ),
              ],
            ),
            transform: isHovered
                ? (Matrix4.identity()..scale(1.2))
                : Matrix4.identity(),
          ),
        ),
      ),
    );
  }

  void _handleTimelineClick(
      TapDownDetails details, BoxConstraints constraints) {
    if (!mounted || !widget.controller.value.isInitialized) return;
    final RenderBox box = context.findRenderObject() as RenderBox;
    final double localDx = box.globalToLocal(details.globalPosition).dx;
    final double progress =
        (localDx.clamp(0, constraints.maxWidth)) / constraints.maxWidth;

    // Immediately update preview position and seek
    setState(() {
      _previewPosition = progress;
    });

    // Perform the seek immediately for clicks
    final Duration position = widget.controller.value.duration * progress;
    widget.controller.seekTo(position);
    _showStepText();
  }

  List<double> get _fullTimestamps {
    if (!mounted || !widget.controller.value.isInitialized) return [0.0];

    // Extract timestamps from steps if not provided directly
    List<double> extractedTimestamps;
    if (widget.timestamps.isEmpty) {
      extractedTimestamps = widget.steps.map((step) {
        final match = RegExp(r'\[(\d+\.?\d*)s\]$').firstMatch(step);
        return match != null ? double.parse(match.group(1)!) : 0.0;
      }).toList();
    } else {
      extractedTimestamps = List<double>.from(widget.timestamps);
    }

    // Filter out any invalid timestamps, sort them, and remove duplicates
    extractedTimestamps = extractedTimestamps
        .where((t) => t.isFinite) // Allow 0.0 timestamps
        .toSet()
        .toList()
      ..sort();

    // Ensure we start from 0.0 if not already included
    if (extractedTimestamps.isEmpty || extractedTimestamps.first > 0) {
      extractedTimestamps.insert(0, 0.0);
    }

    final duration = widget.controller.value.duration.inSeconds.toDouble();

    // Only add duration if it's not already in the list
    if (extractedTimestamps.isEmpty || extractedTimestamps.last != duration) {
      extractedTimestamps.add(duration);
    }

    return extractedTimestamps;
  }

  List<String> get _fullSteps {
    // Strip timestamps from step text but preserve the step content
    final cleanedSteps = widget.steps.map((step) {
      return step
          .replaceAll(RegExp(r'\s*\[\d+\.?\d*s\s*-\s*\d+\.?\d*s\]$'), '')
          .trim();
    }).toList();

    return [...cleanedSteps, 'End'];
  }

  void _updateHoverPosition(Offset? position, BoxConstraints constraints) {
    if (position == null) {
      setState(() => _hoverPosition = null);
      _hideStepText();
      return;
    }

    final RenderBox box = context.findRenderObject() as RenderBox;
    final double localDx = box.globalToLocal(position).dx;
    final double progress =
        (localDx.clamp(0, constraints.maxWidth)) / constraints.maxWidth;
    setState(() {
      _hoverPosition = progress;
      _isShowingStep = true;
    });
    _showStepText();
  }

  Duration _getHoverDuration(BoxConstraints constraints) {
    if (_hoverPosition == null ||
        !mounted ||
        !widget.controller.value.isInitialized) {
      return Duration.zero;
    }
    return widget.controller.value.duration * _hoverPosition!;
  }

  // Replace the current position dot with this new method
  Widget _buildPositionIndicator(double progress, BoxConstraints constraints) {
    // Use preview position while dragging, otherwise use actual progress
    final displayProgress =
        _isDragging ? (_previewPosition ?? progress) : progress;

    return Positioned(
      left: (constraints.maxWidth * displayProgress) - 10,
      top: -6,
      child: Container(
        width: _isHovering ? 24 : 20,
        height: _isHovering ? 24 : 20,
        decoration: BoxDecoration(
          color: widget.color ?? Theme.of(context).primaryColor,
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white,
            width: 3,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 4,
              spreadRadius: 1,
            ),
          ],
        ),
      ),
    );
  }

  // Add a preview time indicator
  Widget _buildTimePreview(BoxConstraints constraints) {
    if (!_isDragging && !_isHovering) return const SizedBox();

    final previewProgress =
        _isDragging ? (_previewPosition ?? 0.0) : _hoverPosition ?? 0.0;
    final previewDuration = widget.controller.value.duration * previewProgress;

    return Positioned(
      left: (constraints.maxWidth * previewProgress)
          .clamp(40.0, constraints.maxWidth - 40),
      bottom: 24,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          _formatDuration(previewDuration),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  String _getCurrentStepText(double currentTime) {
    // Find the index of the first timestamp that is greater than the current time
    int currentStepIndex =
        _fullTimestamps.indexWhere((timestamp) => timestamp >= currentTime);

    // If we're at the end of the video or no matching timestamp found
    if (currentStepIndex == -1) {
      return _fullSteps.last; // Return the last step (End)
    }

    // If we're exactly at a timestamp, use that step
    if (currentStepIndex < _fullSteps.length) {
      return _fullSteps[currentStepIndex];
    }

    // If we're between timestamps, use the previous step
    if (currentStepIndex > 0) {
      return _fullSteps[currentStepIndex - 1];
    }

    // Fallback to first step
    return _fullSteps.first;
  }

  void _handleDragStart(DragStartDetails details, BoxConstraints constraints) {
    if (!mounted) return;
    setState(() {
      _isDragging = true;
      _isShowingStep = true;
    });

    final RenderBox box = context.findRenderObject() as RenderBox;
    final double localDx = box.globalToLocal(details.globalPosition).dx;
    final double progress =
        (localDx.clamp(0, constraints.maxWidth)) / constraints.maxWidth;

    setState(() {
      _previewPosition = progress;
    });

    _showStepText();
  }

  void _handleDragUpdate(
      DragUpdateDetails details, BoxConstraints constraints) {
    if (!mounted || !widget.controller.value.isInitialized) return;

    final RenderBox box = context.findRenderObject() as RenderBox;
    final double localDx = box.globalToLocal(details.globalPosition).dx;
    final double progress =
        (localDx.clamp(0, constraints.maxWidth)) / constraints.maxWidth;

    // Calculate drag speed (pixels per millisecond)
    final dragSpeed = details.primaryDelta?.abs() ?? 0;
    final isFineScrubbing = dragSpeed < 2.0; // Threshold for fine scrubbing

    // Update preview position and step text immediately
    setState(() {
      _previewPosition = progress;
      _isShowingStep = true;
    });

    // Cancel any pending seek timer
    _seekTimer?.cancel();

    // Use different debounce times based on scrubbing mode
    final debounceTime = isFineScrubbing
        ? 16
        : 33; // 16ms (60fps) for fine scrubbing, 33ms (~30fps) for normal

    _seekTimer = Timer(Duration(milliseconds: debounceTime), () {
      if (!mounted) return;
      final Duration position = widget.controller.value.duration * progress;
      widget.controller.seekTo(position);
    });
  }

  void _handleDragEnd(DragEndDetails details) {
    if (!mounted) return;

    // Cancel any pending seek timer
    _seekTimer?.cancel();

    // Perform final seek immediately if needed
    if (_previewPosition != null) {
      final Duration position =
          widget.controller.value.duration * _previewPosition!;
      widget.controller.seekTo(position);
    }

    setState(() {
      _isDragging = false;
      _previewPosition = null;
    });

    _hideStepText();
  }

  // Add a method to handle hover position updates more frequently
  void _handleHoverUpdate(PointerHoverEvent event, BoxConstraints constraints) {
    if (!mounted) return;
    final RenderBox box = context.findRenderObject() as RenderBox;
    final double localDx = box.globalToLocal(event.position).dx;
    final double progress = (localDx.clamp(0, box.size.width)) / box.size.width;
    setState(() {
      _hoverPosition = progress;
      _isShowingStep = true;
    });
  }

  Widget _buildStepText(double currentTime) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.8),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: Colors.white24,
          width: 1,
        ),
      ),
      child: Text(
        _getCurrentStepText(currentTime),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.controller.value.isInitialized) {
      return const SizedBox();
    }

    return Container(
      width: double.infinity,
      height: widget.height + 40,
      padding: EdgeInsets.zero,
      margin: EdgeInsets.zero,
      child: Stack(
        children: [
          // Background container to capture gestures
          Container(
            width: double.infinity,
            height: widget.height + 40,
            color: Colors.transparent,
          ),
          // Timeline bar with hover effect - Keep at bottom
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: LayoutBuilder(
              builder: (context, constraints) {
                return MouseRegion(
                  onEnter: (_) => setState(() => _isHovering = true),
                  onExit: (_) {
                    if (!mounted) return;
                    setState(() {
                      _isHovering = false;
                      _hoverPosition = null;
                      _isShowingStep = false;
                    });
                  },
                  onHover: (event) => _handleHoverUpdate(event, constraints),
                  child: Container(
                    height: 18,
                    width: double.infinity,
                    padding: EdgeInsets.zero,
                    margin: EdgeInsets.zero,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        // Background
                        Container(
                          width: double.infinity,
                          height: _isHovering ? 18 : 16,
                          color: widget.backgroundColor ?? Colors.white24,
                        ),
                        // Buffer progress
                        ValueListenableBuilder<Duration>(
                          valueListenable: _positionNotifier,
                          builder: (context, position, _) {
                            if (!mounted ||
                                !widget.controller.value.isInitialized) {
                              return const SizedBox();
                            }

                            final buffered = widget.controller.value.buffered;
                            if (buffered.isEmpty) return const SizedBox();

                            final bufferProgress = buffered
                                    .last.end.inMilliseconds /
                                widget.controller.value.duration.inMilliseconds;

                            return Container(
                              width: constraints.maxWidth * bufferProgress,
                              height: _isHovering ? 18 : 16,
                              color: Colors.white.withOpacity(0.3),
                            );
                          },
                        ),
                        // Progress bar with segments and bubbles
                        ValueListenableBuilder<Duration>(
                          valueListenable: _positionNotifier,
                          builder: (context, position, _) {
                            if (!mounted ||
                                !widget.controller.value.isInitialized) {
                              return const SizedBox();
                            }

                            final progress = position.inMilliseconds /
                                widget.controller.value.duration.inMilliseconds;

                            return Stack(
                              clipBehavior: Clip.none,
                              children: [
                                // Background track
                                Container(
                                  width: double.infinity,
                                  height: _isHovering ? 18 : 16,
                                  decoration: BoxDecoration(
                                    color: widget.backgroundColor ??
                                        Colors.white24,
                                  ),
                                ),
                                // Segment bubbles making up the purple line
                                ...List.generate(_fullTimestamps.length - 1,
                                    (index) {
                                  final startTime = _fullTimestamps[index];
                                  final endTime = _fullTimestamps[index + 1];
                                  final segmentStart = startTime /
                                      widget
                                          .controller.value.duration.inSeconds;
                                  final segmentEnd = endTime /
                                      widget
                                          .controller.value.duration.inSeconds;

                                  return Stack(
                                    children: [
                                      // Segment
                                      Positioned(
                                        left:
                                            constraints.maxWidth * segmentStart,
                                        top: 0,
                                        child: Container(
                                          width: constraints.maxWidth *
                                              (segmentEnd - segmentStart),
                                          height: _isHovering ? 18 : 16,
                                          decoration: BoxDecoration(
                                            color: widget.color ?? Colors.black,
                                          ),
                                        ),
                                      ),
                                      // White separator line (for all segments except the last)
                                      if (index < _fullTimestamps.length - 2)
                                        Positioned(
                                          left: constraints.maxWidth *
                                                  endTime /
                                                  widget.controller.value
                                                      .duration.inSeconds -
                                              1,
                                          top: 0,
                                          child: Container(
                                            width: 2,
                                            height: _isHovering ? 18 : 16,
                                            color: Colors.white,
                                          ),
                                        ),
                                    ],
                                  );
                                }),
                                // Current position dot
                                _buildPositionIndicator(progress, constraints),
                                // Gesture detector for timeline interactions
                                Positioned.fill(
                                  child: GestureDetector(
                                    onTapDown: (details) =>
                                        _handleTimelineClick(
                                            details, constraints),
                                    onHorizontalDragStart: (details) =>
                                        _handleDragStart(details, constraints),
                                    onHorizontalDragUpdate: (details) =>
                                        _handleDragUpdate(details, constraints),
                                    onHorizontalDragEnd: _handleDragEnd,
                                    behavior: HitTestBehavior.opaque,
                                  ),
                                ),
                                // Step text with fade and slide animation
                                if (_isShowingStep ||
                                    _isDragging ||
                                    _isHovering)
                                  Positioned(
                                    left: 0,
                                    right: 0,
                                    bottom: 32,
                                    child: AnimatedBuilder(
                                      animation: _fadeController,
                                      builder: (context, child) {
                                        return Transform.translate(
                                          offset:
                                              Offset(0, _slideAnimation.value),
                                          child: Opacity(
                                            opacity: _fadeAnimation.value,
                                            child: child,
                                          ),
                                        );
                                      },
                                      child: ValueListenableBuilder<Duration>(
                                        valueListenable: _positionNotifier,
                                        builder: (context, position, _) {
                                          if (!mounted ||
                                              !widget.controller.value
                                                  .isInitialized) {
                                            return const SizedBox();
                                          }

                                          final currentTime = _isDragging &&
                                                  _previewPosition != null
                                              ? _previewPosition! *
                                                  widget.controller.value
                                                      .duration.inSeconds
                                              : _isHovering &&
                                                      _hoverPosition != null
                                                  ? _hoverPosition! *
                                                      widget.controller.value
                                                          .duration.inSeconds
                                                  : position.inSeconds
                                                      .toDouble();

                                          return _buildStepText(currentTime);
                                        },
                                      ),
                                    ),
                                  ),
                                // Time preview
                                _buildTimePreview(constraints),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
