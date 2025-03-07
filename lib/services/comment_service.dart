import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:rxdart/rxdart.dart';
import 'dart:async';
import '../models/comment.dart';

class CommentService {
  static final CommentService _instance = CommentService._internal();
  factory CommentService() => _instance;

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final String _currentUserId;
  final Map<String, BehaviorSubject<List<Comment>>> _commentSubjects = {};
  final Map<String, StreamSubscription<QuerySnapshot>> _subscriptions = {};

  CommentService._internal()
      : _currentUserId = FirebaseAuth.instance.currentUser?.uid ?? '';

  void _disposeSubject(String videoId) {
    print('CommentService: Disposing resources for video $videoId');

    // Cancel the Firestore subscription
    final subscription = _subscriptions[videoId];
    if (subscription != null) {
      subscription.cancel();
      _subscriptions.remove(videoId);
    }

    // Close the comment subject
    final commentSubject = _commentSubjects[videoId];
    if (commentSubject != null && !commentSubject.isClosed) {
      commentSubject.close();
      _commentSubjects.remove(videoId);
    }
  }

  Stream<List<Comment>> watchComments(String videoId) {
    print('CommentService: Starting to watch comments for video $videoId');

    if (_commentSubjects.containsKey(videoId) &&
        !_commentSubjects[videoId]!.isClosed) {
      print('CommentService: Returning existing subject for video $videoId');
      return _commentSubjects[videoId]!.stream;
    }

    print('CommentService: Creating new subject for video $videoId');
    final subject = BehaviorSubject<List<Comment>>();
    _commentSubjects[videoId] = subject;

    final subscription = _firestore
        .collection('videos')
        .doc(videoId)
        .collection('comments')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .listen(
      (snapshot) async {
        if (subject.isClosed) return;

        print(
            'CommentService: Processing ${snapshot.docs.length} comments for video $videoId');

        try {
          // First, create a map of all comments
          final Map<String, Comment> commentsMap = {};
          final Map<String, List<Comment>> repliesMap = {};

          // Process all comments first
          for (var doc in snapshot.docs) {
            final comment = Comment.fromMap(doc.id, doc.data());
            commentsMap[doc.id] = comment;

            // Initialize replies list for parent comments
            if (comment.replyToId == null) {
              repliesMap[comment.id] = [];
            }
          }

          // Organize replies under their parent comments
          for (var comment in commentsMap.values) {
            if (comment.replyToId != null &&
                repliesMap.containsKey(comment.replyToId)) {
              repliesMap[comment.replyToId]!.add(comment);
            }
          }

          // Create final sorted list
          final List<Comment> organizedComments = [];

          // Add parent comments first
          final parentComments = commentsMap.values
              .where((c) => c.replyToId == null)
              .toList()
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

          // For each parent comment, add it and its replies
          for (var parent in parentComments) {
            organizedComments.add(parent);
            // Sort replies by creation time and add them
            final replies = repliesMap[parent.id] ?? [];
            replies.sort((a, b) => a.createdAt.compareTo(b.createdAt));
            organizedComments.addAll(replies);
          }

          print(
              'CommentService: Emitting ${organizedComments.length} organized comments');
          subject.add(organizedComments);
        } catch (e) {
          print('CommentService: Error processing comments: $e');
          if (!subject.isClosed) {
            subject.addError(e);
          }
        }
      },
      onError: (error) {
        print('CommentService: Error in comment stream: $error');
        if (!subject.isClosed) {
          subject.addError(error);
        }
      },
    );

    _subscriptions[videoId] = subscription;
    return subject.stream;
  }

  void disposeVideo(String videoId) {
    _disposeSubject(videoId);
  }

  // Clean up all resources
  void dispose() {
    print('CommentService: Disposing all resources');
    for (var videoId in _commentSubjects.keys.toList()) {
      _disposeSubject(videoId);
    }
  }

  // Add a new comment
  Future<void> addComment(String videoId, String text,
      {String? replyToId}) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('User must be logged in to comment');

