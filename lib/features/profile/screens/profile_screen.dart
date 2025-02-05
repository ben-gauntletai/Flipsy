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

class ProfileScreen extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final authState = context.watch<AuthBloc>().state;
    final currentUser = authState is Authenticated ? authState.user : null;

    // If no userId is provided and we're not authenticated, show loading
    if (userId == null && currentUser == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    // Determine if this is the current user's profile
    final isCurrentUser = userId == null || (currentUser?.id == userId);
    final userService = UserService();
    final videoService = VideoService();

    return Scaffold(
      appBar: AppBar(
        leading: showBackButton
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: onBack,
              )
            : null,
        title: isCurrentUser
            ? Text(currentUser!.displayName)
            : FutureBuilder<Map<String, dynamic>>(
                future: userService.getCachedUserData(userId!),
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
      body: FutureBuilder<Map<String, dynamic>>(
        future: isCurrentUser ? null : userService.getCachedUserData(userId!),
        builder: (context, userSnapshot) {
          // Show loading while fetching user data
          if (!isCurrentUser && !userSnapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          // Use current user data or fetched user data
          final Map<String, dynamic> userData = isCurrentUser
              ? {
                  'displayName': currentUser!.displayName,
                  'avatarURL': currentUser!.avatarURL,
                  'followingCount': currentUser!.followingCount,
                  'followersCount': currentUser!.followersCount,
                  'totalLikes': currentUser!.totalLikes,
                }
              : (userSnapshot.data! as Map<String, dynamic>);

          final displayName = isCurrentUser
              ? currentUser!.displayName
              : (userData['displayName'] as String?) ?? 'User';
          final avatarURL = isCurrentUser
              ? currentUser!.avatarURL
              : userData['avatarURL'] as String?;
          final followingCount = isCurrentUser
              ? currentUser!.followingCount
              : (userData['followingCount'] as int?) ?? 0;
          final followersCount = isCurrentUser
              ? currentUser!.followersCount
              : (userData['followersCount'] as int?) ?? 0;
          final totalLikes = isCurrentUser
              ? currentUser!.totalLikes
              : (userData['totalLikes'] as int?) ?? 0;

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
                      // Display Name
                      Text(
                        '@$displayName',
                        style: Theme.of(context).textTheme.titleLarge,
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
                      // Edit Profile Button (only show for current user)
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
                        ),
                      const SizedBox(height: 20),
                      // Divider before videos
                      const Divider(height: 1),
                    ],
                  ),
                ),
                // Videos Grid
                StreamBuilder<List<Video>>(
                  stream: videoService
                      .getUserVideos(isCurrentUser ? currentUser!.id : userId!),
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
    return Column(
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
  }
}
