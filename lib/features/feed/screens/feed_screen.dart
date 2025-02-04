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

class VideoControllerManager {
  final Map<int, VideoPlayerController> _controllers = {};
  final Map<int, Completer<void>> _initializationCompleters = {};
  final Map<int, bool> _initializationStarted = {};
  final int preloadForward;
  final int keepPrevious;
  int _currentIndex = -1; // Initialize to -1 to ensure first update runs

  VideoControllerManager({
    this.preloadForward = 1,
    this.keepPrevious = 1,
  });

  bool shouldBeLoaded(int index) {
    return index >= _currentIndex - keepPrevious &&
        index <= _currentIndex + preloadForward;
  }

  Future<void> updateCurrentIndex(int newIndex, List<Video> videos) async {
    print(
        'VideoControllerManager: Updating current index to $newIndex with ${videos.length} videos');

    // Always initialize if no controller exists for this index
    if (!_controllers.containsKey(newIndex)) {
      print(
          'VideoControllerManager: No controller exists for index $newIndex, initializing');
      try {
        print(
            'VideoControllerManager: Starting initialization for index $newIndex');
        await _initializeController(newIndex, videos[newIndex]);
        print(
            'VideoControllerManager: Successfully initialized controller for index $newIndex');
      } catch (e, stackTrace) {
        print(
            'VideoControllerManager: Failed to initialize controller for index $newIndex');
        print('Error: $e');
        print('Stack trace: $stackTrace');
        rethrow;
      }
    }

    // Update current index after successful initialization
    _currentIndex = newIndex;

    // Initialize other videos in the window in the background
    for (int i = newIndex - keepPrevious; i <= newIndex + preloadForward; i++) {
      if (i >= 0 && i < videos.length && i != newIndex) {
        _initializeController(i, videos[i]).catchError((e, stackTrace) {
          print(
              'VideoControllerManager: Failed to initialize controller for index $i');
          print('Error: $e');
          print('Stack trace: $stackTrace');
        });
      }
    }

    // Clean up controllers outside the window
    _controllers.keys.toList().forEach((index) {
      if (!shouldBeLoaded(index)) {
        _disposeController(index);
      }
    });
  }

  Future<void> _initializeController(int index, Video video) async {
    print(
        'VideoControllerManager: Entering _initializeController for index $index');
    print('VideoControllerManager: Video URL: ${video.videoURL}');

    if (_controllers.containsKey(index)) {
      print(
          'VideoControllerManager: Controller already exists for index $index');
      return;
    }

    if (_initializationStarted[index] == true) {
      print(
          'VideoControllerManager: Initialization already started for index $index');
      if (_initializationCompleters.containsKey(index)) {
        print(
            'VideoControllerManager: Waiting for existing initialization to complete');
        await _initializationCompleters[index]!.future;
        return;
      }
    }

    print('VideoControllerManager: Creating new controller for index $index');
    _initializationStarted[index] = true;
    _initializationCompleters[index] = Completer<void>();

    VideoPlayerController? controller;
    try {
      print(
          'VideoControllerManager: Creating VideoPlayerController for ${video.videoURL}');
      controller = VideoPlayerController.network(
        video.videoURL,
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );

      print(
          'VideoControllerManager: Created controller, starting initialization');
      _controllers[index] = controller;

      print('VideoControllerManager: Calling initialize() on controller');
      await controller.initialize();
      print(
          'VideoControllerManager: Controller initialization completed successfully');

      if (!_initializationCompleters[index]!.isCompleted) {
        _initializationCompleters[index]?.complete();
        print(
            'VideoControllerManager: Initialization completer completed successfully');
      }
    } catch (e, stackTrace) {
      print(
          'VideoControllerManager: Error initializing controller for index $index');
      print('Error: $e');
      print('Stack trace: $stackTrace');

      // Cleanup on error
      if (controller != null) {
        print('VideoControllerManager: Disposing failed controller');
        await controller.dispose();
      }

      _cleanupController(index);

      if (_initializationCompleters.containsKey(index) &&
          !_initializationCompleters[index]!.isCompleted) {
        _initializationCompleters[index]?.completeError(e);
      }
      rethrow;
    }
  }

