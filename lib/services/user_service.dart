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
      if (!snapshot.exists) {
        return {
          'displayName': 'Unknown User',
          'avatarURL': null,
          'followersCount': 0,
          'followingCount': 0,
          'totalLikes': 0,
        };
      }
      final data = snapshot.data() as Map<String, dynamic>;
      // Update cache
      _userCache[userId] = data;
      return data;
    });
  }

  Future<bool> followUser(String userId) async {
    try {
      final functions = FirebaseFunctions.instance;
      final callable = functions.httpsCallable('followUser');
      final result = await callable.call<Map<String, dynamic>>({
        'followingId': userId,
      });

      // Clear cache for both users
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser != null) {
        _userCache.remove(currentUser.uid);
        _userCache.remove(userId);
      }

      return result.data['success'] as bool;
    } catch (e) {
      print('Error following user: $e');
      rethrow;
    }
  }

  Future<bool> unfollowUser(String userId) async {
    try {
      final functions = FirebaseFunctions.instance;
      final callable = functions.httpsCallable('unfollowUser');
      final result = await callable.call<Map<String, dynamic>>({
        'followingId': userId,
      });

      // Clear cache for both users
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser != null) {
        _userCache.remove(currentUser.uid);
        _userCache.remove(userId);
      }

      return result.data['success'] as bool;
    } catch (e) {
      print('Error unfollowing user: $e');
      rethrow;
    }
  }

  Future<bool> isFollowing(String userId) async {
    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) return false;

      final followDoc = await FirebaseFirestore.instance
          .collection('follows')
          .doc('${currentUser.uid}_$userId')
          .get();

      return followDoc.exists;
    } catch (e) {
      print('Error checking follow status: $e');
      return false;
    }
  }
}
