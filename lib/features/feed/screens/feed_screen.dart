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
import 'dart:collection';
import 'dart:math' as math;
import '../../../features/video/screens/video_upload_screen.dart';
import '../widgets/comment_bottom_sheet.dart';
import '../../../services/comment_service.dart';
import '../../../features/auth/bloc/auth_bloc.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../features/navigation/screens/main_navigation_screen.dart';
import '../../../services/video_cache_service.dart';
import 'dart:io';

class FeedScreen extends StatefulWidget {
  final bool isVisible;
  final String? initialVideoId;
  final bool showBackButton;
  final VoidCallback? onBack;

  const FeedScreen({
    super.key,
    this.isVisible = true,
    this.initialVideoId,
    this.showBackButton = false,
    this.onBack,
  });

  @override
  State<FeedScreen> createState() => FeedScreenState();
}

class VideoControllerManager {
  final Map<int, VideoPlayerController> _controllers = {};
  final Map<int, String> _controllerUrls = {};
  final Map<int, Completer<void>> _initializationCompleters = {};
  final Map<int, bool> _initializationStarted = {};
  final Set<int> _disposingControllers = {};
  final VideoCacheService _cacheService = VideoCacheService();
  final int preloadForward;
  final int keepPrevious;
  int _currentIndex = -1;

  VideoControllerManager({
    this.preloadForward = 2,
    this.keepPrevious = 1,
  }) {
    _initializeCache();
  }

  Future<void> _initializeCache() async {
    try {
      debugPrint('VideoControllerManager: Initializing cache service');
      await _cacheService.ensureInitialized();
      debugPrint(
          'VideoControllerManager: Cache service initialized successfully');
    } catch (e) {
      debugPrint(
          'VideoControllerManager: Error initializing cache service: $e');
    }
  }

  bool shouldBeLoaded(int index) {
    return index >= _currentIndex - keepPrevious &&
        index <= _currentIndex + preloadForward;
  }

  Future<void> updateCurrentIndex(int newIndex, List<Video> videos) async {
    print(
        'VideoControllerManager: Updating current index to $newIndex with ${videos.length} videos');

    if (newIndex < 0 || newIndex >= videos.length) {
      print('VideoControllerManager: Invalid index $newIndex');
      return;
    }

    // Preload videos in the window
    final startIdx = math.max(0, newIndex - keepPrevious);
    final endIdx = math.min(videos.length - 1, newIndex + preloadForward);
    final videosToPreload =
        videos.sublist(startIdx, endIdx + 1).map((v) => v.videoURL).toList();
    _cacheService.preloadVideos(videosToPreload);

    // Initialize current index first
    try {
      print(
          'VideoControllerManager: Initializing controller for current index $newIndex');
      await _initializeController(newIndex, videos[newIndex]);
    } catch (e) {
      print(
          'VideoControllerManager: Failed to initialize controller for current index: $e');
    }

    // Update current index
    _currentIndex = newIndex;

    // Initialize controllers in the window
    for (int i = startIdx; i <= endIdx; i++) {
      if (i != newIndex && i >= 0 && i < videos.length) {
        try {
          await _initializeController(i, videos[i]);
        } catch (e) {
          print(
              'VideoControllerManager: Failed to initialize controller for index $i: $e');
        }
      }
    }

    // Clean up controllers outside the window
    final List<int> toDispose = [];
    for (final index in _controllers.keys) {
      if (!shouldBeLoaded(index)) {
        toDispose.add(index);
      }
    }

    // Dispose controllers sequentially to avoid race conditions
    for (final index in toDispose) {
      if (!_disposingControllers.contains(index)) {
        await _disposeController(index);
      }
    }
  }

