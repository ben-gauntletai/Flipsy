import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../../../models/video.dart';
import '../widgets/video_timeline.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class VideoPlayerScreen extends StatefulWidget {
  final String videoId;

  const VideoPlayerScreen({
    super.key,
    required this.videoId,
  });

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late VideoPlayerController _controller;
  late Future<void> _initializeVideoPlayerFuture;
  List<String> _steps = [];
  List<double> _timestamps = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    print('VideoPlayerScreen initialized');
    _loadVideoData();
  }

  Future<void> _loadVideoData() async {
    try {
      print('Starting to load video data for ID: ${widget.videoId}');

      // Get video data from Firestore
      final videoDoc = await FirebaseFirestore.instance
          .collection('videos')
          .doc(widget.videoId)
          .get();

      if (!videoDoc.exists) {
        print('Video document not found');
        setState(() {
          _error = 'Video not found';
          _isLoading = false;
        });
        return;
      }

      final videoData = videoDoc.data()!;
      print('Video data retrieved: ${videoData.keys}');

      final videoUrl = videoData['videoURL'] as String;
      print('Video URL: $videoUrl');

      // Initialize video player
      _controller = VideoPlayerController.network(videoUrl);
      _initializeVideoPlayerFuture = _controller.initialize();

      // Wait for initialization to get video duration
      await _initializeVideoPlayerFuture;
      final videoDuration = _controller.value.duration.inSeconds.toDouble();
      print('Video duration: $videoDuration seconds');

      // Get analysis data
      final analysis = videoData['analysis'] as Map<String, dynamic>?;
      print('Analysis data: $analysis');

      if (analysis != null) {
        final steps = List<String>.from(analysis['steps'] ?? []);
        print('Found ${steps.length} steps: $steps');

        final timestamps = steps.map((step) {
          final match = RegExp(r'\[(\d+\.?\d*)s\]$').firstMatch(step);
          final timestamp = match != null ? double.parse(match.group(1)!) : 0.0;
          print('Step: $step -> Timestamp: $timestamp');
          return timestamp;
        }).toList();
        print('Extracted timestamps: $timestamps');

        // Add ending step with timestamp
        final allSteps = [
          ...steps
              .map((step) => step.replaceAll(RegExp(r'\[\d+\.?\d*s\]$'), '')),
          'Conclusion'
        ];
        final allTimestamps = [...timestamps, videoDuration];

        print('Final steps (${allSteps.length}): $allSteps');
        print('Final timestamps (${allTimestamps.length}): $allTimestamps');

        setState(() {
          _steps = allSteps;
          _timestamps = allTimestamps;
        });
      } else {
        print('No analysis data found in video document');
      }

      setState(() {
        _isLoading = false;
      });

      // Start playing the video
      await _controller.play();
      print('Video playback started');
    } catch (e, stackTrace) {
      print('Error in _loadVideoData: $e');
      print('Stack trace: $stackTrace');
      setState(() {
        _error = 'Error loading video: $e';
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    print('Disposing VideoPlayerScreen');
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    print(
        'Building VideoPlayerScreen - Steps: ${_steps.length}, Timestamps: ${_timestamps.length}');
    final screenHeight = MediaQuery.of(context).size.height;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.white),
                    ),
                  )
                : Column(
                    children: [
                      // Video player at the top
                      AspectRatio(
                        aspectRatio: _controller.value.aspectRatio,
                        child: Stack(
                          children: [
                            VideoPlayer(_controller),
                            GestureDetector(
                              onTap: () {
                                setState(() {
                                  if (_controller.value.isPlaying) {
                                    _controller.pause();
                                  } else {
                                    _controller.play();
                                  }
                                });
                              },
                              child: Container(
                                color: Colors.transparent,
                                child: Center(
                                  child: Icon(
                                    _controller.value.isPlaying
                                        ? Icons.pause
                                        : Icons.play_arrow,
                                    size: 64,
                                    color: Colors.white.withOpacity(0.7),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Debug info and timeline in the middle
                      Expanded(
                        child: Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              // Debug info
                              Container(
                                margin: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 8),
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.red.withOpacity(0.3),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  'Steps: ${_steps.length}, Timestamps: ${_timestamps.length}',
                                  style: const TextStyle(color: Colors.white),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                              const SizedBox(height: 16),
                              // Timeline
                              if (_steps.isNotEmpty && _timestamps.isNotEmpty)
                                Container(
                                  width: double.infinity,
                                  height: 120,
                                  margin: const EdgeInsets.symmetric(
                                      horizontal: 16),
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: Colors.grey[900],
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                        color: Colors.white24, width: 2),
                                  ),
                                  child: VideoTimeline(
                                    controller: _controller,
                                    steps: _steps,
                                    timestamps: _timestamps,
                                    color: Colors.white,
                                    backgroundColor: Colors.white24,
                                    height: 88,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }
}
