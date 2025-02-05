import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

class UserService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Get user data by ID
  Future<Map<String, dynamic>> getUserData(String userId) async {
    try {
      final doc = await _firestore.collection('users').doc(userId).get();
      if (doc.exists) {
        final data = doc.data() as Map<String, dynamic>;
        // Ensure displayName exists
        if (!data.containsKey('displayName')) {
          data['displayName'] = 'Unknown User';
        }
        return data;
      } else {
        return {
          'displayName': 'Unknown User',
          'avatarURL': null,
        };
      }
    } catch (e) {
      print('Error fetching user data: $e');
      return {
        'displayName': 'Unknown User',
        'avatarURL': null,
      };
    }
  }

  // Cache user data in memory for better performance
  final Map<String, Map<String, dynamic>> _userCache = {};

  // Get user data with caching
  Future<Map<String, dynamic>> getCachedUserData(String userId) async {
    if (_userCache.containsKey(userId)) {
      return _userCache[userId]!;
    }

    final userData = await getUserData(userId);
    _userCache[userId] = userData;
    return userData;
  }

  // Clear cache for testing or when user data is updated
  void clearCache() {
    _userCache.clear();
  }

  Stream<Map<String, dynamic>> watchUserData(String userId) {
    print('Watching user data for: $userId');
    return _firestore
        .collection('users')
        .doc(userId)
        .snapshots()
        .map((snapshot) {
      print('Received user data update for $userId: ${snapshot.data()}');

      // Default user data with all required fields
      final Map<String, dynamic> defaultData = {
        'displayName': 'Unknown User',
        'avatarURL': null,
        'followersCount': 0,
        'followingCount': 0,
        'totalLikes': 0,
        'totalVideos': 0,
      };

      if (!snapshot.exists) {
        print('No user data found for $userId, using defaults');
        return defaultData;
      }

      final data = snapshot.data() as Map<String, dynamic>;

      // Ensure all required fields exist with proper types
      final Map<String, dynamic> sanitizedData = {
        ...defaultData,
        ...data,
        // Ensure counts are integers
        'followersCount': (data['followersCount'] ?? 0) as int,
        'followingCount': (data['followingCount'] ?? 0) as int,
        'totalLikes': (data['totalLikes'] ?? 0) as int,
        'totalVideos': (data['totalVideos'] ?? 0) as int,
      };

      print('Sanitized user data for $userId: $sanitizedData');

      // Update cache with sanitized data
      _userCache[userId] = sanitizedData;
      return sanitizedData;
    });
  }

  Future<bool> followUser(String userId) async {
    print('Attempting to follow user: $userId');
    try {
      final functions = FirebaseFunctions.instance;
      final callable = functions.httpsCallable('followUser');

      // Clear cache before the operation to ensure fresh data
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser != null) {
        print(
            'Pre-emptively clearing cache for users: ${currentUser.uid} and $userId');
        _userCache.remove(currentUser.uid);
        _userCache.remove(userId);
      }

      final result = await callable.call<Map<String, dynamic>>({
        'followingId': userId,
      });

      print('Follow operation result: ${result.data}');

      // Force a refresh of the user data after the operation
      if (currentUser != null) {
        print('Forcing refresh of user data after follow operation');
        await getUserData(currentUser.uid);
        await getUserData(userId);
      }

      return result.data['success'] as bool;
    } catch (e) {
      print('Error following user $userId: $e');
      if (e is FirebaseFunctionsException) {
        switch (e.code) {
          case 'not-found':
            throw 'User not found';
          case 'already-exists':
            throw 'Already following this user';
          case 'permission-denied':
            throw 'Permission denied';
          default:
            throw 'Failed to follow user';
        }
      }
      rethrow;
    }
  }

  Future<bool> unfollowUser(String userId) async {
    print('Attempting to unfollow user: $userId');
    try {
      final functions = FirebaseFunctions.instance;
      final callable = functions.httpsCallable('unfollowUser');

      // Clear cache before the operation to ensure fresh data
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser != null) {
        print(
            'Pre-emptively clearing cache for users: ${currentUser.uid} and $userId');
        _userCache.remove(currentUser.uid);
        _userCache.remove(userId);
      }

      final result = await callable.call<Map<String, dynamic>>({
        'followingId': userId,
      });

      print('Unfollow operation result: ${result.data}');

      // Force a refresh of the user data after the operation
      if (currentUser != null) {
        print('Forcing refresh of user data after unfollow operation');
        await getUserData(currentUser.uid);
        await getUserData(userId);
      }

      return result.data['success'] as bool;
    } catch (e) {
      print('Error unfollowing user $userId: $e');
      if (e is FirebaseFunctionsException) {
        switch (e.code) {
          case 'not-found':
            throw 'Not following this user';
          case 'permission-denied':
            throw 'Permission denied';
          default:
            throw 'Failed to unfollow user';
        }
      }
      rethrow;
    }
  }

  Future<bool> isFollowing(String userId) async {
    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) return false;

      print('Checking follow status: ${currentUser.uid} -> $userId');
      final followDoc = await FirebaseFirestore.instance
          .collection('follows')
          .doc('${currentUser.uid}_$userId')
          .get();

      final exists = followDoc.exists;
      print('Follow relationship exists: $exists');
      return exists;
    } catch (e) {
      print('Error checking follow status: $e');
      return false;
    }
  }
}
