import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
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
                'avatarURL': currentUser!.avatarURL,
                'followingCount': currentUser!.followingCount,
                'followersCount': currentUser!.followersCount,
                'totalLikes': currentUser!.totalLikes,
                'bio': currentUser!.bio,
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
          final followingCount = userData['followingCount'] as int? ?? 0;
          final followersCount = userData['followersCount'] as int? ?? 0;
          final totalLikes = userData['totalLikes'] as int? ?? 0;

          return LayoutBuilder(
            builder: (context, constraints) {
              // Calculate dimensions for profile section and video grid
              final screenHeight = constraints.maxHeight;
              final screenWidth = constraints.maxWidth;

              // Calculate video item size for exactly 2 rows of 3 videos
              final videoWidth =
                  (screenWidth - 2) / 3; // 1px spacing between items
              final videoHeight =
                  videoWidth / 0.8; // maintain aspect ratio of 0.8
              final videoGridHeight =
                  videoHeight * 2 + 1; // 2 rows with 1px spacing

              // Profile section takes remaining height
              final profileSectionHeight = screenHeight - videoGridHeight;

              return Column(
                children: [
                  // Non-scrollable profile section with calculated height
                  SizedBox(
                    height: profileSectionHeight,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          // Profile Image
                          UserAvatar(
                            avatarURL: avatarURL,
                            radius: profileSectionHeight *
                                0.15, // Proportional to section height
                          ),
                          // Display Name
                          Text(
                            displayName,
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(
                                  color: Colors.grey[600],
                                ),
                          ),
                          if (bio.isNotEmpty)
                            // Bio
                            Text(
                              bio,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                          // Social Media Links
                          _buildSocialLinks(
                            userData['instagramLink'] as String?,
                            userData['youtubeLink'] as String?,
                          ),
                          // Stats Row
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              _buildStatColumn(context,
                                  followingCount.toString(), 'Following'),
                              _buildStatColumn(context,
                                  followersCount.toString(), 'Followers'),
                              _buildStatColumn(
                                  context, totalLikes.toString(), 'Likes'),
                            ],
                          ),
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
                                minimumSize: Size(screenWidth - 32, 36),
                              ),
                              child: const Text('Edit Profile'),
                            )
                          else
                            StreamBuilder<bool>(
                              stream: _userService
                                  .watchFollowStatus(widget.userId!),
                              builder: (context, followSnapshot) {
                                final isFollowing =
                                    followSnapshot.data ?? false;

                                return ElevatedButton(
                                  onPressed: _isLoading
                                      ? null
                                      : () => _handleFollowAction(isFollowing),
                                  style: ElevatedButton.styleFrom(
                                    minimumSize: Size(screenWidth - 32, 36),
                                    backgroundColor: isFollowing
                                        ? Colors.grey[200]
                                        : Theme.of(context).primaryColor,
                                    foregroundColor: isFollowing
                                        ? Colors.black
                                        : Colors.white,
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
                          const Divider(height: 1),
                        ],
                      ),
                    ),
                  ),
                  // Scrollable videos section with exact height for 6 videos
                  SizedBox(
                    height: videoGridHeight,
                    child: StreamBuilder<List<Video>>(
                      stream: videoService.getUserVideos(targetUserId),
                      builder: (context, snapshot) {
                        if (snapshot.connectionState ==
                            ConnectionState.waiting) {
                          return const Center(
                              child: CircularProgressIndicator());
                        }

                        if (snapshot.hasError) {
                          return Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.error_outline,
                                    size: 48, color: Colors.grey),
                                const SizedBox(height: 16),
                                Text('Something went wrong',
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
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.videocam_off,
                                    size: 48, color: Colors.grey[400]),
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
                          );
                        }

                        return GridView.builder(
                          padding: const EdgeInsets.all(1),
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            mainAxisSpacing: 1,
                            crossAxisSpacing: 1,
                            childAspectRatio: 0.8,
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
                                  if (video.thumbnailURL.isNotEmpty)
                                    CachedNetworkImage(
                                      imageUrl: video.thumbnailURL,
                                      fit: BoxFit.cover,
                                      placeholder: (context, url) => Container(
                                        color: Colors.grey[300],
                                        child: const Center(
                                            child: CircularProgressIndicator()),
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
                                            const Icon(Icons.play_arrow,
                                                color: Colors.white, size: 16),
                                            const SizedBox(width: 4),
                                            Text(
                                              video.likesCount.toString(),
                                              style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 12),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            );
                          },
                        );
                      },
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
