import 'package:cloud_firestore/cloud_firestore.dart';

class UserService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Get user data by ID
  Future<Map<String, dynamic>> getUserData(String userId) async {
    try {
      final doc = await _firestore.collection('users').doc(userId).get();
      if (doc.exists) {
        return doc.data() as Map<String, dynamic>;
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
    return _firestore
        .collection('users')
        .doc(userId)
        .snapshots()
        .map((snapshot) => snapshot.data() as Map<String, dynamic>? ?? {});
  }
}
