import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:video_player/video_player.dart';

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
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _slideAnimation;

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
    setState(() => _isShowingStep = true);
    _fadeController.forward();
  }

  void _hideStepText() {
    _fadeController.reverse().then((_) {
      if (mounted) {
        setState(() => _isShowingStep = false);
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

    // Different colors for intro, steps, and conclusion
    if (index == 0) {
      return Colors.green.withOpacity(0.9); // Intro marker
    } else if (index == totalSteps - 1) {
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
      extractedTimestamps = widget.timestamps;
    }

    // Filter out any invalid timestamps and sort them
    extractedTimestamps =
        extractedTimestamps.where((t) => t > 0 && t.isFinite).toList()..sort();

    final duration = widget.controller.value.duration.inSeconds.toDouble();
    return [0.0, ...extractedTimestamps, duration];
  }

  List<String> get _fullSteps {
    // Strip timestamps from step text but preserve the step content
    final cleanedSteps = widget.steps.map((step) {
      return step.replaceAll(RegExp(r'\s*\[\d+\.?\d*s\]$'), '').trim();
    }).toList();

    return ['Intro', ...cleanedSteps, 'End'];
  }

  void _updateHoverPosition(Offset? position, BoxConstraints constraints) {
    if (position == null) {
      setState(() => _hoverPosition = null);
      return;
    }

    final RenderBox box = context.findRenderObject() as RenderBox;
    final double localDx = box.globalToLocal(position).dx;
    final double progress =
        (localDx.clamp(0, constraints.maxWidth)) / constraints.maxWidth;
    setState(() => _hoverPosition = progress);
  }

  Duration _getHoverDuration(BoxConstraints constraints) {
    if (_hoverPosition == null ||
        !mounted ||
        !widget.controller.value.isInitialized) {
      return Duration.zero;
    }
    return widget.controller.value.duration * _hoverPosition!;
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
            child: Container(
              height: 18,
              width: double.infinity,
              child: MouseRegion(
                onEnter: (_) => setState(() => _isHovering = true),
                onExit: (_) {
                  if (!mounted) return;
                  setState(() {
                    _isHovering = false;
                    _hoverPosition = null;
                  });
                },
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return Stack(
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
                                  height: 4,
                                  margin:
                                      const EdgeInsets.symmetric(vertical: 7),
                                  decoration: BoxDecoration(
                                    color: widget.backgroundColor ??
                                        Colors.white24,
                                    borderRadius: BorderRadius.circular(2),
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

                                  return Positioned(
                                    left: constraints.maxWidth * segmentStart,
                                    top: 0,
                                    child: Container(
                                      width: constraints.maxWidth *
                                          (segmentEnd - segmentStart),
                                      height: _isHovering ? 18 : 16,
                                      decoration: BoxDecoration(
                                        color: widget.color ??
                                            Theme.of(context).primaryColor,
                                        borderRadius: BorderRadius.circular(9),
                                      ),
                                    ),
                                  );
                                }),
                                // Current position dot
                                Positioned(
                                  left: (constraints.maxWidth * progress) - 10,
                                  top: -6,
                                  child: Container(
                                    width: _isHovering ? 24 : 20,
                                    height: _isHovering ? 24 : 20,
                                    decoration: BoxDecoration(
                                      color: widget.color ??
                                          Theme.of(context).primaryColor,
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
                                ),
                                // Gesture detector for timeline interactions
                                GestureDetector(
                                  onTapDown: (details) => _handleTimelineClick(
                                      details, constraints),
                                  onHorizontalDragStart: (details) {
                                    if (!mounted) return;
                                    _isDragging = true;
                                    _handleTimelineClick(
                                      TapDownDetails(
                                        globalPosition: details.globalPosition,
                                        kind: PointerDeviceKind.touch,
                                      ),
                                      constraints,
                                    );
                                  },
                                  onHorizontalDragUpdate: (details) {
                                    if (!mounted ||
                                        !widget.controller.value.isInitialized)
                                      return;
                                    final RenderBox box =
                                        context.findRenderObject() as RenderBox;
                                    final double localDx = box
                                        .globalToLocal(details.globalPosition)
                                        .dx;
                                    final double progress = (localDx.clamp(
                                            0, constraints.maxWidth)) /
                                        constraints.maxWidth;
                                    final Duration position =
                                        widget.controller.value.duration *
                                            progress;
                                    _positionNotifier.value = position;
                                    widget.controller.seekTo(position);
                                  },
                                  onHorizontalDragEnd: (_) {
                                    if (!mounted) return;
                                    _isDragging = false;
                                    Future.delayed(const Duration(seconds: 2),
                                        _hideStepText);
                                  },
                                  child: Container(
                                    width: double.infinity,
                                    height: 18,
                                    color: Colors.transparent,
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                        // Step text with fade and slide animation - Adjusted position
                        if (_isShowingStep || _isDragging)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 32,
                            child: AnimatedBuilder(
                              animation: _fadeController,
                              builder: (context, child) {
                                return Transform.translate(
                                  offset: Offset(0, _slideAnimation.value),
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
                                      !widget.controller.value.isInitialized) {
                                    return const SizedBox();
                                  }

                                  final currentTime =
                                      position.inSeconds.toDouble();
                                  int currentStepIndex =
                                      _fullTimestamps.indexWhere((timestamp) =>
                                              timestamp > currentTime) -
                                          1;
                                  if (currentStepIndex < 0)
                                    currentStepIndex = 0;
                                  if (currentStepIndex >= _fullSteps.length)
                                    currentStepIndex = _fullSteps.length - 1;

                                  return Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 6, horizontal: 8),
                                    margin: const EdgeInsets.symmetric(
                                        horizontal: 16),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withOpacity(0.8),
                                      borderRadius: BorderRadius.circular(4),
                                      border: Border.all(
                                        color: Colors.white24,
                                        width: 1,
                                      ),
                                    ),
                                    child: Text(
                                      _fullSteps[currentStepIndex],
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
                                },
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
