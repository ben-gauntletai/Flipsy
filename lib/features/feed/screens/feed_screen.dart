import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../../../services/video_service.dart';
import '../../../services/user_service.dart';
import '../../../models/video.dart';

class FeedScreen extends StatefulWidget {
  final bool isVisible;

  const FeedScreen({
    Key? key,
    this.isVisible = true,
  }) : super(key: key);

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> with WidgetsBindingObserver {
  late PageController _pageController;
  final VideoService _videoService = VideoService();
  final UserService _userService = UserService();
  List<Video> _videos = [];
  Map<String, Map<String, dynamic>> _usersData = {};
  bool _isLoading = true;
  final List<VideoPlayerController> _videoControllers = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pageController = PageController();
    _loadVideos();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disposeControllers();
    _pageController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _pauseAllVideos();
    }
  }

  void _disposeControllers() {
    for (var controller in _videoControllers) {
      controller.dispose();
    }
    _videoControllers.clear();
  }

  void _pauseAllVideos() {
    for (var controller in _videoControllers) {
      controller.pause();
    }
  }

  void _handleVisibilityChanged() {
    if (!widget.isVisible) {
      _pauseAllVideos();
    }
  }

  @override
  void didUpdateWidget(FeedScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isVisible != widget.isVisible) {
      _handleVisibilityChanged();
    }
  }

  Future<void> _loadUserData(List<Video> videos) async {
    final userIds = videos.map((v) => v.userId).toSet().toList();

    await Future.wait(
      userIds.map((userId) async {
        final userData = await _userService.getCachedUserData(userId);
        _usersData[userId] = userData;
      }),
    );
  }

  Future<void> _loadVideos() async {
    setState(() {
      _isLoading = true;
    });

    try {
      // Listen to the video feed stream
      _videoService.getVideoFeed().listen((videos) async {
        // Pre-fetch user data for all videos
        await _loadUserData(videos);

        if (mounted) {
          setState(() {
            _videos = videos;
            _isLoading = false;
          });
        }
      }, onError: (error) {
        print('Error loading videos: $error');
        setState(() {
          _isLoading = false;
        });
      });
    } catch (e) {
      print('Error setting up video stream: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Video Feed
          if (_isLoading)
            const Center(
              child: CircularProgressIndicator(
                color: Colors.white,
              ),
            )
          else if (_videos.isEmpty)
            const Center(
              child: Text(
                'No videos available',
                style: TextStyle(color: Colors.white),
              ),
            )
          else
            PageView.builder(
              controller: _pageController,
              scrollDirection: Axis.vertical,
              itemCount: _videos.length,
              itemBuilder: (context, index) {
                final video = _videos[index];
                final userData = _usersData[video.userId];
                return VideoFeedItem(
                  video: video,
                  userData: userData,
                  isVisible: widget.isVisible,
                );
              },
            ),

          // Top Navigation (Following/For You)
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        'Following',
                        style: TextStyle(
                          color: Colors.white60,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(width: 20),
                      Column(
                        children: [
                          const Text(
                            'For You',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Container(
                            width: 30,
                            height: 2,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(1),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                // Live indicator
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.red,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.live_tv,
                        color: Colors.white,
                        size: 12,
                      ),
                      SizedBox(width: 4),
                      Text(
                        'LIVE',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class VideoFeedItem extends StatefulWidget {
  final Video video;
  final Map<String, dynamic>? userData;
  final bool isVisible;

  const VideoFeedItem({
    Key? key,
    required this.video,
    this.userData,
    this.isVisible = true,
  }) : super(key: key);

  @override
  State<VideoFeedItem> createState() => _VideoFeedItemState();
}

class _VideoFeedItemState extends State<VideoFeedItem> {
  late VideoPlayerController _videoController;
  bool _isPlaying = true;

  @override
  void initState() {
    super.initState();
    _initializeVideo();
  }

  Future<void> _initializeVideo() async {
    try {
      _videoController = VideoPlayerController.network(widget.video.videoURL)
        ..initialize().then((_) {
          if (mounted) {
            setState(() {
              if (widget.isVisible) {
                _videoController.play();
                _videoController.setLooping(true);
              }
            });
          }
        });

      // Add controller to parent's list
      final feedState = context.findAncestorStateOfType<_FeedScreenState>();
      feedState?._videoControllers.add(_videoController);
    } catch (e) {
      print('Error initializing video: $e');
    }
  }

  @override
  void didUpdateWidget(VideoFeedItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isVisible != widget.isVisible) {
      if (!widget.isVisible) {
        _videoController.pause();
        _isPlaying = false;
      }
    }
  }

  @override
  void dispose() {
    // Remove controller from parent's list before disposing
    final feedState = context.findAncestorStateOfType<_FeedScreenState>();
    feedState?._videoControllers.remove(_videoController);
    _videoController.dispose();
    super.dispose();
  }

  void _togglePlay() {
    setState(() {
      _isPlaying = !_isPlaying;
      if (_isPlaying) {
        _videoController.play();
      } else {
        _videoController.pause();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final String displayName =
        widget.userData?['displayName'] ?? widget.video.userId;
    final String? avatarURL = widget.userData?['avatarURL'];

    return GestureDetector(
      onTap: () {
        if (widget.isVisible) {
          _togglePlay();
        }
      },
      child: Stack(
        children: [
          // Video Player
          SizedBox.expand(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: _videoController.value.size?.width ?? 0,
                height: _videoController.value.size?.height ?? 0,
                child: VideoPlayer(_videoController),
              ),
            ),
          ),

          // Play/Pause Overlay
          if (!_videoController.value.isInitialized)
            const Center(
              child: CircularProgressIndicator(
                color: Colors.white,
              ),
            ),

          // Right Side Action Buttons
          Positioned(
            right: 8,
            bottom: 100,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Profile Picture
                Stack(
                  alignment: Alignment.bottomCenter,
                  children: [
                    _buildCircleButton(
                      child: CircleAvatar(
                        radius: 20,
                        backgroundColor: Colors.grey,
                        backgroundImage:
                            avatarURL != null ? NetworkImage(avatarURL) : null,
                        child: avatarURL == null
                            ? const Icon(Icons.person,
                                color: Colors.white, size: 20)
                            : null,
                      ),
                    ),
                    Transform.translate(
                      offset: const Offset(0, 10),
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: const BoxDecoration(
                          color: Colors.pink,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.add,
                          color: Colors.white,
                          size: 12,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 25),

                // Like Button
                _buildActionButton(
                  icon: FontAwesomeIcons.solidHeart,
                  label: widget.video.likesCount.toString(),
                  iconSize: 28,
                ),
                const SizedBox(height: 15),

                // Comment Button
                _buildActionButton(
                  icon: FontAwesomeIcons.solidComment,
                  label: widget.video.commentsCount.toString(),
                  iconSize: 28,
                ),
                const SizedBox(height: 15),

                // Share Button
                _buildActionButton(
                  icon: FontAwesomeIcons.share,
                  label: 'Share',
                  iconSize: 28,
                ),
                const SizedBox(height: 15),

                // More Button
                Container(
                  width: 45,
                  height: 45,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.more_horiz,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ],
            ),
          ),

          // Bottom User Info
          Positioned(
            left: 8,
            right: 100,
            bottom: 20,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '@$displayName',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  widget.video.description ?? '',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 10),
                // Music Info
                Row(
                  children: [
                    const Icon(
                      FontAwesomeIcons.music,
                      color: Colors.white,
                      size: 12,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Original Sound - $displayName',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
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

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    double iconSize = 35,
  }) {
    return Column(
      children: [
        Icon(
          icon,
          color: Colors.white,
          size: iconSize,
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildCircleButton({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(1),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white,
          width: 1.5,
        ),
      ),
      child: child,
    );
  }
}
