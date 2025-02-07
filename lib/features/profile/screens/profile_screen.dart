import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
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
    with SingleTickerProviderStateMixin {
  bool _isLoading = false;
  final _userService = UserService();
  late TabController _tabController;
  final VideoService _videoService = VideoService();
  List<Video> _videos = [];
  List<Collection> _collections = [];
  bool _isLoadingCollections = true;
  bool _isDisposed = false;

  String? get _currentUserId {
    final authState = context.read<AuthBloc>().state;
    return authState is Authenticated ? authState.user.id : null;
  }

  @override
  void initState() {
    super.initState();
    _initializeTabController();
    _loadUserData();
    _loadCollections();
  }

  void _initializeTabController() {
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(_handleTabChange);
  }

  void _handleTabChange() {
    if (_isDisposed) return;
    if (!_tabController.indexIsChanging) {
      setState(() {
        // Rebuild when tab changes
        if (_tabController.index == 2 && _isLoadingCollections) {
          _loadCollections(); // Reload collections when switching to collections tab
        }
      });
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_isDisposed && !_tabController.hasListeners) {
      _tabController.addListener(_handleTabChange);
    }
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

  Future<void> _loadUserData() async {
    if (_isDisposed) return;

    try {
      final userId = widget.userId ?? _currentUserId;
      if (userId == null) return;

      final userData = await _userService.getUserData(userId);
      if (!_isDisposed && mounted) {
        setState(() {
          _videos = userData['videos'] as List<Video>? ?? [];
          _collections = userData['collections'] as List<Collection> ?? [];
          _isLoadingCollections = false;
        });
      }
    } catch (e) {
      print('Error loading user data: $e');
      if (!_isDisposed && mounted) {
        setState(() {
          _isLoadingCollections = false;
        });
      }
    }
  }

  Future<void> _loadCollections() async {
    if (_isDisposed) return;

    try {
      final userId = widget.userId ?? _currentUserId;
      if (userId == null) {
        print('\nProfileScreen: No userId available for loading collections');
        return;
      }

      print('\nProfileScreen: Starting to load collections for user $userId');
      print('ProfileScreen: Current collections count: ${_collections.length}');
      setState(() {
        _isLoadingCollections = true;
      });

      final collections = await _videoService.getUserCollections(userId);
      print('ProfileScreen: Loaded ${collections.length} collections');
      print('ProfileScreen: Collection details:');
      for (var collection in collections) {
        print('- ID: ${collection.id}');
        print('  Name: ${collection.name}');
        print('  Video Count: ${collection.videoCount}');
        print('  Created At: ${collection.createdAt}');
      }

      if (!_isDisposed && mounted) {
        print('ProfileScreen: Updating state with collections');
        setState(() {
          _collections = collections;
          _isLoadingCollections = false;
        });
        print(
            'ProfileScreen: State updated with ${_collections.length} collections');
        print(
            'ProfileScreen: Collection IDs in state: ${_collections.map((c) => c.id).join(', ')}');
      }
    } catch (e, stackTrace) {
      print('ProfileScreen: Error loading collections: $e');
      print('ProfileScreen: Stack trace: $stackTrace');
      if (!_isDisposed && mounted) {
        setState(() {
          _isLoadingCollections = false;
        });
      }
    }
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
                    _loadCollections();

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

  @override
  Widget build(BuildContext context) {
    if (_isDisposed) {
      return const SizedBox.shrink();
    }

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
          if (isCurrentUser)
            IconButton(
              icon: const Icon(Icons.logout),
              onPressed: () {
                context.read<AuthBloc>().add(SignOutRequested());
              },
              tooltip: 'Logout',
            ),
        ],
      ),
      body: Column(
        children: [
          // Profile section
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Profile Image
                UserAvatar(
                  avatarURL: currentUser?.avatarURL,
                  radius: 50,
                ),
                const SizedBox(height: 12),
                // Display Name
                Text(
                  currentUser?.displayName ?? 'User',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.grey[600],
                      ),
                ),
                if (currentUser?.bio?.isNotEmpty ?? false) ...[
                  const SizedBox(height: 8),
                  Text(
                    currentUser!.bio!,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.grey[600],
                        ),
                  ),
                ],
                const SizedBox(height: 16),
                // Stats Row
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildStatColumn(
                        context, _videos.length.toString(), 'Videos'),
                    _buildStatColumn(
                        context, _collections.length.toString(), 'Collections'),
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
                          builder: (context) => const EditProfileScreen(),
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
                    stream: _userService.watchFollowStatus(widget.userId!),
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
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Text(isFollowing ? 'Following' : 'Follow'),
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
            tabs: const [
              Tab(text: 'Videos'),
              Tab(text: 'Bookmarks'),
              Tab(text: 'Collections'),
            ],
            labelColor: Theme.of(context).primaryColor,
            unselectedLabelColor: Colors.grey,
            indicatorColor: Theme.of(context).primaryColor,
          ),
          // Tab Bar View
          Expanded(
            child: TabBarView(
              controller: _tabController,
              physics:
                  const NeverScrollableScrollPhysics(), // Prevent swipe to change tabs
              children: [
                // Videos Tab
                _buildVideosGrid(),
                // Bookmarks Tab
                _buildBookmarksGrid(),
                // Collections Tab
                CollectionsGrid(
                  key: const ValueKey('collections_grid'),
                  collections: _collections,
                  onCreateCollection: _showCreateCollectionDialog,
                  isLoading: _isLoadingCollections,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideosGrid() {
    if (_videos.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.videocam_off, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              'No videos found',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(1),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.8,
        crossAxisSpacing: 1,
        mainAxisSpacing: 1,
      ),
      itemCount: _videos.length,
      itemBuilder: (context, index) {
        final video = _videos[index];
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
  }

  Widget _buildBookmarksGrid() {
    if (_videos.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.bookmark_border, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              'No bookmarked videos',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(1),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.8,
        crossAxisSpacing: 1,
        mainAxisSpacing: 1,
      ),
      itemCount: _videos.length,
      itemBuilder: (context, index) {
        final video = _videos[index];
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