  Future<VideoPlayerController?> getController(int index) async {
    print('VideoControllerManager: Getting controller for index $index');
    print(
        'VideoControllerManager: Available controllers: ${_controllers.keys.toList()}');
    print(
        'VideoControllerManager: Initialization started for indices: ${_initializationStarted.keys.toList()}');

    if (!_controllers.containsKey(index)) {
      print('VideoControllerManager: No controller exists for index $index');
      return null;
    }

    try {
      if (_initializationCompleters.containsKey(index)) {
        print(
            'VideoControllerManager: Waiting for initialization to complete for index $index');
        await _initializationCompleters[index]!.future;
      }

      final controller = _controllers[index];
      if (controller != null) {
        print(
            'VideoControllerManager: Returning initialized controller for index $index');
        if (controller.value.isInitialized) {
          print('VideoControllerManager: Controller is properly initialized');
        } else {
          print(
              'VideoControllerManager: Warning - Controller exists but is not initialized');
        }
      } else {
        print('VideoControllerManager: Controller is null for index $index');
      }
      return controller;
    } catch (e, stackTrace) {
      print(
          'VideoControllerManager: Error getting controller for index $index');
      print('Error: $e');
      print('Stack trace: $stackTrace');
      return null;
    }
  }

  void _cleanupController(int index) {
    print('VideoControllerManager: Cleaning up controller for index $index');
    _controllers[index]?.dispose();
    _controllers.remove(index);
    _initializationCompleters.remove(index);
    _initializationStarted.remove(index);
  }

  void _disposeController(int index) {
    print('VideoControllerManager: Disposing controller for index $index');
    _cleanupController(index);
  }

  void disposeAll() {
    print('VideoControllerManager: Disposing all controllers');
    for (var controller in _controllers.values) {
      controller.dispose();
    }
    _controllers.clear();
    _initializationCompleters.clear();
    _initializationStarted.clear();
  }

  void pauseAllExcept(int index) {
    _controllers.forEach((idx, controller) {
      if (idx != index && controller.value.isPlaying) {
        print('VideoControllerManager: Pausing video at index $idx');
        controller.pause();
      }
    });
  }
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
  late VideoControllerManager _controllerManager;
  String? _error;
  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    print('FeedScreen: Initializing');
    WidgetsBinding.instance.addObserver(this);
    _pageController = PageController();
    _controllerManager = VideoControllerManager();
    _loadVideos();
    _pageController.addListener(_onPageChanged);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controllerManager.disposeAll();
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

        // Update controller manager with new index and handle playback
        _controllerManager.updateCurrentIndex(newPage, _videos).then((_) async {
          // Ensure the current video plays and others are paused
          final currentController =
              await _controllerManager.getController(newPage);
          if (currentController != null) {
            print('FeedScreen: Playing video at index $newPage');
            currentController.play();
            currentController.setLooping(true);
          }
          _controllerManager.pauseAllExcept(newPage);
        });

        // Load more videos when user reaches the last 2 videos
        if (newPage >= _videos.length - 2 &&
            !_isLoadingMore &&
            _hasMoreVideos) {
          _loadMoreVideos();
        }
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused) {
      _controllerManager.pauseAllExcept(-1); // Pause all videos
    } else if (state == AppLifecycleState.resumed && mounted) {
      // Resume playback of current video when app is resumed
      final currentController =
          _controllerManager.getController(_currentPage).then((controller) {
        if (controller != null && widget.isVisible) {
          print(
              'FeedScreen: Resuming video at index $_currentPage after app resume');
          controller.play();
          controller.setLooping(true);
        }
      });
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

          // Pre-initialize controllers for the first few videos
          if (videos.isNotEmpty) {
            try {
              print('FeedScreen: Starting controller initialization');
              await _controllerManager.updateCurrentIndex(0, videos);
              print(
                  'FeedScreen: Controller initialization completed successfully');
            } catch (e) {
              print('FeedScreen: Error initializing controllers: $e');
              if (mounted) {
                setState(() {
                  _error = 'Error initializing video: $e';
                });
              }
            }
          }
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
                  getController: _controllerManager.getController,
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
  final Future<VideoPlayerController?> Function(int index) getController;

  const VideoFeedItem({
    Key? key,
    required this.video,
    this.userData,
    this.isVisible = true,
    required this.index,
    required this.currentPage,
    required this.getController,
  }) : super(key: key);

  @override
  State<VideoFeedItem> createState() => _VideoFeedItemState();
}

class _VideoFeedItemState extends State<VideoFeedItem> {
  VideoPlayerController? _videoController;
  bool _isPlaying = false;
  bool _isMuted = false;
  bool _showMuteIcon = false;
  bool _isInitialized = false;
  bool _hasError = false;
  String? _errorMessage;
  DateTime? _tapDownTime;
  bool _isLoading = true;
  Timer? _initializationRetryTimer;
  int _initializationAttempts = 0;
  static const int maxInitializationAttempts = 3;

  @override
  void initState() {
    super.initState();
    print(
        'VideoFeedItem: Initializing video ${widget.video.id} at index ${widget.index}');
    _initializeController();
  }

