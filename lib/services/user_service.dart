import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:rxdart/rxdart.dart';
import 'dart:async';
import 'dart:math' as math;

class UserService {
  static final UserService _instance = UserService._internal();
  factory UserService() => _instance;

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final Map<String, Map<String, dynamic>> _userCache = {};
  final Map<String, Timer> _reconciliationTimers = {};

  UserService._internal();

  String get _currentUserId => FirebaseAuth.instance.currentUser?.uid ?? '';

  // Helper method to get follow document ID
  String _getFollowDocId(String followerId, String followingId) {
    return '${followerId}_$followingId';
  }

  // New method to reconcile follow counts
  Future<void> reconcileFollowCounts(String userId) async {
    print('\nUserService: Starting count reconciliation for user $userId');
    try {
      // Get actual follower count from follows collection
      final followersQuery = await _firestore
          .collection('follows')
          .where('followingId', isEqualTo: userId)
          .get();

      // Get actual following count
      final followingQuery = await _firestore
          .collection('follows')
          .where('followerId', isEqualTo: userId)
          .get();

      // Get actual total likes from videos
      final videosQuery = await _firestore
          .collection('videos')
          .where('userId', isEqualTo: userId)
          .where('status', isEqualTo: 'active')
          .get();

      int totalLikes = 0;
      for (var doc in videosQuery.docs) {
        totalLikes += (doc.data()['likesCount'] as int?) ?? 0;
      }

      final actualCounts = {
        'followersCount': followersQuery.docs.length,
        'followingCount': followingQuery.docs.length,
        'totalLikes': totalLikes,
      };

      print('UserService: Actual counts for $userId:');
      print('- Followers: ${actualCounts['followersCount']}');
      print('- Following: ${actualCounts['followingCount']}');
      print('- Total Likes: ${actualCounts['totalLikes']}');

      // Get current counts
      final userDoc = await _firestore.collection('users').doc(userId).get();
      final currentCounts = {
        'followersCount': userDoc.data()?['followersCount'] ?? 0,
        'followingCount': userDoc.data()?['followingCount'] ?? 0,
        'totalLikes': userDoc.data()?['totalLikes'] ?? 0,
      };

      // Check if counts are different
      if (currentCounts['followersCount'] != actualCounts['followersCount'] ||
          currentCounts['followingCount'] != actualCounts['followingCount'] ||
          currentCounts['totalLikes'] != actualCounts['totalLikes']) {
        print('UserService: Counts mismatch detected for $userId:');
        print('Current counts: $currentCounts');
        print('Actual counts: $actualCounts');

        // Update user document with actual counts
        await _firestore.collection('users').doc(userId).update(actualCounts);

        // Update cache
        if (_userCache.containsKey(userId)) {
          _userCache[userId] = {
            ..._userCache[userId]!,
            ...actualCounts,
          };
        }

        print('UserService: Successfully updated counts for $userId');
      } else {
        print('UserService: Counts are already accurate for $userId');
      }
    } catch (e) {
      print('UserService: Error reconciling counts: $e');
    }
  }

  // Schedule reconciliation with debounce
  void _scheduleReconciliation(String userId) {
    print('UserService: Scheduling reconciliation for $userId');

    // Cancel existing timer if any
    _reconciliationTimers[userId]?.cancel();

    // Schedule new reconciliation
    _reconciliationTimers[userId] = Timer(const Duration(seconds: 5), () {
      reconcileFollowCounts(userId);
      _reconciliationTimers.remove(userId);
    });
  }

  // Real-time count tracking
  Stream<Map<String, int>> watchUserCounts(String userId) {
    print('UserService: Starting to watch counts for $userId');

    // Watch followers
    final followersStream = _firestore
        .collection('follows')
        .where('followingId', isEqualTo: userId)
        .snapshots()
        .map((snap) => snap.docs.length);

    // Watch following
    final followingStream = _firestore
        .collection('follows')
        .where('followerId', isEqualTo: userId)
        .snapshots()
        .map((snap) => snap.docs.length);

    // Watch total likes by watching all user's videos
    final totalLikesStream = _firestore
        .collection('videos')
        .where('userId', isEqualTo: userId)
        .where('status', isEqualTo: 'active')
        .snapshots()
        .map((snap) {
      int totalLikes = 0;
      for (var doc in snap.docs) {
        totalLikes += (doc.data()['likesCount'] as int?) ?? 0;
      }
      print('UserService: Calculated total likes for $userId: $totalLikes');
      return totalLikes;
    });

    // Combine all streams
    return Rx.combineLatest3(followersStream, followingStream, totalLikesStream,
        (followers, following, totalLikes) {
      final counts = {
        'followersCount': followers,
        'followingCount': following,
        'totalLikes': totalLikes,
      };
      print('UserService: New counts for $userId: $counts');
      return counts;
    });
  }

