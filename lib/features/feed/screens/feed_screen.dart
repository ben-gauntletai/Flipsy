import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../../../services/video_service.dart';
import '../../../services/user_service.dart';
import '../../../models/video.dart';
import 'dart:async';
import '../../../widgets/user_avatar.dart';
import '../../../features/profile/screens/profile_screen.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

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
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _hasMoreVideos = true;
  DocumentSnapshot? _lastDocument;
  StreamSubscription<List<Video>>? _videoSubscription;
  final List<VideoPlayerController> _videoControllers = [];
  String? _error;
  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    print('FeedScreen: Initializing');
    WidgetsBinding.instance.addObserver(this);
    _pageController = PageController();
    _loadVideos();
    _pageController.addListener(_onPageChanged);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disposeControllers();
    _pageController.removeListener(_onPageChanged);
    _pageController.dispose();
    _videoSubscription?.cancel();
    super.dispose();
  }

  void _onPageChanged() {
    if (_pageController.hasClients) {
      final newPage = _pageController.page?.round() ?? 0;
      if (newPage != _currentPage) {
        setState(() {
          _currentPage = newPage;
          print('FeedScreen: Page changed to $_currentPage');
        });
      }

      // Load more videos when user reaches the last 2 videos
      if (newPage >= _videos.length - 2 && !_isLoadingMore && _hasMoreVideos) {
        _loadMoreVideos();
      }
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

  void _resumeCurrentVideo() {
    if (_videoControllers.isNotEmpty && _pageController.hasClients) {
      final currentPage = _pageController.page?.round() ?? 0;
      if (currentPage >= 0 && currentPage < _videoControllers.length) {
        _videoControllers[currentPage].play();
      }
    }
  }

  void _handleVisibilityChanged() {
    if (!widget.isVisible) {
      _pauseAllVideos();
    } else {
      _resumeCurrentVideo();
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
    print('FeedScreen: Starting to load videos');
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      await _videoSubscription?.cancel();
      print('FeedScreen: Cancelled existing subscription');

      _videoSubscription =
          _videoService.getVideoFeed(limit: 5).listen((videos) async {
        print('FeedScreen: Received ${videos.length} videos from stream');

        if (videos.isNotEmpty) {
          _lastDocument = await _videoService.getLastDocument(videos.last.id);
          print('FeedScreen: Got last document for pagination');
        }

        await _loadUserData(videos);
        print('FeedScreen: Loaded user data for videos');

        if (mounted) {
          setState(() {
            _videos = videos;
            _isLoading = false;
            _hasMoreVideos = videos.length == 5;
            print('FeedScreen: Updated state with ${_videos.length} videos');
          });
        }
      }, onError: (error) {
        print('FeedScreen: Error loading videos: $error');
        if (mounted) {
          setState(() {
            _isLoading = false;
            _error = 'Error loading videos: $error';
          });
        }
      });
    } catch (e) {
      print('FeedScreen: Error setting up video stream: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = 'Error loading videos: $e';
        });
      }
    }
  }

  Future<void> _loadMoreVideos() async {
    if (_isLoadingMore || !_hasMoreVideos || _lastDocument == null) return;

    setState(() {
      _isLoadingMore = true;
    });

    try {
      final newVideos = await _videoService.getVideoFeedBatch(
        limit: 5,
        startAfter: _lastDocument,
      );

      if (newVideos.isNotEmpty) {
        _lastDocument = await _videoService.getLastDocument(newVideos.last.id);

        // Pre-fetch user data for new videos
        await _loadUserData(newVideos);

        if (mounted) {
          setState(() {
            _videos.addAll(newVideos);
            _isLoadingMore = false;
            _hasMoreVideos = newVideos.length == 5;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _isLoadingMore = false;
            _hasMoreVideos = false;
          });
        }
      }
    } catch (e) {
      print('Error loading more videos: $e');
      if (mounted) {
        setState(() {
          _isLoadingMore = false;
          _error = 'Error loading more videos';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    print(
        'FeedScreen: Building with isLoading: $_isLoading, videos: ${_videos.length}, currentPage: $_currentPage');
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (_isLoading && _videos.isEmpty)
            const Center(
              child: CircularProgressIndicator(
                color: Colors.white,
              ),
            )
          else if (_videos.isEmpty && !_isLoading)
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    'No videos available',
                    style: TextStyle(color: Colors.white),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _error!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                  TextButton(
                    onPressed: _loadVideos,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            )
          else
            PageView.builder(
              controller: _pageController,
              scrollDirection: Axis.vertical,
              itemCount: _videos.length + (_hasMoreVideos ? 1 : 0),
              itemBuilder: (context, index) {
                if (index >= _videos.length) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(20),
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                  );
                }
                final video = _videos[index];
                final userData = _usersData[video.userId];
                print(
                    'FeedScreen: Building video item at index $index, currentPage: $_currentPage');
                return VideoFeedItem(
                  key: ValueKey(video.id),
                  video: video,
                  userData: userData,
                  isVisible: widget.isVisible && index == _currentPage,
                  index: index,
                  currentPage: _currentPage,
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
  final int index;
  final int currentPage;

  const VideoFeedItem({
    Key? key,
    required this.video,
    this.userData,
    this.isVisible = true,
    required this.index,
    required this.currentPage,
  }) : super(key: key);

  @override
  State<VideoFeedItem> createState() => _VideoFeedItemState();
}

class _VideoFeedItemState extends State<VideoFeedItem> {
  late VideoPlayerController _videoController;
  bool _isPlaying = false;
  bool _isMuted = false;
  bool _showMuteIcon = false;
  bool _isInitialized = false;
  bool _hasError = false;
  String? _errorMessage;
  _FeedScreenState? _feedScreenState;
  DateTime? _tapDownTime;

  @override
  void initState() {
    super.initState();
    print(
        'VideoFeedItem: Initializing video ${widget.video.id} at index ${widget.index}');
    _initializeVideo();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final feedState = context.findAncestorStateOfType<_FeedScreenState>();
    if (feedState != null && feedState != _feedScreenState) {
      _feedScreenState = feedState;
      _feedScreenState!._videoControllers.add(_videoController);
      print(
          'VideoFeedItem: Added controller to feed state for ${widget.video.id}');
    }
    _checkAndUpdatePlaybackState();
  }

  void _checkAndUpdatePlaybackState() {
    if (!mounted || !_isInitialized) {
      print(
          'VideoFeedItem: Skipping playback check - mounted: $mounted, initialized: $_isInitialized');
      return;
    }

    final shouldPlay = widget.isVisible && widget.index == widget.currentPage;
    print(
        'VideoFeedItem: Checking playback state for ${widget.video.id} - shouldPlay: $shouldPlay, isPlaying: $_isPlaying, index: ${widget.index}, currentPage: ${widget.currentPage}');

    if (shouldPlay && !_isPlaying) {
      print('VideoFeedItem: Starting playback for ${widget.video.id}');
      _videoController.play();
      _videoController.setLooping(true);
      _isPlaying = true;
    } else if (!shouldPlay && _isPlaying) {
      print('VideoFeedItem: Pausing playback for ${widget.video.id}');
      _videoController.pause();
      _isPlaying = false;
    }
  }

  Future<void> _initializeVideo() async {
    try {
      print('VideoFeedItem: Creating controller for ${widget.video.videoURL}');
      _videoController = VideoPlayerController.network(widget.video.videoURL);

      await _videoController.initialize();
      print('VideoFeedItem: Controller initialized for ${widget.video.id}');

      if (mounted) {
        setState(() {
          _isInitialized = true;
        });
        _checkAndUpdatePlaybackState();
      }
    } catch (e) {
      print('VideoFeedItem: Error initializing video ${widget.video.id}: $e');
      if (mounted) {
        setState(() {
          _hasError = true;
          _errorMessage = 'Error loading video: $e';
        });
      }
    }
  }

  @override
  void didUpdateWidget(VideoFeedItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    print(
        'VideoFeedItem: Widget updated for ${widget.video.id} - visible: ${widget.isVisible}, index: ${widget.index}, currentPage: ${widget.currentPage}');

    if (oldWidget.isVisible != widget.isVisible ||
        oldWidget.currentPage != widget.currentPage) {
      _checkAndUpdatePlaybackState();
    }
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

  void _toggleMute() {
    setState(() {
      _isMuted = !_isMuted;
      _showMuteIcon = true;
      _videoController.setVolume(_isMuted ? 0 : 1);
    });

    // Hide the mute icon after 1 second
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) {
        setState(() {
          _showMuteIcon = false;
        });
      }
    });
  }

  @override
  void dispose() {
    if (mounted && _feedScreenState != null) {
      // Safely remove controller from parent's list
      _feedScreenState!._videoControllers.remove(_videoController);
    }
    _videoController.pause(); // Ensure video is paused before disposal
    _videoController.dispose();
    super.dispose();
  }

  // Profile Picture Navigation
  void _navigateToProfile(BuildContext context) {
    // Pause video before navigating
    _videoController.pause();
    _isPlaying = false;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ProfileScreen(
          userId: widget.video.userId,
        ),
      ),
    ).then((_) {
      // Resume video if the feed is still visible when returning
      if (widget.isVisible && mounted) {
        _videoController.play();
        _isPlaying = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final String displayName =
        widget.userData?['displayName'] ?? widget.video.userId;
    final String? avatarURL = widget.userData?['avatarURL'];

    return GestureDetector(
      onTapDown: (details) {
        if (widget.isVisible && _isInitialized) {
          _tapDownTime = DateTime.now();
        }
      },
      onTapUp: (details) {
        if (widget.isVisible && _tapDownTime != null) {
          final tapDuration = DateTime.now().difference(_tapDownTime!);
          if (tapDuration.inMilliseconds < 200) {
            // Short tap - toggle mute
            _toggleMute();
          }
          _tapDownTime = null;
        }
      },
      onLongPressDown: (details) {
        if (widget.isVisible) {
          _videoController.pause();
        }
      },
      onLongPressUp: () {
        if (widget.isVisible) {
          _videoController.play();
        }
      },
      onLongPressCancel: () {
        if (widget.isVisible) {
          _videoController.play();
        }
      },
      behavior: HitTestBehavior.opaque,
      child: Stack(
        children: [
          SizedBox.expand(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: _videoController.value.size?.width ?? 0,
                height: _videoController.value.size?.height ?? 0,
                child: _hasError
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.error, color: Colors.white),
                            Text(
                              _errorMessage ?? 'Error loading video',
                              style: const TextStyle(color: Colors.white),
                            ),
                          ],
                        ),
                      )
                    : VideoPlayer(_videoController),
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

          // Mute Icon Overlay
          if (_showMuteIcon)
            Center(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(50),
                ),
                child: Icon(
                  _isMuted ? Icons.volume_off : Icons.volume_up,
                  color: Colors.white,
                  size: 30,
                ),
              ),
            ),

          // Right Side Action Buttons
          Positioned(
            right: 8,
            bottom: 20,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Profile Picture
                _buildCircleButton(
                  child: GestureDetector(
                    onTap: () => _navigateToProfile(context),
                    child: UserAvatar(
                      avatarURL: avatarURL,
                      radius: 20,
                    ),
                  ),
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
                GestureDetector(
                  onTap: () {
                    // Add your more options logic here
                  },
                  child: const SizedBox(
                    width: 45,
                    height: 45,
                    child: Icon(
                      Icons.more_horiz,
                      color: Colors.white,
                      size: 20,
                    ),
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