  Future<void> _initializeController(int index, Video video) async {
    debugPrint(
        'VideoControllerManager: Entering _initializeController for index $index');
    debugPrint('VideoControllerManager: Video URL: ${video.videoURL}');

    if (_disposingControllers.contains(index)) {
      debugPrint(
          'VideoControllerManager: Controller $index is being disposed, skipping initialization');
      return;
    }

    // Check if we need to reinitialize due to URL change
    if (_controllers.containsKey(index)) {
      if (_controllerUrls[index] != video.videoURL) {
        debugPrint(
            'VideoControllerManager: URL changed for index $index, reinitializing');
        await _disposeController(index);
      } else if (_controllers[index]!.value.isInitialized) {
        debugPrint(
            'VideoControllerManager: Controller exists with same URL and is initialized');
        return;
      }
    }

    // If initialization is in progress, wait for it
    if (_initializationStarted[index] == true &&
        _initializationCompleters.containsKey(index)) {
      debugPrint(
          'VideoControllerManager: Waiting for existing initialization for index $index');
      try {
        await _initializationCompleters[index]!.future;
        if (_controllerUrls[index] == video.videoURL) {
          return;
        }
      } catch (e) {
        debugPrint(
            'VideoControllerManager: Previous initialization failed: $e');
      }
    }

    _initializationStarted[index] = true;
    _initializationCompleters[index] = Completer<void>();

    VideoPlayerController? controller;
    try {
      debugPrint(
          'VideoControllerManager: Attempting to get cached video for ${video.videoURL}');
      final cachedPath = await _cacheService.getCachedVideoPath(video.videoURL);

      if (cachedPath == null) {
        throw Exception('Failed to get cached video path');
      }

      debugPrint(
          'VideoControllerManager: Using cached video from: $cachedPath');
      controller = VideoPlayerController.file(
        File(cachedPath),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );

      _controllers[index] = controller;
      _controllerUrls[index] = video.videoURL;

      debugPrint('VideoControllerManager: Initializing controller');
      await controller.initialize();
      debugPrint('VideoControllerManager: Controller initialized successfully');

      if (_disposingControllers.contains(index)) {
        debugPrint(
            'VideoControllerManager: Controller was disposed during initialization');
        await controller.dispose();
        return;
      }

      if (!_initializationCompleters[index]!.isCompleted) {
        _initializationCompleters[index]?.complete();
      }
    } catch (e, stack) {
      debugPrint(
          'VideoControllerManager: Error initializing controller for index $index: $e');
      debugPrint('Stack trace: $stack');

      if (controller != null && !_disposingControllers.contains(index)) {
        await controller.dispose();
      }
      _controllers.remove(index);
      _controllerUrls.remove(index);

      if (_initializationCompleters[index]?.isCompleted == false) {
        _initializationCompleters[index]?.completeError(e);
      }

      rethrow;
    }
  }