  // Modified followUser method with optimistic updates
  Future<bool> followUser(String userId) async {
    print('\nUserService: Starting followUser');
    print('UserService: Current user ID: $_currentUserId');
    print('UserService: Target user ID: $userId');

    if (_currentUserId.isEmpty) {
      print('UserService: No current user ID');
      return false;
    }

    // Prevent self-following
    if (_currentUserId == userId) {
      print('UserService: Cannot follow yourself');
      return false;
    }

    try {
      // Optimistically update cache for target user
      if (_userCache.containsKey(userId)) {
        _userCache[userId] = {
          ..._userCache[userId]!,
          'followersCount': (_userCache[userId]!['followersCount'] ?? 0) + 1,
        };
      }

      // Optimistically update cache for current user
      if (_userCache.containsKey(_currentUserId)) {
        _userCache[_currentUserId] = {
          ..._userCache[_currentUserId]!,
          'followingCount':
              (_userCache[_currentUserId]!['followingCount'] ?? 0) + 1,
        };
      }

      print('UserService: Following user: $_currentUserId -> $userId');
      final batch = _firestore.batch();

      // Create follow document
      final followDoc = _firestore
          .collection('follows')
          .doc(_getFollowDocId(_currentUserId, userId));
      batch.set(followDoc, {
        'followerId': _currentUserId,
        'followingId': userId,
        'createdAt': FieldValue.serverTimestamp(),
      });

      // Create notification
      final notificationRef = _firestore.collection('notifications').doc();
      batch.set(notificationRef, {
        'userId': userId,
        'type': 'follow',
        'sourceUserId': _currentUserId,
        'createdAt': FieldValue.serverTimestamp(),
        'read': false,
      });

      await batch.commit();
      print('UserService: Successfully followed user and created notification');

      // Schedule reconciliation for both users
      _scheduleReconciliation(userId);
      _scheduleReconciliation(_currentUserId);

      return true;
    } catch (e) {
      print('UserService: Error following user: $e');

      // Revert optimistic updates on failure
      if (_userCache.containsKey(userId)) {
        _userCache[userId] = {
          ..._userCache[userId]!,
          'followersCount': (_userCache[userId]!['followersCount'] ?? 1) - 1,
        };
      }

      if (_userCache.containsKey(_currentUserId)) {
        _userCache[_currentUserId] = {
          ..._userCache[_currentUserId]!,
          'followingCount':
              (_userCache[_currentUserId]!['followingCount'] ?? 1) - 1,
        };
      }

      return false;
    }
  }

  // Modified unfollowUser method with optimistic updates
  Future<bool> unfollowUser(String userId) async {
    print('\nUserService: Starting unfollowUser');
    print('UserService: Current user ID: $_currentUserId');
    print('UserService: Target user ID: $userId');

    if (_currentUserId.isEmpty) {
      print('UserService: No current user ID');
      return false;
    }

    try {
      // Optimistically update cache for target user
      if (_userCache.containsKey(userId)) {
        _userCache[userId] = {
          ..._userCache[userId]!,
          'followersCount': math.max<int>(
              0, (_userCache[userId]!['followersCount'] ?? 1) - 1),
        };
      }

      // Optimistically update cache for current user
      if (_userCache.containsKey(_currentUserId)) {
        _userCache[_currentUserId] = {
          ..._userCache[_currentUserId]!,
          'followingCount': math.max<int>(
              0, (_userCache[_currentUserId]!['followingCount'] ?? 1) - 1),
        };
      }

      final functions = FirebaseFunctions.instance;
      final callable = functions.httpsCallable('unfollowUser');

      final result = await callable.call<Map<String, dynamic>>({
        'followingId': userId,
      });

      print('UserService: Unfollow operation result: ${result.data}');

      // Schedule reconciliation for both users
      _scheduleReconciliation(userId);
      _scheduleReconciliation(_currentUserId);

      final success = result.data['success'] as bool;

      if (!success) {
        // Revert optimistic updates on failure
        if (_userCache.containsKey(userId)) {
          _userCache[userId] = {
            ..._userCache[userId]!,
            'followersCount': (_userCache[userId]!['followersCount'] ?? 0) + 1,
          };
        }

        if (_userCache.containsKey(_currentUserId)) {
          _userCache[_currentUserId] = {
            ..._userCache[_currentUserId]!,
            'followingCount':
                (_userCache[_currentUserId]!['followingCount'] ?? 0) + 1,
          };
        }
      }

      return success;
    } catch (e) {
      print('UserService: Error unfollowing user: $e');

      // Revert optimistic updates on error
      if (_userCache.containsKey(userId)) {
        _userCache[userId] = {
          ..._userCache[userId]!,
          'followersCount': (_userCache[userId]!['followersCount'] ?? 0) + 1,
        };
      }

      if (_userCache.containsKey(_currentUserId)) {
        _userCache[_currentUserId] = {
          ..._userCache[_currentUserId]!,
          'followingCount':
              (_userCache[_currentUserId]!['followingCount'] ?? 0) + 1,
        };
      }

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
