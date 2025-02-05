import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:async';
import '../../../services/user_service.dart';
import '../../../widgets/user_avatar.dart';
import '../../../features/navigation/screens/main_navigation_screen.dart';
import 'package:timeago/timeago.dart' as timeago;

class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  final UserService _userService = UserService();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  String? _currentUserId;
  StreamSubscription<User?>? _authSubscription;

  @override
  void initState() {
    super.initState();
    _authSubscription = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (mounted) {
        setState(() {
          _currentUserId = user?.uid;
        });
      }
    });
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  Future<void> _handleFollowAction(String userId, bool isFollowing) async {
    print('ActivityScreen: Handling follow action');
    print('ActivityScreen: Current user: $_currentUserId');
    print('ActivityScreen: Target user to follow: $userId');
    print('ActivityScreen: Is currently following: $isFollowing');

    try {
      if (isFollowing) {
        // Show confirmation dialog before unfollowing
        final shouldUnfollow = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text(
              'Unfollow',
              textAlign: TextAlign.center,
            ),
            content: const Text(
              'Are you sure you want to unfollow this user?',
              textAlign: TextAlign.center,
            ),
            contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
            actionsPadding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            actions: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.grey[600],
                      ),
                      child: const Text('CANCEL'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.red,
                      ),
                      child: const Text('UNFOLLOW'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );

        if (shouldUnfollow == true) {
          await _userService.unfollowUser(userId);
        }
      } else {
        await _userService.followUser(userId);
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

  Widget _buildNotificationItem(Map<String, dynamic> notification) {
    final sourceUserId = notification['sourceUserId'] as String;
    final notificationType = notification['type'] as String;

    // Skip notifications from yourself
    if (sourceUserId == _currentUserId) {
      return const SizedBox.shrink();
    }

    return FutureBuilder<Map<String, dynamic>?>(
      future: _userService.getUserData(sourceUserId),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const SizedBox.shrink();
        }

        final userData = snapshot.data!;
        final timeAgo = timeago.format(
          (notification['createdAt'] as Timestamp).toDate(),
          allowFromNow: true,
        );

        if (notificationType == 'video_post') {
          return ListTile(
            leading: GestureDetector(
              onTap: () {
                MainNavigationScreen.showUserProfile(context, sourceUserId);
              },
              child: UserAvatar(
                avatarURL: userData['avatarURL'] as String?,
                radius: 24,
              ),
            ),
            title: RichText(
              text: TextSpan(
                style: const TextStyle(color: Colors.black87),
                children: [
                  TextSpan(
                    text: userData['displayName'] as String,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const TextSpan(text: ' posted a new video'),
                ],
              ),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(timeAgo),
                if (notification['videoDescription'] != null)
                  Text(
                    notification['videoDescription'] as String,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.black54),
                  ),
              ],
            ),
            trailing: notification['videoThumbnailURL'] != null
                ? GestureDetector(
                    onTap: () {
                      MainNavigationScreen.jumpToVideo(
                        context,
                        notification['videoId'] as String,
                        showBackButton: true,
                      );
                    },
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.network(
                        notification['videoThumbnailURL'] as String,
                        width: 50,
                        height: 50,
                        fit: BoxFit.cover,
                      ),
                    ),
                  )
                : null,
          );
        }

        // Follow notification (existing code)
        return StreamBuilder<bool>(
          stream: _userService.watchFollowStatus(sourceUserId),
          builder: (context, followSnapshot) {
            final isFollowing = followSnapshot.data ?? false;

            return ListTile(
              leading: GestureDetector(
                onTap: () {
                  MainNavigationScreen.showUserProfile(context, sourceUserId);
                },
                child: UserAvatar(
                  avatarURL: userData['avatarURL'] as String?,
                  radius: 24,
                ),
              ),
              title: RichText(
                text: TextSpan(
                  style: const TextStyle(color: Colors.black87),
                  children: [
                    TextSpan(
                      text: userData['displayName'] as String,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const TextSpan(text: ' started following you'),
                  ],
                ),
              ),
              subtitle: Text(timeAgo),
              trailing: SizedBox(
                width: 110,
                child: TextButton(
                  onPressed: () =>
                      _handleFollowAction(sourceUserId, isFollowing),
                  style: TextButton.styleFrom(
                    backgroundColor:
                        isFollowing ? Colors.grey[200] : Colors.blue,
                    foregroundColor:
                        isFollowing ? Colors.black87 : Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                  child: Text(isFollowing ? 'Friends' : 'Follow back'),
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // If not authenticated, show a message
    if (_currentUserId == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Activity'),
        ),
        body: const Center(
          child: Text(
            'Please sign in to view your activity',
            style: TextStyle(
              color: Colors.black54,
              fontSize: 16,
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Activity'),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: _firestore
            .collection('notifications')
            .where('userId', isEqualTo: _currentUserId)
            .where('type', whereIn: ['follow', 'video_post'])
            .orderBy('createdAt', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return const Center(
              child: Text(
                'No activity yet',
                style: TextStyle(
                  color: Colors.black54,
                  fontSize: 16,
                ),
              ),
            );
          }

          return ListView.builder(
            itemCount: snapshot.data!.docs.length,
            itemBuilder: (context, index) {
              final notification =
                  snapshot.data!.docs[index].data() as Map<String, dynamic>;
              return _buildNotificationItem(notification);
            },
          );
        },
      ),
    );
  }
}