  Future<VideoPlayerController?> getController(int index) async {
    print('VideoControllerManager: Getting controller for index $index');

    // Don't return a controller that's being disposed
    if (_disposingControllers.contains(index)) {
      print(
          'VideoControllerManager: Controller $index is being disposed, returning null');
      return null;
    }

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

      // Check again after waiting for initialization
      if (_disposingControllers.contains(index)) {
        print(
            'VideoControllerManager: Controller was disposed during initialization wait');
        return null;
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

  Future<void> _disposeController(int index) async {
    print('VideoControllerManager: Disposing controller for index $index');

    // Mark the controller as being disposed
    _disposingControllers.add(index);

    try {
      await _cleanupController(index);
    } finally {
      // Remove from disposing set after cleanup
      _disposingControllers.remove(index);
    }
  }

  Future<void> _cleanupController(int index) async {
    print('VideoControllerManager: Cleaning up controller for index $index');
    final controller = _controllers[index];
    if (controller != null) {
      try {
        await controller.dispose();
      } catch (e) {
        print('VideoControllerManager: Error disposing controller: $e');
      }
    }
    _controllers.remove(index);
    _controllerUrls.remove(index);
    _initializationCompleters.remove(index);
    _initializationStarted.remove(index);
  }

  Future<void> disposeAll() async {
    print('VideoControllerManager: Disposing all controllers');
    final indices = _controllers.keys.toList();
    for (final index in indices) {
      await _disposeController(index);
    }
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

class FeedScreenState extends State<FeedScreen> with WidgetsBindingObserver {
  late PageController _pageController;
  final VideoService _videoService = VideoService();
  final UserService _userService = UserService();
  final CommentService _commentService = CommentService();
  List<Video> _videos = [];
  final Map<String, Map<String, dynamic>> _usersData = {};
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _hasMoreVideos = true;
  DocumentSnapshot? _lastDocument;
  StreamSubscription<List<Video>>? _videoSubscription;
  late VideoControllerManager _controllerManager;
  String? _error;
  int _currentPage = 0;
  final Set<String> _processedVideoIds = {}; // Track processed video IDs
  String? _targetVideoId; // Add this property to track target video
  bool _hasInitializedControllers = false;
  bool _isFollowingFeed = false; // Track current feed type

  @override
  void initState() {
    super.initState();
    print('FeedScreen: Initializing');
    WidgetsBinding.instance.addObserver(this);
    _pageController = PageController();
    _controllerManager = VideoControllerManager();
    if (widget.initialVideoId != null) {
      _targetVideoId = widget.initialVideoId;
    }
    _loadVideos();
    _pageController.addListener(_onPageChanged);

    // Add post-frame callback to handle initialization
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeAfterBuild();
    });
  }

  Future<void> _initializeAfterBuild() async {
    if (_videos.isEmpty || _hasInitializedControllers) return;

    try {
      print('FeedScreen: Starting post-build initialization');
      await _controllerManager.updateCurrentIndex(_currentPage, _videos);
      print('FeedScreen: Post-build controller initialization completed');

      if (mounted) {
        setState(() {
          _hasInitializedControllers = true;
        });

        if (_targetVideoId != null) {
          final targetIndex = _videos.indexWhere((v) => v.id == _targetVideoId);
          if (targetIndex != -1) {
            print('FeedScreen: Jumping to target video at index $targetIndex');
            await Future.delayed(const Duration(milliseconds: 100));
            if (mounted) {
              _pageController.jumpToPage(targetIndex);
              _targetVideoId = null;
            }
          }
        }
      }
    } catch (e) {
      print('FeedScreen: Error in post-build initialization: $e');
      if (mounted) {
        setState(() {
          _error = 'Error initializing video: $e';
        });
      }
    }
  }

  Future<void> _initializeControllers() async {
    if (_videos.isNotEmpty && !_hasInitializedControllers) {
      try {
        print('FeedScreen: Starting initial controller initialization');
        await _controllerManager.updateCurrentIndex(_currentPage, _videos);
        print('FeedScreen: Controller initialization completed successfully');
        if (mounted) {
          setState(() {
            _hasInitializedControllers = true;
          });
        }
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controllerManager.disposeAll();
    _pageController.removeListener(_onPageChanged);
    _pageController.dispose();
    _videoSubscription?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(FeedScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    print('FeedScreen: Widget updated, isVisible: ${widget.isVisible}');

    if (!widget.isVisible) {
      // Pause all videos when feed is not visible
      _controllerManager.pauseAllExcept(-1);
    } else if (widget.isVisible && _currentPage >= 0) {
      // Resume current video if feed becomes visible
      _controllerManager.getController(_currentPage).then((controller) {
        if (controller != null && mounted) {
          print('FeedScreen: Resuming video at index $_currentPage');
          controller.play();
          controller.setLooping(true);
        }
      });
    }
  }

  void _onPageChanged() {
    if (!mounted || !widget.isVisible) return;

    final page = _pageController.page?.round() ?? 0;
    if (page != _currentPage) {
      setState(() => _currentPage = page);
      _controllerManager.updateCurrentIndex(page, _videos);

      // Only play the video if the feed is visible
      if (widget.isVisible) {
        _controllerManager.getController(page).then((controller) {
          if (controller != null) {
            controller.play();
            controller.setLooping(true);
          }
        });
      }
    }

    // Load more videos if we're near the end
    if (page >= _videos.length - 2) {
      _loadMoreVideos();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    print('FeedScreen: App lifecycle state changed to $state');

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _controllerManager.pauseAllExcept(-1); // Pause all videos
    } else if (state == AppLifecycleState.resumed && mounted) {
      // Only resume playback if the feed is visible
      if (widget.isVisible && _currentPage >= 0) {
        _controllerManager.getController(_currentPage).then((controller) {
          if (controller != null) {
            print(
                'FeedScreen: Resuming video at index $_currentPage after app resume');
            controller.play();
            controller.setLooping(true);
          }
        });
      }
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

  void jumpToVideo(String videoId) {
    print('FeedScreen: Attempting to jump to video $videoId');
    setState(() {
      _targetVideoId = videoId;
      _isLoading = true; // Show loading state while we prepare the video
    });

    // Find the index of the video
    final index = _videos.indexWhere((v) => v.id == videoId);
    if (index != -1) {
      print('FeedScreen: Found video at index $index, preparing to jump');
      // Initialize the controller for this specific video first
      _controllerManager.updateCurrentIndex(index, _videos).then((_) async {
        if (mounted) {
          // Get the controller to ensure it's ready
          final controller = await _controllerManager.getController(index);
          if (controller != null && controller.value.isInitialized) {
            print('FeedScreen: Controller ready for playback');
            setState(() {
              _isLoading = false;
              _currentPage = index;
            });

            // Schedule the jump for the next frame to ensure PageView is ready
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _pageController.hasClients) {
                print('FeedScreen: Executing jump to page $index');
                _pageController.jumpToPage(index);

                // Ensure video starts playing
                controller.play();
                controller.setLooping(true);
              }
            });
          } else {
            print('FeedScreen: Controller not ready, retrying initialization');
            // If controller isn't ready, retry initialization
            await _initializeControllers();
          }
        }
      });
    } else {
      print('FeedScreen: Video not found in current list, reloading feed');
      // Reset the feed and load videos again
      setState(() {
        _lastDocument = null;
        _hasMoreVideos = true;
        _videos.clear();
        _processedVideoIds.clear();
        _controllerManager.disposeAll();
        _hasInitializedControllers = false;
      });
      _loadVideos();
    }
  }

  Future<void> _loadVideos() async {
    print('FeedScreen: Starting to load videos');
    setState(() {
      _isLoading = true;
      _error = null;
      _processedVideoIds.clear();
      _videos.clear();
    });

    try {
      await _videoSubscription?.cancel();
      print('FeedScreen: Cancelled existing subscription');

      // If we have a target video, load it first
      if (_targetVideoId != null) {
        try {
          print('FeedScreen: Attempting to load target video: $_targetVideoId');
          final targetVideo = await _videoService.getVideoById(_targetVideoId!);
          if (targetVideo != null) {
            print('FeedScreen: Successfully loaded target video');
            _videos.add(targetVideo);
            _processedVideoIds.add(targetVideo.id);
            await _loadUserData([targetVideo]);
          }
        } catch (e) {
          print('FeedScreen: Error loading target video: $e');
        }
      }

      final stream = _isFollowingFeed
          ? _videoService.getFollowingFeed(limit: 5)
          : _videoService.getVideoFeed(limit: 5);

      _videoSubscription = stream.listen((videos) async {
        print('FeedScreen: Received ${videos.length} videos from stream');

        if (videos.isNotEmpty) {
          _lastDocument = await _videoService.getLastDocument(videos.last.id);
          print('FeedScreen: Got last document for pagination');
        }

        // Process new videos
        final List<Video> newVideos = [];
        final Set<String> newVideoIds = {};

        for (final video in videos) {
          if (!_processedVideoIds.contains(video.id)) {
            newVideos.add(video);
            newVideoIds.add(video.id);
          }
        }

        if (newVideos.isNotEmpty) {
          await _loadUserData(newVideos);
          print('FeedScreen: Loaded user data for new videos');
        }

        if (mounted) {
          setState(() {
            // Update the processed IDs set
            _processedVideoIds.addAll(newVideoIds);

            // Merge new videos with existing ones, maintaining order
            final Map<String, Video> mergedVideos = {};

            // Add existing videos first
            for (final video in _videos) {
              mergedVideos[video.id] = video;
            }

            // Add or update with new videos
            for (final video in videos) {
              mergedVideos[video.id] = video;
            }

            // Convert back to list and sort by createdAt
            _videos = mergedVideos.values.toList()
              ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

            _isLoading = false;
            _hasMoreVideos = videos.length == 5;
          });

          // Initialize controllers
          await _initializeControllers();

          // If we have a target video, jump to it
          if (_targetVideoId != null) {
            final targetIndex =
                _videos.indexWhere((v) => v.id == _targetVideoId);
            if (targetIndex != -1) {
              print(
                  'FeedScreen: Found target video at index $targetIndex, jumping to it');
              _pageController.jumpToPage(targetIndex);
              _targetVideoId = null;
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
      final newVideos = _isFollowingFeed
          ? await _videoService.getFollowingFeedBatch(
              limit: 5,
              startAfter: _lastDocument,
            )
          : await _videoService.getVideoFeedBatch(
              limit: 5,
              startAfter: _lastDocument,
            );

      if (newVideos.isNotEmpty) {
        _lastDocument = await _videoService.getLastDocument(newVideos.last.id);

        // Filter out already processed videos
        final List<Video> uniqueNewVideos = newVideos
            .where((video) => !_processedVideoIds.contains(video.id))
            .toList();

        if (uniqueNewVideos.isNotEmpty) {
          await _loadUserData(uniqueNewVideos);

          if (mounted) {
            setState(() {
              _processedVideoIds.addAll(uniqueNewVideos.map((v) => v.id));
              _videos.addAll(uniqueNewVideos);
              _videos.sort((a, b) => b.createdAt.compareTo(a.createdAt));
              _isLoadingMore = false;
              _hasMoreVideos = newVideos.length == 5;
            });
          }
        }
      }
    } catch (e) {
      print('FeedScreen: Error loading more videos: $e');
      if (mounted) {
        setState(() {
          _isLoadingMore = false;
          _error = 'Error loading more videos: $e';
        });
      }
    }
  }

  void _switchFeed(bool isFollowing) {
    if (_isFollowingFeed == isFollowing) return;

    setState(() {
      _isFollowingFeed = isFollowing;
      _currentPage = 0;
      _lastDocument = null;
      _hasMoreVideos = true;
      _controllerManager.disposeAll();
      _hasInitializedControllers = false;
    });

    _loadVideos();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          if (_isLoading)
            const Center(
              child: CircularProgressIndicator(),
            )
          else if (_error != null)
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, size: 48),
                  const SizedBox(height: 16),
                  Text(_error!),
                  TextButton(
                    onPressed: _loadVideos,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            )
          else if (_videos.isEmpty)
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.videocam_off, size: 48),
                  const SizedBox(height: 16),
                  Text(
                    _isFollowingFeed
                        ? 'No videos from followed users'
                        : 'No videos available',
                  ),
                ],
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
                      GestureDetector(
                        onTap: () => _switchFeed(true),
                        child: Text(
                          'Following',
                          style: TextStyle(
                            color: _isFollowingFeed
                                ? Colors.white
                                : Colors.white60,
                            fontSize: 15,
                            fontWeight: _isFollowingFeed
                                ? FontWeight.bold
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(width: 20),
                      GestureDetector(
                        onTap: () => _switchFeed(false),
                        child: Text(
                          'For You',
                          style: TextStyle(
                            color: !_isFollowingFeed
                                ? Colors.white
                                : Colors.white60,
                            fontSize: 15,
                            fontWeight: !_isFollowingFeed
                                ? FontWeight.bold
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          if (widget.showBackButton)
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              left: 8,
              child: IconButton(
                icon: const Icon(
                  Icons.arrow_back,
                  color: Colors.white,
                ),
                onPressed: widget.onBack,
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
    super.key,
    required this.video,
    this.userData,
    this.isVisible = true,
    required this.index,
    required this.currentPage,
    required this.getController,
  });

  @override
  State<VideoFeedItem> createState() => _VideoFeedItemState();
}

class _VideoFeedItemState extends State<VideoFeedItem>
    with SingleTickerProviderStateMixin {
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

  // Like animation controller
  late AnimationController _likeAnimationController;
  bool _isLiked = false;
  final bool _isLiking = false;
  bool _showLikeAnimation = false;
  final VideoService _videoService = VideoService();
  StreamSubscription<bool>? _likeStatusSubscription;
  StreamSubscription<int>? _commentCountSubscription;
  StreamSubscription<int>? _likeCountSubscription;
  int _commentCount = 0;

  DateTime? _lastTapTime;
  Timer? _doubleTapTimer;
  final bool _isHandlingDoubleTap = false;
  bool _isLongPressing = false;

  // Queue system for like actions
  final Queue<_LikeAction> _likeActionQueue = Queue<_LikeAction>();
  bool _isProcessingQueue = false;

  // Track local state with timestamps
  int _localLikesCount = 0;
  bool _localLikeState = false;
  DateTime? _lastLikeActionTime;
  bool _isLikeActionPending = false;

  final CommentService _commentService = CommentService();

  // Add new state variables for bookmark
  bool _localBookmarkState = false;
  int _bookmarkCount = 0;
  StreamSubscription<bool>? _bookmarkStatusSubscription;
  StreamSubscription<int>? _bookmarkCountSubscription;

  @override
  void initState() {
    super.initState();
    print(
        'VideoFeedItem: Initializing video ${widget.video.id} at index ${widget.index}');

    // Initialize like animation controller
    _likeAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    // Initialize video controller
    _initializeController();

    // Initialize like status and count
    _localLikesCount = widget.video.likesCount;
    _initializeLikeStatus();
    _initializeLikeCount();

    // Initialize comment count
    _commentCount = widget.video.commentsCount;
    _commentCountSubscription =
        _commentService.watchCommentCount(widget.video.id).listen((count) {
      if (mounted) {
        setState(() {
          _commentCount = count;
          print(
              'VideoFeedItem: Updated comment count to $_commentCount for video ${widget.video.id}');
        });
      }
    }, onError: (error) {
      print('VideoFeedItem: Error watching comment count: $error');
    });

    // Initialize bookmark status and count
    _initializeBookmarkStatus();
    _initializeBookmarkCount();
  }

  void _initializeLikeStatus() {
    _likeStatusSubscription =
        _videoService.watchUserLikeStatus(widget.video.id).listen((isLiked) {
      if (mounted) {
        final now = DateTime.now();
        final timeSinceLastAction = _lastLikeActionTime != null
            ? now.difference(_lastLikeActionTime!)
            : null;

        // Only update if:
        // 1. We're not processing a queue
        // 2. It's been more than 2 seconds since our last action (to avoid race conditions)
        // 3. Or if we have no pending actions
        if (!_isProcessingQueue &&
            (!_isLikeActionPending ||
                (timeSinceLastAction != null &&
                    timeSinceLastAction.inSeconds > 2))) {
          setState(() {
            _isLiked = isLiked;
            _localLikeState = isLiked;
            _isLikeActionPending = false;
          });
        }
      }
    });
  }

  void _initializeLikeCount() {
    _likeCountSubscription =
        _videoService.watchVideoLikeCount(widget.video.id).listen((count) {
      if (mounted) {
        final now = DateTime.now();
        final timeSinceLastAction = _lastLikeActionTime != null
            ? now.difference(_lastLikeActionTime!)
            : null;

        // Update if:
        // 1. We're not processing a queue and have no pending actions, or
        // 2. It's been more than 2 seconds since our last action
        if (!_isProcessingQueue && !_isLikeActionPending ||
            (timeSinceLastAction != null &&
                timeSinceLastAction.inSeconds > 2)) {
          setState(() {
            _localLikesCount = count;
            print(
                'VideoFeedItem: Updated like count to $count for video ${widget.video.id}');
          });
        }
      }
    }, onError: (error) {
      print('VideoFeedItem: Error watching like count: $error');
    });
  }

  void _initializeBookmarkStatus() {
    _bookmarkStatusSubscription = _videoService
        .watchUserBookmarkStatus(widget.video.id)
        .listen((isBookmarked) {
      if (mounted) {
        setState(() {
          _localBookmarkState = isBookmarked;
        });
      }
    });
  }

  void _initializeBookmarkCount() {
    _bookmarkCountSubscription =
        _videoService.watchVideoBookmarkCount(widget.video.id).listen((count) {
      if (mounted) {
        setState(() {
          _bookmarkCount = count;
        });
      }
    });
  }

  Future<void> _handleLikeAction() async {
    if (_isLikeActionPending) {
      print('VideoFeedItem: Like action already pending, skipping');
      return;
    }

    final newLikeState = !_localLikeState;
    final action = _LikeAction(isLike: newLikeState);

    // Apply optimistic update
    setState(() {
      _localLikeState = newLikeState;
      _localLikesCount += newLikeState ? 1 : -1;
      _isLikeActionPending = true;
      _lastLikeActionTime = DateTime.now();
      _showHeartAnimation(isLike: newLikeState);
    });

    print(
        'VideoFeedItem: Applied optimistic update - new like count: $_localLikesCount');

    // Add to queue and process
    _likeActionQueue.add(action);

    // Start processing if not already processing
    if (!_isProcessingQueue) {
      await _processLikeActionQueue();
    }
  }

  Future<void> _processLikeActionQueue() async {
    if (_isProcessingQueue) return;

    _isProcessingQueue = true;
    print('VideoFeedItem: Starting to process like action queue');

    try {
      while (_likeActionQueue.isNotEmpty) {
        final action = _likeActionQueue.first;
        print(
            'VideoFeedItem: Processing like action: ${action.isLike ? 'like' : 'unlike'}');

        try {
          final success = action.isLike
              ? await _videoService.likeVideo(widget.video.id)
              : await _videoService.unlikeVideo(widget.video.id);

          if (!success && mounted) {
            print('VideoFeedItem: Action failed, reverting optimistic update');
            setState(() {
              _localLikesCount += action.isLike ? -1 : 1;
              _localLikeState = !action.isLike;
              _isLikeActionPending = false;
            });

            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Failed to update like status'),
                duration: Duration(seconds: 2),
              ),
            );
          } else {
            print('VideoFeedItem: Action completed successfully');
            if (mounted) {
              setState(() {
                _isLikeActionPending = false;
                // Force update the local state to match the action
                _localLikeState = action.isLike;
              });
            }
          }
        } catch (e) {
          print('VideoFeedItem: Error processing like action: $e');
          if (mounted) {
            setState(() {
              _localLikesCount += action.isLike ? -1 : 1;
              _localLikeState = !action.isLike;
              _isLikeActionPending = false;
            });

            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Error updating like status'),
                duration: Duration(seconds: 2),
              ),
            );
          }
        }

        // Remove the processed action
        if (_likeActionQueue.isNotEmpty) {
          _likeActionQueue.removeFirst();
        }
      }
    } finally {
      _isProcessingQueue = false;
      print('VideoFeedItem: Finished processing like action queue');
    }
  }

  void _showHeartAnimation({required bool isLike}) {
    setState(() {
      _showLikeAnimation = true;
    });
    _likeAnimationController.forward().then((_) {
      _likeAnimationController.reverse().then((_) {
        if (mounted) {
          setState(() {
            _showLikeAnimation = false;
          });
        }
      });
    });
  }

  Future<void> _handleBookmarkAction() async {
    try {
      final success = _localBookmarkState
          ? await _videoService.unbookmarkVideo(widget.video.id)
          : await _videoService.bookmarkVideo(widget.video.id);

      if (success && mounted) {
        setState(() {
          _localBookmarkState = !_localBookmarkState;
          _bookmarkCount += _localBookmarkState ? 1 : -1;
        });
      }
    } catch (e) {
      print('VideoFeedItem: Error updating bookmark status: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Error updating bookmark status'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    print('VideoFeedItem: Disposing video ${widget.video.id}');
    _commentCountSubscription?.cancel();
    _likeCountSubscription?.cancel();
    _doubleTapTimer?.cancel();
    _likeAnimationController.dispose();
    _likeStatusSubscription?.cancel();
    _initializationRetryTimer?.cancel();
    _bookmarkStatusSubscription?.cancel();
    _bookmarkCountSubscription?.cancel();
    super.dispose();
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
    if (_videoController != null && _isPlaying) {
      _videoController!.pause();
      _isPlaying = false;
    }

    MainNavigationScreen.showUserProfile(context, widget.video.userId);
  }

  void _handleTap() {
    if (_isLongPressing || _isHandlingDoubleTap) return;

    print('VideoFeedItem: Single tap detected');
    _toggleMute();
  }

  void _handleDoubleTap() {
    if (_isLongPressing) return;

    print(
        'VideoFeedItem: Double tap detected, current like status: $_localLikeState');
    _handleLikeAction();
  }

  void _handleLongPressStart(LongPressStartDetails details) {
    print('VideoFeedItem: Long press start detected');
    _isLongPressing = true;
    if (widget.isVisible && _videoController != null) {
      _videoController!.pause();
    }
  }

  void _handleLongPressEnd(LongPressEndDetails details) {
    print('VideoFeedItem: Long press end detected');
    if (widget.isVisible && _videoController != null) {
      _videoController!.play();
    }
    Future.delayed(const Duration(milliseconds: 200), () {
      _isLongPressing = false;
    });
  }

  void _showComments(BuildContext context) {
    // Pause video while comments are shown
    if (_videoController != null && _isPlaying) {
      _videoController!.pause();
      _isPlaying = false;
    }

    CommentBottomSheet.show(
      context,
      widget.video.id,
      widget.video.allowComments,
    ).then((_) {
      // Resume video when comments are closed
      if (widget.isVisible && mounted && _videoController != null) {
        _videoController!.play();
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
      onTap: _handleTap,
      onDoubleTap: _handleDoubleTap,
      onLongPressStart: _handleLongPressStart,
      onLongPressEnd: _handleLongPressEnd,
      onLongPressCancel: () {
        print('VideoFeedItem: Long press cancelled');
        _isLongPressing = false;
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
                width: _videoController?.value.size.width ?? 0,
                height: _videoController?.value.size.height ?? 0,
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

          // Heart Animation Overlay
          if (_showLikeAnimation)
            Center(
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.0, end: 1.0).animate(
                  CurvedAnimation(
                    parent: _likeAnimationController,
                    curve: Curves.elasticOut,
                  ),
                ),
                child: Icon(
                  Icons.favorite,
                  color: _localLikeState ? Colors.red : Colors.white,
                  size: 100,
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
                const SizedBox(height: 20),

                // Like Button with optimistic count
                _buildActionButton(
                  icon: _localLikeState
                      ? FontAwesomeIcons.solidHeart
                      : FontAwesomeIcons.heart,
                  label: _localLikesCount.toString(),
                  iconSize: 28,
                  color: _localLikeState ? Colors.red : Colors.white,
                  onTap: _handleLikeAction,
                ),
                const SizedBox(height: 20),

                // Comment Button
                _buildActionButton(
                  icon: FontAwesomeIcons.solidComment,
                  label: _commentCount.toString(),
                  iconSize: 28,
                  onTap: () => _showComments(context),
                ),
                const SizedBox(height: 20),

                // Bookmark Button
                _buildActionButton(
                  icon: _localBookmarkState
                      ? FontAwesomeIcons.solidBookmark
                      : FontAwesomeIcons.bookmark,
                  label: '',
                  iconSize: 28,
                  color: _localBookmarkState ? Colors.yellow : Colors.white,
                  onTap: _handleBookmarkAction,
                ),
                const SizedBox(height: 12),

                // More Button
                GestureDetector(
                  onTap: () {
                    // Add your more options logic here
                  },
                  child: const SizedBox(
                    width: 40,
                    height: 40,
                    child: Icon(
                      Icons.more_horiz,
                      color: Colors.white,
                      size: 18,
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
    Color color = Colors.white,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Icon(
            icon,
            color: color,
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
      ),
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

// Helper class to track like actions
class _LikeAction {
  final bool isLike;
  _LikeAction({required this.isLike});
}