    try {
      final commentRef = _firestore
          .collection('videos')
          .doc(videoId)
          .collection('comments')
          .doc();

      // Set depth to 1 for replies, 0 for parent comments
      final depth = replyToId != null ? 1 : 0;

      final comment = Comment(
        id: commentRef.id,
        userId: user.uid,
        videoId: videoId,
        text: text,
        createdAt: DateTime.now(),
        likesCount: 0,
        replyToId: replyToId,
        depth: depth,
        replyCount: 0,
      );

      // Let the cloud function handle all the counting
      await commentRef.set(comment.toMap());

      // Try to create notification separately
      if (replyToId != null) {
        try {
          final parentCommentRef = _firestore
              .collection('videos')
              .doc(videoId)
              .collection('comments')
              .doc(replyToId);

          final parentComment = await parentCommentRef.get();
          if (!parentComment.exists) {
            throw Exception('Parent comment not found');
          }

          final parentData = parentComment.data();
          if (parentData?['depth'] != 0) {
            throw Exception('Cannot reply to a reply');
          }

          final parentUserId = parentData?['userId'] as String?;
          if (parentUserId != null && parentUserId != user.uid) {
            await _firestore.collection('notifications').add({
              'type': 'comment_reply',
              'recipientId': parentUserId,
              'senderId': user.uid,
              'videoId': videoId,
              'commentId': commentRef.id,
              'createdAt': FieldValue.serverTimestamp(),
              'read': false,
            });
          }
        } catch (e) {
          print('Warning: Failed to create notification: $e');
        }
      }
    } catch (e) {
      print('Error adding comment: $e');
      rethrow;
    }
  }

  // Delete a comment
  Future<void> deleteComment(String videoId, String commentId) async {
    try {
      // Let the cloud function handle all the counting
      await _firestore
          .collection('videos')
          .doc(videoId)
          .collection('comments')
          .doc(commentId)
          .delete();
    } catch (e) {
      print('Error deleting comment: $e');
      rethrow;
    }
  }

  // Like a comment
  Future<bool> likeComment(String videoId, String commentId) async {
    if (_currentUserId.isEmpty) return false;

    try {
      final likeRef = _firestore
          .collection('videos')
          .doc(videoId)
          .collection('comments')
          .doc(commentId)
          .collection('likes')
          .doc(_currentUserId);

      final likeDoc = await likeRef.get();
      if (likeDoc.exists) {
        print('CommentService: User has already liked this comment');
        return false;
      }

      await likeRef.set({
        'userId': _currentUserId,
        'createdAt': FieldValue.serverTimestamp(),
      });

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
      final likeRef = _firestore
          .collection('videos')
          .doc(videoId)
          .collection('comments')
          .doc(commentId)
          .collection('likes')
          .doc(_currentUserId);

      final likeDoc = await likeRef.get();
      if (!likeDoc.exists) {
        print('CommentService: User has not liked this comment');
        return false;
      }

      await likeRef.delete();
      return true;
    } catch (e) {
      print('CommentService: Error unliking comment: $e');
      return false;
    }
  }

  // Check if user has liked a comment and get like count
  Stream<Map<String, dynamic>> watchCommentLikeInfo(
      String videoId, String commentId) {
    if (_currentUserId.isEmpty) {
      return Stream.value({'isLiked': false, 'likesCount': 0});
    }

    final likesCollection = _firestore
        .collection('videos')
        .doc(videoId)
        .collection('comments')
        .doc(commentId)
        .collection('likes');

    return likesCollection.snapshots().map((snapshot) {
      final likesCount = snapshot.docs.length;
      final isLiked = snapshot.docs.any((doc) => doc.id == _currentUserId);

      // Update the comment's likesCount in Firestore
      _firestore
          .collection('videos')
          .doc(videoId)
          .collection('comments')
          .doc(commentId)
          .update({'likesCount': likesCount});

      return {
        'isLiked': isLiked,
        'likesCount': likesCount,
      };
    });
  }

  // Add a stream to watch the video's comment count
  Stream<int> watchCommentCount(String videoId) {
    return watchComments(videoId).map((comments) {
      final parentComments = comments.where((c) => c.replyToId == null).length;
      print(
          'CommentService: Counted $parentComments parent comments for video $videoId');
      return parentComments;
    });
  }

  // Add a stream to watch a comment's reply count
  Stream<int> watchCommentReplyCount(String videoId, String commentId) {
    return _firestore
        .collection('videos')
        .doc(videoId)
        .collection('comments')
        .doc(commentId)
        .snapshots()
        .map((snapshot) => (snapshot.data()?['replyCount'] as int?) ?? 0);
  }
}
