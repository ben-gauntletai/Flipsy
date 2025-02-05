import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

class UserService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Helper method to get follow document ID
  String _getFollowDocId(String followerId, String followingId) {
    return '${followerId}_$followingId';
  }

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
          .doc(_getFollowDocId(currentUser.uid, userId))
          .get();

      final exists = followDoc.exists;
      print('Follow relationship exists: $exists');
      return exists;
    } catch (e) {
      print('Error checking follow status: $e');
      return false;
    }
  }

  // Add real-time follow status stream
  Stream<bool> watchFollowStatus(String userId) {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return Stream.value(false);

    print('Watching follow status: ${currentUser.uid} -> $userId');
    return FirebaseFirestore.instance
        .collection('follows')
        .doc(_getFollowDocId(currentUser.uid, userId))
        .snapshots()
        .map((doc) {
      final exists = doc.exists;
      print('Follow status update - exists: $exists');
      return exists;
    });
  }

  // Add method to watch follows list
  Stream<List<String>> watchFollowsList(String userId,
      {required bool isFollowers}) {
    print('\n========== FOLLOWS LIST DEBUG ==========');
    print(
        'Watching ${isFollowers ? 'followers' : 'following'} list for user: $userId');

    // Get current user for logging
    final currentUser = FirebaseAuth.instance.currentUser;
    print('Current user: ${currentUser?.uid}');

    // Log the query we're about to make
    final queryField = isFollowers ? 'followingId' : 'followerId';
    final returnField = isFollowers ? 'followerId' : 'followingId';

    print('\nQuery setup:');
    print('- Collection: follows');
    print('- Where $queryField = $userId');
    print('- Will return $returnField values');
    print('- Ordered by createdAt descending');

    final query =
        _firestore.collection('follows').where(queryField, isEqualTo: userId);

    return query.snapshots().map((snapshot) {
      print('\nSnapshot received at ${DateTime.now()}:');
      print('- Number of documents: ${snapshot.docs.length}');

      if (snapshot.docs.isEmpty) {
        print('- No documents found in snapshot');
        return <String>[];
      }

      print('\nProcessing documents:');
      final follows = snapshot.docs.map((doc) {
        final data = doc.data();
        print('\nDocument ${doc.id}:');
        print('- followerId: ${data['followerId']}');
        print('- followingId: ${data['followingId']}');
        print('- createdAt: ${data['createdAt']}');

        final returnId = data[returnField] as String;
        print('- Will return: $returnId');
        return returnId;
      }).toList();

      // Sort by createdAt if available
      follows.sort((a, b) {
        final docA =
            snapshot.docs.firstWhere((doc) => doc.data()[returnField] == a);
        final docB =
            snapshot.docs.firstWhere((doc) => doc.data()[returnField] == b);
        final timeA =
            (docA.data()['createdAt'] as Timestamp?)?.millisecondsSinceEpoch ??
                0;
        final timeB =
            (docB.data()['createdAt'] as Timestamp?)?.millisecondsSinceEpoch ??
                0;
        return timeB.compareTo(timeA); // Descending order
      });

      print('\nFinal result:');
      print('- Number of IDs: ${follows.length}');
      print('- IDs in order: $follows');
      print('=======================================\n');

      return follows;
    }).handleError((error) {
      print('\nERROR in watchFollowsList:');
      print('- Error details: $error');
      print('=======================================\n');
      return <String>[];
    });
  }
}
