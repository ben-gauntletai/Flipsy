import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/user_service.dart';
import '../widgets/user_avatar.dart';
import 'profile_screen.dart';

class FollowersScreen extends StatelessWidget {
  final String userId;
  final String title;
  final bool isFollowers;

  const FollowersScreen({
    Key? key,
    required this.userId,
    required this.title,
    required this.isFollowers,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    print(
        'Building ${isFollowers ? "Followers" : "Following"} screen for user: $userId');
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('follows')
            .where(isFollowers ? 'followingId' : 'followerId',
                isEqualTo: userId)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            print(
                'Error loading ${isFollowers ? "followers" : "following"}: ${snapshot.error}');
            return Center(
              child: Text(
                  'Error loading ${isFollowers ? "followers" : "following"}'),
            );
          }

          if (!snapshot.hasData) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          final users = snapshot.data!.docs;

          if (users.isEmpty) {
            return Center(
              child: Text(
                'No ${isFollowers ? "followers" : "following"} yet',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            );
          }

          return ListView.builder(
            itemCount: users.length,
            itemBuilder: (context, index) {
              final userData = users[index].data() as Map<String, dynamic>;
              final otherUserId = isFollowers
                  ? userData['followerId'] as String
                  : userData['followingId'] as String;

              return FutureBuilder<Map<String, dynamic>>(
                future: UserService().getCachedUserData(otherUserId),
                builder: (context, userSnapshot) {
                  if (!userSnapshot.hasData) {
                    return const ListTile(
                      leading: CircleAvatar(),
                      title: LinearProgressIndicator(),
                    );
                  }

                  final user = userSnapshot.data!;
                  final displayName = user['displayName'] as String? ?? 'User';
                  final avatarUrl = user['avatarURL'] as String?;

                  return ListTile(
                    leading: UserAvatar(
                      userId: otherUserId,
                      avatarUrl: avatarUrl,
                      size: 40,
                    ),
                    title: Text('@$displayName'),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) =>
                              ProfileScreen(userId: otherUserId),
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
