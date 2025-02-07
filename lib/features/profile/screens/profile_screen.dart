import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';
import '../../auth/bloc/auth_bloc.dart';
import '../../../services/video_service.dart';
import '../../../models/video.dart';
import '../../../models/collection.dart';
import 'edit_profile_screen.dart';
import '../../../widgets/user_avatar.dart';
import '../../../services/user_service.dart';
import '../../feed/screens/feed_screen.dart';
import '../../navigation/screens/main_navigation_screen.dart';
import 'followers_screen.dart';
import '../widgets/collections_grid.dart';
import 'package:cloud_functions/cloud_functions.dart';

class ProfileScreen extends StatefulWidget {
  final String? userId; // If null, show current user's profile
  final bool showBackButton;
  final VoidCallback? onBack;

  const ProfileScreen({
    super.key,
    this.userId,
    this.showBackButton = false,
    this.onBack,
  });

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with TickerProviderStateMixin {
  final _userService = UserService();
  late TabController _tabController;
  final VideoService _videoService = VideoService();
  List<Collection> _collections = [];
  bool _isLoadingCollections = true;
  bool _isDisposed = false;
  bool _isLoading = false;
  StreamSubscription<List<Collection>>? _collectionsSubscription;

  // New state variables for collection videos
  bool _showingCollectionVideos = false;
  Collection? _selectedCollection;
  List<Video> _collectionVideos = [];
  bool _isLoadingCollectionVideos = false;

  String? get _currentUserId {
    final authState = context.read<AuthBloc>().state;
    return authState is Authenticated ? authState.user.id : null;
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 3,
      vsync: this,
      animationDuration: const Duration(milliseconds: 200),
    );
    _startListeningToCollections();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _tabController.dispose();
    _collectionsSubscription?.cancel();
    _videoService.cancelVideoCountSubscriptions();
    super.dispose();
  }

  void _startListeningToCollections() {
    print('\nProfileScreen: Starting to listen to collections');
    final userId = widget.userId ?? _currentUserId;
    if (userId == null) {
      print('ProfileScreen: No userId available for loading collections');
      return;
    }

    print('ProfileScreen: Setting up collection stream for user $userId');
    _collectionsSubscription =
        _videoService.watchUserCollections(userId).listen(
      (collections) {
        if (!_isDisposed && mounted) {
          print('\nProfileScreen: Received collections update');
          print('ProfileScreen: Number of collections: ${collections.length}');

          for (var collection in collections) {
            print('Collection ${collection.id}:');
            print('- Name: ${collection.name}');
            print('- Video count: ${collection.videoCount}');
            print('- Updated at: ${collection.updatedAt}');
          }

          setState(() {
            _collections = collections;
            _isLoadingCollections = false;
          });
        }
      },
      onError: (error, stackTrace) {
        print('\nProfileScreen: Error watching collections:');
        print('Error: $error');
        print('Stack trace: $stackTrace');
        if (!_isDisposed && mounted) {
          setState(() {
            _isLoadingCollections = false;
          });
        }
      },
    );
  }