  Future<void> _initializeController() async {
    if (!mounted) return;

    if (_initializationAttempts >= maxInitializationAttempts) {
      print(
          'VideoFeedItem: Max initialization attempts reached for ${widget.video.id}');
      setState(() {
        _hasError = true;
        _errorMessage = 'Failed to load video after multiple attempts';
        _isLoading = false;
      });
      return;
    }

    _initializationAttempts++;
    print(
        'VideoFeedItem: Attempt $_initializationAttempts to initialize ${widget.video.id}');

    setState(() {
      _isLoading = true;
      _hasError = false;
      _errorMessage = null;
    });

    try {
      final controller = await widget.getController(widget.index);
      if (!mounted) return;

      if (controller == null) {
        print(
            'VideoFeedItem: Controller is null for ${widget.video.id}, retrying in 1 second');
        _scheduleRetry();
        return;
      }

      setState(() {
        _videoController = controller;
        _isInitialized = controller.value.isInitialized;
        _isLoading = false;
        print('VideoFeedItem: Successfully initialized ${widget.video.id}');
      });

      if (_isInitialized) {
        _checkAndUpdatePlaybackState();
      } else {
        print(
            'VideoFeedItem: Controller not initialized for ${widget.video.id}, retrying in 1 second');
        _scheduleRetry();
      }
    } catch (e) {
      print(
          'VideoFeedItem: Error initializing controller for ${widget.video.id}: $e');
      if (!mounted) return;

      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    _initializationRetryTimer?.cancel();
    _initializationRetryTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) {
        _initializeController();
      }
    });
  }

  @override
  void dispose() {
    _initializationRetryTimer?.cancel();
    super.dispose();
  }

  void _checkAndUpdatePlaybackState() {
    if (!mounted || !_isInitialized || _videoController == null) {
      print(
          'VideoFeedItem: Skipping playback check - mounted: $mounted, initialized: $_isInitialized, controller: ${_videoController != null}');
      return;
    }

    final shouldPlay = widget.isVisible && widget.index == widget.currentPage;
    print(
        'VideoFeedItem: Checking playback state for ${widget.video.id} - shouldPlay: $shouldPlay, isPlaying: $_isPlaying');

    if (shouldPlay && !_isPlaying) {
      print('VideoFeedItem: Starting playback for ${widget.video.id}');
      _videoController!.play();
      _videoController!.setLooping(true);
      _isPlaying = true;
    } else if (!shouldPlay && _isPlaying) {
      print('VideoFeedItem: Pausing playback for ${widget.video.id}');
      _videoController!.pause();
      _isPlaying = false;
    }
  }

  void _togglePlay() {
    if (_videoController == null) return;

    setState(() {
      _isPlaying = !_isPlaying;
      if (_isPlaying) {
        _videoController!.play();
      } else {
        _videoController!.pause();
      }
    });
  }

  void _toggleMute() {
    if (_videoController == null) return;

    setState(() {
      _isMuted = !_isMuted;
      _showMuteIcon = true;
      _videoController!.setVolume(_isMuted ? 0 : 1);
    });

    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) {
        setState(() {
          _showMuteIcon = false;
        });
      }
    });
  }

  // Profile Picture Navigation
  void _navigateToProfile(BuildContext context) {
    // Pause video before navigating
    _videoController?.pause();
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
        _videoController?.play();
        _isPlaying = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(
          color: Colors.white,
        ),
      );
    }

    if (_hasError) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error, color: Colors.white),
            Text(
              _errorMessage ?? 'Error loading video',
              style: const TextStyle(color: Colors.white),
            ),
            TextButton(
              onPressed: _initializeController,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (_videoController == null || !_isInitialized) {
      return const Center(
        child: CircularProgressIndicator(
          color: Colors.white,
        ),
      );
    }

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
            _toggleMute();
          }
          _tapDownTime = null;
        }
      },
      onLongPressDown: (details) {
        if (widget.isVisible && _videoController != null) {
          _videoController!.pause();
        }
      },
      onLongPressUp: () {
        if (widget.isVisible && _videoController != null) {
          _videoController!.play();
        }
      },
      onLongPressCancel: () {
        if (widget.isVisible && _videoController != null) {
          _videoController!.play();
        }
      },
      behavior: HitTestBehavior.opaque,
      child: Stack(
        children: [
          SizedBox.expand(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: _videoController?.value.size?.width ?? 0,
                height: _videoController?.value.size?.height ?? 0,
                child: VideoPlayer(_videoController!),
              ),
            ),
          ),

          // Play/Pause Overlay
          if (!_videoController!.value.isInitialized)
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
