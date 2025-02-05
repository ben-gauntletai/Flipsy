import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../services/user_service.dart';
import '../../../widgets/user_avatar.dart';
import 'profile_screen.dart';

class FollowersScreen extends StatelessWidget {
  final String userId;
  final String title;
  final bool isFollowers; // true for followers, false for following

  const FollowersScreen({
    super.key,
    required this.userId,
    required this.title,
    required this.isFollowers,
  });

  @override
  Widget build(BuildContext context) {
    final userService = UserService();

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('follows')
            .where(isFollowers ? 'followingId' : 'followerId',
                isEqualTo: userId)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Text('Error: ${snapshot.error}'),
            );
          }

          final follows = snapshot.data?.docs ?? [];

          if (follows.isEmpty) {
            return Center(
              child: Text(
                isFollowers ? 'No followers yet' : 'Not following anyone',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            );
          }

          return ListView.builder(
            itemCount: follows.length,
            itemBuilder: (context, index) {
              final followDoc = follows[index];
              final followData = followDoc.data() as Map<String, dynamic>;
              final otherUserId = isFollowers
                  ? followData['followerId'] as String
                  : followData['followingId'] as String;

              return FutureBuilder<Map<String, dynamic>>(
                future: userService.getCachedUserData(otherUserId),
                builder: (context, userSnapshot) {
                  if (!userSnapshot.hasData) {
                    return const SizedBox(height: 72);
                  }

                  final userData = userSnapshot.data!;
                  final displayName =
                      userData['displayName'] as String? ?? 'User';
                  final avatarURL = userData['avatarURL'] as String?;

                  return ListTile(
                    leading: UserAvatar(
                      avatarURL: avatarURL,
                      radius: 24,
                    ),
                    title: Text(displayName),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => ProfileScreen(
                            userId: otherUserId,
                            showBackButton: true,
                          ),
                        ),
                      );
                    },
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}
