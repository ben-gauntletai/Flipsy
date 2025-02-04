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
  final Map<String, BehaviorSubject<int>> _commentCountSubjects = {};

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

    // Close the count subject
    final countSubject = _commentCountSubjects[videoId];
    if (countSubject != null && !countSubject.isClosed) {
      countSubject.close();
      _commentCountSubjects.remove(videoId);
    }
  }

  Stream<List<Comment>> watchComments(String videoId) {
    // Return existing subject if it exists and isn't closed
    if (_commentSubjects.containsKey(videoId) &&
        !_commentSubjects[videoId]!.isClosed) {
      print('CommentService: Returning existing subject for video $videoId');
      return _commentSubjects[videoId]!.stream;
    }

    print('CommentService: Creating new subject for video $videoId');

    // Create a new BehaviorSubject
    final subject = BehaviorSubject<List<Comment>>();
    _commentSubjects[videoId] = subject;

    // Set up the Firestore stream
    final subscription = _firestore
        .collection('videos')
        .doc(videoId)
        .collection('comments')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .listen(
      (snapshot) {
        if (subject.isClosed) return; // Skip if subject is closed

        print(
            'CommentService: Processing snapshot with ${snapshot.docs.length} comments for video $videoId');

        final List<Comment> comments = [];
        final Set<String> processedIds = {};

        for (var doc in snapshot.docs) {
          if (!processedIds.contains(doc.id)) {
            processedIds.add(doc.id);
            comments.add(Comment.fromMap(doc.id, doc.data()));
          }
        }

        // Sort comments
        comments.sort((a, b) {
          if ((a.replyToId == null) != (b.replyToId == null)) {
            return a.replyToId == null ? -1 : 1;
          }

          if (a.replyToId == b.replyToId) {
            return b.createdAt.compareTo(a.createdAt);
          }

          return a.depth.compareTo(b.depth);
        });

        print(
            'CommentService: Adding ${comments.length} comments to subject for video $videoId');
        subject.add(comments);
      },
      onError: (error) {
        print('CommentService: Error in stream for video $videoId: $error');
        if (!subject.isClosed) {
          subject.addError(error);
        }
      },
    );

    // Store the subscription
    _subscriptions[videoId] = subscription;

    // Return the subject's stream with distinct operator
    return subject.stream.distinct((previous, next) {
      if (previous.length != next.length) return false;
      for (int i = 0; i < previous.length; i++) {
        if (previous[i].id != next[i].id) return false;
      }
      return true;
    });
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

  Stream<int> watchCommentCount(String videoId) {
    // Return existing subject if it exists and isn't closed
    if (_commentCountSubjects.containsKey(videoId) &&
        !_commentCountSubjects[videoId]!.isClosed) {
      print(
          'CommentService: Returning existing comment count subject for video $videoId');
      return _commentCountSubjects[videoId]!.stream;
    }

    print(
        'CommentService: Creating new comment count subject for video $videoId');

    // Create a new BehaviorSubject for comment count
    final subject = BehaviorSubject<int>();
    _commentCountSubjects[videoId] = subject;

    // Watch the comments collection for this video
    _firestore
        .collection('videos')
        .doc(videoId)
        .collection('comments')
        .snapshots()
        .listen(
      (snapshot) {
        if (!subject.isClosed) {
          print(
              'CommentService: Updating comment count for video $videoId: ${snapshot.docs.length}');
          subject.add(snapshot.docs.length);
        }
      },
      onError: (error) {
        print('CommentService: Error watching comment count: $error');
        if (!subject.isClosed) {
          subject.addError(error);
        }
      },
    );

    return subject.stream.distinct();
  }
}
