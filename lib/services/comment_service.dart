import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/comment.dart';

class CommentService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final String _currentUserId;

  CommentService()
      : _currentUserId = FirebaseAuth.instance.currentUser?.uid ?? '';

  // Get comments for a video
  Stream<List<Comment>> watchComments(String videoId) {
    return _firestore
        .collection('videos')
        .doc(videoId)
        .collection('comments')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => Comment.fromMap(doc.id, doc.data()))
            .toList());
  }

  // Add a new comment
  Future<void> addComment(String videoId, String text,
      {String? replyToId}) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('User must be logged in to comment');

    final batch = _firestore.batch();
    final commentRef = _firestore
        .collection('videos')
        .doc(videoId)
        .collection('comments')
        .doc();

    int depth = 0;
    if (replyToId != null) {
      final parentComment = await _firestore
          .collection('videos')
          .doc(videoId)
          .collection('comments')
          .doc(replyToId)
          .get();

      if (parentComment.exists) {
        final parentData = parentComment.data();
        depth = (parentData?['depth'] as int? ?? 0) + 1;
        // Limit nesting depth to 2 levels
        if (depth > 2) depth = 2;
      }
    }

    final comment = Comment(
      id: commentRef.id,
      userId: user.uid,
      videoId: videoId,
      text: text,
      createdAt: DateTime.now(),
      likesCount: 0,
      replyToId: replyToId,
      depth: depth,
    );

    batch.set(commentRef, comment.toMap());

    // Update video's comment count
    final videoRef = _firestore.collection('videos').doc(videoId);
    batch.update(videoRef, {
      'commentsCount': FieldValue.increment(1),
    });

    // If this is a reply, update parent comment's reply count
    if (replyToId != null) {
      final parentCommentRef = _firestore
          .collection('videos')
          .doc(videoId)
          .collection('comments')
          .doc(replyToId);

      batch.update(parentCommentRef, {
        'replyCount': FieldValue.increment(1),
      });

      // Create notification for reply
      final parentComment = await parentCommentRef.get();
      if (parentComment.exists) {
        final parentUserId = parentComment.data()?['userId'] as String?;
        if (parentUserId != null && parentUserId != user.uid) {
          final notificationRef = _firestore.collection('notifications').doc();
          batch.set(notificationRef, {
            'type': 'comment_reply',
            'recipientId': parentUserId,
            'senderId': user.uid,
            'videoId': videoId,
            'commentId': commentRef.id,
            'createdAt': FieldValue.serverTimestamp(),
            'read': false,
          });
        }
      }
    }

    await batch.commit();
  }

  // Delete a comment
  Future<void> deleteComment(String videoId, String commentId) async {
    try {
      final batch = _firestore.batch();
      final commentRef = _firestore
          .collection('videos')
          .doc(videoId)
          .collection('comments')
          .doc(commentId);

      final comment = await commentRef.get();
      final commentData = comment.data();

      if (commentData == null) return;

      batch.delete(commentRef);

      // Decrement comment count on video
      final videoRef = _firestore.collection('videos').doc(videoId);
      batch.update(videoRef, {
        'commentsCount': FieldValue.increment(-1),
      });

      // If this is a reply, decrement reply count on parent comment
      final replyToId = commentData['replyToId'] as String?;
      if (replyToId != null) {
        final parentCommentRef = _firestore
            .collection('videos')
            .doc(videoId)
            .collection('comments')
            .doc(replyToId);
        batch.update(parentCommentRef, {
          'replyCount': FieldValue.increment(-1),
        });
      }

      await batch.commit();
    } catch (e) {
      print('CommentService: Error deleting comment: $e');
      rethrow;
    }
  }

  // Like a comment
  Future<bool> likeComment(String videoId, String commentId) async {
    if (_currentUserId.isEmpty) return false;

    try {
      final batch = _firestore.batch();

      // Add to comment's likes subcollection
      final likeRef = _firestore
          .collection('videos')
          .doc(videoId)
          .collection('comments')
          .doc(commentId)
          .collection('likes')
          .doc(_currentUserId);

      batch.set(likeRef, {
        'userId': _currentUserId,
        'createdAt': FieldValue.serverTimestamp(),
      });

      // Increment comment's like count
      final commentRef = _firestore
          .collection('videos')
          .doc(videoId)
          .collection('comments')
          .doc(commentId);
      batch.update(commentRef, {
        'likesCount': FieldValue.increment(1),
      });

      await batch.commit();
      return true;
    } catch (e) {
      print('CommentService: Error liking comment: $e');
      return false;
    }
  }

  // Unlike a comment
  Future<bool> unlikeComment(String videoId, String commentId) async {
    if (_currentUserId.isEmpty) return false;

    try {
      final batch = _firestore.batch();

      // Remove from comment's likes subcollection
      final likeRef = _firestore
          .collection('videos')
          .doc(videoId)
          .collection('comments')
          .doc(commentId)
          .collection('likes')
          .doc(_currentUserId);

      batch.delete(likeRef);

      // Decrement comment's like count
      final commentRef = _firestore
          .collection('videos')
          .doc(videoId)
          .collection('comments')
          .doc(commentId);
      batch.update(commentRef, {
        'likesCount': FieldValue.increment(-1),
      });

      await batch.commit();
      return true;
    } catch (e) {
      print('CommentService: Error unliking comment: $e');
      return false;
    }
  }

  // Check if user has liked a comment
  Stream<bool> watchCommentLikeStatus(String videoId, String commentId) {
    if (_currentUserId.isEmpty) {
      return Stream.value(false);
    }

    return _firestore
        .collection('videos')
        .doc(videoId)
        .collection('comments')
        .doc(commentId)
        .collection('likes')
        .doc(_currentUserId)
        .snapshots()
        .map((doc) => doc.exists);
  }
}
