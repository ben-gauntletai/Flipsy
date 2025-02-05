import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../auth/bloc/auth_bloc.dart';
import '../../../services/video_service.dart';
import '../../../models/video.dart';
import 'edit_profile_screen.dart';
import '../../../widgets/user_avatar.dart';
import '../../../services/user_service.dart';
import '../../feed/screens/feed_screen.dart';
import '../../navigation/screens/main_navigation_screen.dart';
import 'followers_screen.dart';

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

class _ProfileScreenState extends State<ProfileScreen> {
  bool _isLoading = false;
  final _userService = UserService();

  @override
  void initState() {
    super.initState();
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
      body: StreamBuilder<Map<String, dynamic>>(
        stream: _userService.watchUserData(targetUserId),
        initialData: isCurrentUser
            ? {
                'displayName': currentUser!.displayName,
                'username': currentUser!.username,
                'avatarURL': currentUser!.avatarURL,
                'followingCount': currentUser!.followingCount,
                'followersCount': currentUser!.followersCount,
                'totalLikes': currentUser!.totalLikes,
              }
            : null,
        builder: (context, userStreamSnapshot) {
          if (!userStreamSnapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final userData = userStreamSnapshot.data!;
          final displayName = userData['displayName'] as String? ?? 'User';
          final username = userData['username'] as String? ?? displayName;
          final avatarURL = userData['avatarURL'] as String?;
          final followingCount = userData['followingCount'] as int? ?? 0;
          final followersCount = userData['followersCount'] as int? ?? 0;
          final totalLikes = userData['totalLikes'] as int? ?? 0;

          return RefreshIndicator(
            onRefresh: () async {
              // Implement refresh logic here
            },
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Column(
                    children: [
                      const SizedBox(height: 20),
                      // Profile Image
                      UserAvatar(
                        avatarURL: avatarURL,
                        radius: 50,
                      ),
                      const SizedBox(height: 16),
                      // Display Name and Username
                      Column(
                        children: [
                          Text(
                            displayName,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '@$username',
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(
                                  color: Colors.grey[600],
                                ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      // Stats Row
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _buildStatColumn(
                              context, followingCount.toString(), 'Following'),
                          _buildStatColumn(
                              context, followersCount.toString(), 'Followers'),
                          _buildStatColumn(
                              context, totalLikes.toString(), 'Likes'),
                        ],
                      ),
                      const SizedBox(height: 20),
                      // Edit Profile Button or Follow Button
                      if (isCurrentUser)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: OutlinedButton(
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
                              minimumSize: const Size.fromHeight(40),
                            ),
                            child: const Text('Edit Profile'),
                          ),
                        )
                      else
                        StreamBuilder<bool>(
                          stream:
                              _userService.watchFollowStatus(widget.userId!),
                          builder: (context, followSnapshot) {
                            final isFollowing = followSnapshot.data ?? false;

                            return Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 20),
                              child: ElevatedButton(
                                onPressed: _isLoading
                                    ? null
                                    : () => _handleFollowAction(isFollowing),
                                style: ElevatedButton.styleFrom(
                                  minimumSize: const Size.fromHeight(40),
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
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : Text(
                                        isFollowing ? 'Following' : 'Follow'),
                              ),
                            );
                          },
                        ),
                      const SizedBox(height: 20),
                      // Divider before videos
                      const Divider(height: 1),
                    ],
                  ),
                ),
                // Videos Grid
                StreamBuilder<List<Video>>(
                  stream: videoService.getUserVideos(targetUserId),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const SliverFillRemaining(
                        child: Center(
                          child: CircularProgressIndicator(),
                        ),
                      );
                    }

                    if (snapshot.hasError) {
                      return SliverFillRemaining(
                        child: Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(
                                Icons.error_outline,
                                size: 48,
                                color: Colors.grey,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'Something went wrong',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Please try again later',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(
                                      color: Colors.grey[600],
                                    ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }

                    final videos = snapshot.data ?? [];

                    if (videos.isEmpty) {
                      return SliverFillRemaining(
                        child: Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.videocam_off,
                                size: 48,
                                color: Colors.grey[400],
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'No flips found',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(
                                      color: Colors.grey[600],
                                    ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }

                    return SliverPadding(
                      padding: const EdgeInsets.all(1),
                      sliver: SliverGrid(
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisSpacing: 1,
                          crossAxisSpacing: 1,
                          childAspectRatio: 0.8,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
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
                                  if (video.thumbnailURL.isNotEmpty)
                                    CachedNetworkImage(
                                      imageUrl: video.thumbnailURL,
                                      fit: BoxFit.cover,
                                      placeholder: (context, url) => Container(
                                        color: Colors.grey[300],
                                        child: const Center(
                                          child: CircularProgressIndicator(),
                                        ),
                                      ),
                                      errorWidget: (context, url, error) =>
                                          Container(
                                        color: Colors.grey[300],
                                        child: const Icon(Icons.error),
                                      ),
                                    )
                                  else
                                    Container(
                                      color: Colors.grey[300],
                                      child: const Icon(Icons.video_library),
                                    ),
                                  if (video.likesCount > 0)
                                    Positioned(
                                      bottom: 8,
                                      left: 8,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.black.withOpacity(0.6),
                                          borderRadius:
                                              BorderRadius.circular(4),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(
                                              Icons.play_arrow,
                                              color: Colors.white,
                                              size: 16,
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
                                    ),
                                ],
                              ),
                            );
                          },
                          childCount: videos.length,
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
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