  Future<void> _handleFollowAction(bool isFollowing) async {
    if (widget.userId == null) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final currentUser = context.read<AuthBloc>().state;
      if (currentUser is! Authenticated) {
        throw 'You must be logged in to follow users';
      }

      if (isFollowing) {
        // Get user display name for the dialog
        final userData = await _userService.getCachedUserData(widget.userId!);
        final displayName = userData['displayName'] as String? ?? 'User';

        final shouldUnfollow = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Unfollow User'),
            content: Text('Are you sure you want to unfollow @$displayName?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Yes'),
              ),
            ],
          ),
        );

        if (shouldUnfollow == true) {
          final success = await _userService.unfollowUser(widget.userId!);
          if (success && mounted) {
            setState(() {
              _isLoading = false;
            });
            _userService.clearCache();
          }
        } else {
          // If user cancels unfollow, reset loading state
          if (mounted) {
            setState(() {
              _isLoading = false;
            });
          }
        }
      } else {
        final success = await _userService.followUser(widget.userId!);
        if (success && mounted) {
          setState(() {
            _isLoading = false;
          });
          _userService.clearCache();
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _launchURL(String url,
      {bool isInstagram = false, bool isYoutube = false}) async {
    try {
      // Clean and validate the input URL
      String cleanUrl = url.trim();
      if (cleanUrl.isEmpty) return;

      Uri? uri;
      if (isInstagram) {
        // Remove any URL parts and get just the username
        final username = cleanUrl
            .replaceAll(RegExp(r'https?://(www\.)?instagram\.com/'), '')
            .replaceAll('@', '')
            .replaceAll('/', '');

        if (username.isEmpty) return;

        // First try to open in Instagram app
        uri = Uri.parse('instagram://user?username=$username');
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
          return;
        }

        // Fallback to web URL
        uri = Uri.parse('https://instagram.com/$username');
      } else if (isYoutube) {
        // Handle various YouTube URL formats
        String channelId = cleanUrl
            .replaceAll(
                RegExp(r'https?://(www\.)?youtube\.com/(@|channel/|c/)?'), '')
            .replaceAll('/', '');

        if (channelId.isEmpty) return;

        // First try to open in YouTube app
        uri = Uri.parse('vnd.youtube://www.youtube.com/$channelId');
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
          return;
        }

        // Fallback to web URL
        uri = Uri.parse('https://youtube.com/$channelId');
      }

      if (uri != null && await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        throw 'Could not launch URL';
      }
    } catch (e) {
      print('Error launching URL: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not open link: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _buildSocialLinks(String? instagramLink, String? youtubeLink) {
    if ((instagramLink?.isEmpty ?? true) && (youtubeLink?.isEmpty ?? true)) {
      return const SizedBox.shrink();
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (instagramLink?.isNotEmpty ?? false)
          IconButton(
            onPressed: () => _launchURL(instagramLink!, isInstagram: true),
            icon: const FaIcon(FontAwesomeIcons.instagram),
            color: Colors.grey[700],
            tooltip: 'Instagram',
          ),
        if (youtubeLink?.isNotEmpty ?? false)
          IconButton(
            onPressed: () => _launchURL(youtubeLink!, isYoutube: true),
            icon: const FaIcon(FontAwesomeIcons.youtube),
            color: Colors.red,
            tooltip: 'YouTube',
          ),
      ],
    );
  }

  void _showCreateCollectionDialog() {
    final nameController = TextEditingController();
    bool isPrivate = false;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('New Collection'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'Enter collection name',
                ),
              ),
              const SizedBox(height: 16),
              SwitchListTile(
                title: const Text('Private Collection'),
                value: isPrivate,
                onChanged: (value) {
                  setState(() {
                    isPrivate = value;
                  });
                },
              ),
            ],
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('CANCEL'),
            ),
            TextButton(
              onPressed: () async {
                final name = nameController.text.trim();
                if (name.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Please enter a name')),
                  );
                  return;
                }

                try {
                  final userId = widget.userId ?? _currentUserId;
                  if (userId == null) {
                    print(
                        '\nProfileScreen: No userId available for creating collection');
                    return;
                  }

                  print(
                      '\nProfileScreen: Creating collection for user $userId with name: $name');
                  final collection = await _videoService.createCollection(
                    userId: userId,
                    name: name,
                    isPrivate: isPrivate,
                  );
                  print(
                      'ProfileScreen: Successfully created collection with ID: ${collection.id}');

                  if (mounted) {
                    print(
                        'ProfileScreen: Current collections before update: ${_collections.length}');
                    setState(() {
                      _collections = [collection, ..._collections];
                    });
                    print(
                        'ProfileScreen: Updated collections list with new collection');
                    print(
                        'ProfileScreen: New collections count: ${_collections.length}');
                    print(
                        'ProfileScreen: Collection IDs: ${_collections.map((c) => c.id).join(', ')}');

                    // Reload collections to ensure consistency
                    _startListeningToCollections();

                    Navigator.pop(context);
                  }
                } catch (e, stackTrace) {
                  print('ProfileScreen: Error creating collection: $e');
                  print('ProfileScreen: Stack trace: $stackTrace');
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Error creating collection: $e')),
                    );
                  }
                }
              },
              child: const Text('CREATE'),
            ),
          ],
        ),
      ),
    );
  }

  void _updateTabController(bool showingCollection) {
    print('\nProfileScreen: Updating tab controller');
    print('ProfileScreen: Showing collection: $showingCollection');

    if (!mounted) return;

    final newLength = showingCollection ? 1 : 3;
    if (_tabController.length != newLength) {
      _tabController.dispose();
      setState(() {
        _tabController = TabController(
          length: newLength,
          vsync: this,
          animationDuration: const Duration(milliseconds: 200),
        );
      });
    }
  }

  Future<void> _handleCollectionSelected(Collection collection) async {
    print('\nProfileScreen: Loading videos for collection ${collection.id}');
    setState(() {
      _isLoadingCollectionVideos = true;
      _selectedCollection = collection;
      _showingCollectionVideos = true;
    });

    _updateTabController(true);

    try {
      final videos = await _videoService.getCollectionVideos(collection.id);
      print('ProfileScreen: Loaded ${videos.length} videos from collection');
      if (mounted) {
        setState(() {
          _collectionVideos = videos;
          _isLoadingCollectionVideos = false;
        });
      }
    } catch (e, stackTrace) {
      print('ProfileScreen: Error loading collection videos: $e');
      print('Stack trace: $stackTrace');
      if (mounted) {
        setState(() {
          _isLoadingCollectionVideos = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading collection videos: $e')),
        );
      }
    }
  }

  void _backToCollections() {
    print('ProfileScreen: Returning to collections view');
    setState(() {
      _showingCollectionVideos = false;
      _selectedCollection = null;
      _collectionVideos = [];
    });
    _updateTabController(false);
  }

  Future<void> _analyzeAllVideos() async {
    try {
      final functions = FirebaseFunctions.instance;
      final result =
          await functions.httpsCallable('analyzeExistingVideos').call();

      if (mounted) {
        final data = result.data as Map<String, dynamic>;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text('Analysis started: ${data['totalVideos']} videos found\n'
                    'Processed: ${data['processedCount']}, '
                    'Skipped: ${data['skippedCount']}, '
                    'Errors: ${data['errorCount']}'),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = context.watch<AuthBloc>().state;
    final currentUser = authState is Authenticated ? authState.user : null;

    // If no userId is provided and we're not authenticated, show loading
    if (widget.userId == null && currentUser == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    // Determine if this is the current user's profile and get the correct userId
    final isCurrentUser =
        widget.userId == null || (currentUser?.id == widget.userId);
    final targetUserId = isCurrentUser ? currentUser!.id : widget.userId!;
    final videoService = VideoService();

    return Scaffold(
      appBar: AppBar(
        leading: widget.showBackButton
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: widget.onBack,
              )
            : null,
        title: StreamBuilder<Map<String, dynamic>>(
          stream: _userService.watchUserData(targetUserId),
          builder: (context, snapshot) {
            if (snapshot.hasData) {
              return Text(snapshot.data!['displayName'] ?? 'Profile');
            }
            return const Text('Profile');
          },
        ),
        actions: [
          if (isCurrentUser) ...[
            IconButton(
              icon: const Icon(Icons.analytics),
              onPressed: _analyzeAllVideos,
              tooltip: 'Analyze Videos',
            ),
            PopupMenuButton<String>(
              onSelected: (value) async {
                if (value == 'logout') {
                  context.read<AuthBloc>().add(SignOutRequested());
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'logout',
                  child: Row(
                    children: [
                      Icon(Icons.logout),
                      SizedBox(width: 8),
                      Text('Logout'),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      body: StreamBuilder<Map<String, dynamic>>(
        stream: _userService.watchUserData(targetUserId),
        initialData: isCurrentUser
            ? {
                'displayName': currentUser!.displayName,
                'avatarURL': currentUser.avatarURL,
                'bio': currentUser.bio,
              }
            : null,
        builder: (context, userStreamSnapshot) {
          if (!userStreamSnapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final userData = userStreamSnapshot.data!;
          final displayName = userData['displayName'] as String? ?? 'User';
          final avatarURL = userData['avatarURL'] as String?;
          final bio = userData['bio'] as String? ?? '';

          return StreamBuilder<Map<String, int>>(
            stream: _userService.watchUserCounts(targetUserId),
            builder: (context, countsSnapshot) {
              final followingCount =
                  countsSnapshot.data?['followingCount'] ?? 0;
              final followersCount =
                  countsSnapshot.data?['followersCount'] ?? 0;
              final totalLikes = countsSnapshot.data?['totalLikes'] ?? 0;

              return Column(
                children: [
                  // Profile section
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Profile Image
                        UserAvatar(
                          avatarURL: avatarURL,
                          radius: 50,
                        ),
                        const SizedBox(height: 12),
                        // Display Name
                        Text(
                          displayName,
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    color: Colors.grey[600],
                                  ),
                        ),
                        if (bio.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            bio,
                            textAlign: TextAlign.center,
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                  color: Colors.grey[600],
                                ),
                          ),
                        ],
                        // Add social media links
                        _buildSocialLinks(
                          userData['instagramLink'] as String?,
                          userData['youtubeLink'] as String?,
                        ),
                        const SizedBox(height: 16),
                        // Stats Row
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _buildStatColumn(context, followingCount.toString(),
                                'Following'),
                            _buildStatColumn(context, followersCount.toString(),
                                'Followers'),
                            _buildStatColumn(
                                context, totalLikes.toString(), 'Likes'),
                          ],
                        ),
                        const SizedBox(height: 16),
                        // Edit Profile Button or Follow Button
                        if (isCurrentUser)
                          OutlinedButton(
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) =>
                                      const EditProfileScreen(),
                                ),
                              );
                            },
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(double.infinity, 36),
                            ),
                            child: const Text('Edit Profile'),
                          )
                        else
                          StreamBuilder<bool>(
                            stream:
                                _userService.watchFollowStatus(widget.userId!),
                            builder: (context, followSnapshot) {
                              final isFollowing = followSnapshot.data ?? false;

                              return ElevatedButton(
                                onPressed: _isLoading
                                    ? null
                                    : () => _handleFollowAction(isFollowing),
                                style: ElevatedButton.styleFrom(
                                  minimumSize: const Size(double.infinity, 36),
                                  backgroundColor: isFollowing
                                      ? Colors.grey[200]
                                      : Theme.of(context).primaryColor,
                                  foregroundColor:
                                      isFollowing ? Colors.black : Colors.white,
                                ),
                                child: _isLoading
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2),
                                      )
                                    : Text(
                                        isFollowing ? 'Following' : 'Follow'),
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Tab Bar
                  TabBar(
                    controller: _tabController,
                    tabs: _showingCollectionVideos
                        ? [
                            Tab(
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.arrow_back),
                                    onPressed: _backToCollections,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      _selectedCollection?.name ?? '',
                                      style: const TextStyle(fontSize: 16),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ]
                        : const [
                            Tab(text: 'Videos'),
                            Tab(text: 'Bookmarked'),
                            Tab(text: 'Collections'),
                          ],
                    labelColor: Theme.of(context).primaryColor,
                    unselectedLabelColor: Colors.grey,
                    indicatorColor: _showingCollectionVideos
                        ? Colors.transparent
                        : Theme.of(context).primaryColor,
                  ),
                  // Tab Bar View
                  Expanded(
                    child: TabBarView(
                      controller: _tabController,
                      children: _showingCollectionVideos
                          ? [
                              // Collection Videos Grid
                              _isLoadingCollectionVideos
                                  ? const Center(
                                      child: CircularProgressIndicator())
                                  : _collectionVideos.isEmpty
                                      ? Center(
                                          child: Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              Icon(Icons.videocam_off,
                                                  size: 48,
                                                  color: Colors.grey[400]),
                                              const SizedBox(height: 16),
                                              Text(
                                                'No videos in this collection',
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .titleMedium,
                                              ),
                                            ],
                                          ),
                                        )
                                      : GridView.builder(
                                          padding: const EdgeInsets.all(1),
                                          gridDelegate:
                                              const SliverGridDelegateWithFixedCrossAxisCount(
                                            crossAxisCount: 3,
                                            childAspectRatio: 0.8,
                                            crossAxisSpacing: 1,
                                            mainAxisSpacing: 1,
                                          ),
                                          itemCount: _collectionVideos.length,
                                          itemBuilder: (context, index) {
                                            final video =
                                                _collectionVideos[index];
                                            return GestureDetector(
                                              onTap: () {
                                                MainNavigationScreen
                                                    .jumpToVideo(
                                                  context,
                                                  video.id,
                                                  showBackButton: true,
                                                );
                                              },
                                              child: Stack(
                                                fit: StackFit.expand,
                                                children: [
                                                  Image.network(
                                                    video.thumbnailURL,
                                                    fit: BoxFit.cover,
                                                  ),
                                                  Positioned(
                                                    bottom: 8,
                                                    left: 8,
                                                    child: Row(
                                                      children: [
                                                        const Icon(
                                                          FontAwesomeIcons
                                                              .heart,
                                                          color: Colors.white,
                                                          size: 14,
                                                        ),
                                                        const SizedBox(
                                                            width: 4),
                                                        Text(
                                                          video.likesCount
                                                              .toString(),
                                                          style:
                                                              const TextStyle(
                                                            color: Colors.white,
                                                            fontSize: 12,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            );
                                          },
                                        ),
                            ]
                          : [
                              // Videos Tab
                              StreamBuilder<List<Video>>(
                                stream:
                                    videoService.getUserVideos(targetUserId),
                                builder: (context, snapshot) {
                                  if (snapshot.connectionState ==
                                      ConnectionState.waiting) {
                                    return const Center(
                                        child: CircularProgressIndicator());
                                  }

                                  if (snapshot.hasError) {
                                    return Center(
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Icon(Icons.error_outline,
                                              size: 48,
                                              color: Colors.grey[400]),
                                          const SizedBox(height: 16),
                                          Text('Error loading videos',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium),
                                        ],
                                      ),
                                    );
                                  }

                                  final videos = snapshot.data ?? [];

                                  if (videos.isEmpty) {
                                    return Center(
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Icon(Icons.videocam_off,
                                              size: 48,
                                              color: Colors.grey[400]),
                                          const SizedBox(height: 16),
                                          Text(
                                            'No videos found',
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium,
                                          ),
                                        ],
                                      ),
                                    );
                                  }

                                  return GridView.builder(
                                    padding: const EdgeInsets.all(1),
                                    gridDelegate:
                                        const SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: 3,
                                      childAspectRatio: 0.8,
                                      crossAxisSpacing: 1,
                                      mainAxisSpacing: 1,
                                    ),
                                    itemCount: videos.length,
                                    itemBuilder: (context, index) {
                                      final video = videos[index];
                                      return GestureDetector(
                                        onTap: () {
                                          MainNavigationScreen.jumpToVideo(
                                            context,
                                            video.id,
                                            showBackButton: true,
                                          );
                                        },
                                        child: Stack(
                                          fit: StackFit.expand,
                                          children: [
                                            Image.network(
                                              video.thumbnailURL,
                                              fit: BoxFit.cover,
                                            ),
                                            Positioned(
                                              bottom: 8,
                                              left: 8,
                                              child: Row(
                                                children: [
                                                  const Icon(
                                                    FontAwesomeIcons.heart,
                                                    color: Colors.white,
                                                    size: 14,
                                                  ),
                                                  const SizedBox(width: 4),
                                                  Text(
                                                    video.likesCount.toString(),
                                                    style: const TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 12,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  );
                                },
                              ),
                              // Bookmarked Videos Tab
                              StreamBuilder<List<Video>>(
                                stream: videoService.getBookmarkedVideos(),
                                builder: (context, snapshot) {
                                  if (snapshot.connectionState ==
                                      ConnectionState.waiting) {
                                    return const Center(
                                        child: CircularProgressIndicator());
                                  }

                                  if (snapshot.hasError) {
                                    return Center(
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Icon(Icons.error_outline,
                                              size: 48,
                                              color: Colors.grey[400]),
                                          const SizedBox(height: 16),
                                          Text(
                                              'Error loading bookmarked videos',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium),
                                        ],
                                      ),
                                    );
                                  }

                                  final videos = snapshot.data ?? [];

                                  if (videos.isEmpty) {
                                    return Center(
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Icon(Icons.bookmark_border,
                                              size: 48,
                                              color: Colors.grey[400]),
                                          const SizedBox(height: 16),
                                          Text(
                                            'No bookmarked videos',
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium,
                                          ),
                                        ],
                                      ),
                                    );
                                  }

                                  return GridView.builder(
                                    padding: const EdgeInsets.all(1),
                                    gridDelegate:
                                        const SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: 3,
                                      childAspectRatio: 0.8,
                                      crossAxisSpacing: 1,
                                      mainAxisSpacing: 1,
                                    ),
                                    itemCount: videos.length,
                                    itemBuilder: (context, index) {
                                      final video = videos[index];
                                      return GestureDetector(
                                        onTap: () {
                                          MainNavigationScreen.jumpToVideo(
                                            context,
                                            video.id,
                                            showBackButton: true,
                                          );
                                        },
                                        child: Stack(
                                          fit: StackFit.expand,
                                          children: [
                                            Image.network(
                                              video.thumbnailURL,
                                              fit: BoxFit.cover,
                                            ),
                                            Positioned(
                                              bottom: 8,
                                              left: 8,
                                              child: Row(
                                                children: [
                                                  const Icon(
                                                    FontAwesomeIcons.heart,
                                                    color: Colors.white,
                                                    size: 14,
                                                  ),
                                                  const SizedBox(width: 4),
                                                  Text(
                                                    video.likesCount.toString(),
                                                    style: const TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 12,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  );
                                },
                              ),
                              // Collections Tab
                              CollectionsGrid(
                                key: const ValueKey('collections_grid'),
                                collections: _collections,
                                onCreateCollection: _showCreateCollectionDialog,
                                isLoading: _isLoadingCollections,
                                onCollectionSelected: _handleCollectionSelected,
                              ),
                            ],
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildStatColumn(BuildContext context, String value, String label) {
    final bool isClickable = label == 'Following' || label == 'Followers';

    Widget content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: Theme.of(context)
              .textTheme
              .titleLarge
              ?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.grey[600],
              ),
        ),
      ],
    );

    if (!isClickable) return content;

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => FollowersScreen(
              userId: widget.userId ??
                  (context.read<AuthBloc>().state as Authenticated).user.id,
              title: label,
              isFollowers: label == 'Followers',
            ),
          ),
        );
      },
      child: content,
    );
  }
}
