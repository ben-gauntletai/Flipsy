import 'dart:io';
import 'package:video_player/video_player.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:video_compress/video_compress.dart';
import '../models/video.dart';
import 'package:uuid/uuid.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

class VideoService {
  static final VideoService _instance = VideoService._internal();
  factory VideoService() => _instance;

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;
  final Map<String, Timer> _reconciliationTimers = {};
  final Map<String, int> _localLikeCounts = {};

  VideoService._internal();

  String get _currentUserId => FirebaseAuth.instance.currentUser?.uid ?? '';

  // Generate and upload thumbnail
  Future<String> generateAndUploadThumbnail(
      String userId, File videoFile) async {
    try {
      print('Generating thumbnail...');
      final thumbnailFile = await VideoCompress.getFileThumbnail(
        videoFile.path,
        quality: 50,
        position: -1, // -1 means center frame
      );

      print('Uploading thumbnail...');
      final fileName = '${const Uuid().v4()}.jpg';
      final storageRef =
          _storage.ref().child('users/$userId/thumbnails/$fileName');

      final metadata = SettableMetadata(
        contentType: 'image/jpeg',
        customMetadata: {'userId': userId},
      );

      final uploadTask = storageRef.putFile(thumbnailFile, metadata);
      final snapshot = await uploadTask;
      final thumbnailUrl = await snapshot.ref.getDownloadURL();

      print('Thumbnail uploaded successfully: $thumbnailUrl');
      return thumbnailUrl;
    } catch (e) {
      print('Error generating/uploading thumbnail: $e');
      throw Exception('Failed to generate/upload thumbnail: $e');
    }
  }

  // Upload a video file to Firebase Storage
  Future<String> uploadVideo(
    String userId,
    File videoFile, {
    Function(double)? onProgress,
    Function()? onCanceled,
  }) async {
    UploadTask? uploadTask;
    try {
      final fileName = '${const Uuid().v4()}.mp4';
      final storageRef = FirebaseStorage.instance
          .ref()
          .child('users/$userId/videos/$fileName');

      // Create metadata
      final metadata = SettableMetadata(
        contentType: 'video/mp4',
        customMetadata: {'userId': userId},
      );

      // Upload with metadata
      uploadTask = storageRef.putFile(videoFile, metadata);

      // Monitor upload progress
      uploadTask.snapshotEvents.listen((TaskSnapshot snapshot) {
        final progress = snapshot.bytesTransferred / snapshot.totalBytes;
        onProgress?.call(progress);
        print('Upload progress: ${(progress * 100).toStringAsFixed(2)}%');
      }, onError: (error) {
        print('Error in upload stream: $error');
        if (error.toString().contains('canceled')) {
          onCanceled?.call();
        }
      });

      // Wait for upload to complete and get download URL
      final snapshot = await uploadTask;
      final downloadUrl = await snapshot.ref.getDownloadURL();

      print('Video uploaded successfully: $downloadUrl');
      return downloadUrl;
    } catch (e) {
      print('Error uploading video: $e');
      // Check if the error is due to cancellation
      if (e.toString().contains('canceled')) {
        uploadTask?.cancel();
        onCanceled?.call();
        throw Exception('Upload canceled');
      }
      throw Exception('Failed to upload video: $e');
    }
  }

  // Create a new video document in Firestore
  Future<Video> createVideo({
    required String userId,
    required String videoURL,
    required double duration,
    required int width,
    required int height,
    String? description,
    File? videoFile,
    required bool allowComments,
  }) async {
    try {
      print('VideoService: Creating new video document');
      print('VideoService: User ID: $userId');
      print('VideoService: Video URL: $videoURL');

      String thumbnailURL;
      if (videoFile != null) {
        thumbnailURL = await generateAndUploadThumbnail(userId, videoFile);
      } else {
        // Fallback to a default thumbnail if no video file is provided
        thumbnailURL =
            'https://via.placeholder.com/320x480.png?text=Video+Thumbnail';
      }

      print('VideoService: Thumbnail URL: $thumbnailURL');

      // Use server timestamp for both createdAt and updatedAt
      final videoData = {
        'userId': userId,
        'videoURL': videoURL,
        'thumbnailURL': thumbnailURL,
        'description': description,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'likesCount': 0,
        'commentsCount': 0,
        'shareCount': 0,
        'duration': duration,
        'width': width,
        'height': height,
        'status': 'active',
        'allowComments': allowComments,
      };

      print('VideoService: Creating document with data: $videoData');

      final DocumentReference docRef =
          await _firestore.collection('videos').add(videoData);
      print('VideoService: Created document with ID: ${docRef.id}');

      // Wait for the server timestamp to be set by listening to the document
      DocumentSnapshot doc;
      int attempts = 0;
      const maxAttempts = 5;
      const delay = Duration(milliseconds: 200);

      do {
        await Future.delayed(delay);
        doc = await docRef.get();
        attempts++;

        final data = doc.data() as Map<String, dynamic>?;
        if (data != null) {
          print(
              'VideoService: Attempt $attempts - createdAt: ${data['createdAt']}');
        }
      } while (attempts < maxAttempts &&
          (doc.data() as Map<String, dynamic>?)?.containsKey('createdAt') !=
              true);

      if (attempts >= maxAttempts) {
        print(
            'VideoService: Warning - Server timestamp not resolved after $maxAttempts attempts');
      }

      final video = Video.fromFirestore(doc);
      print(
          'VideoService: Created video object with createdAt: ${video.createdAt}');

      return video;
    } catch (e) {
      print('VideoService: Error creating video document: $e');
      throw Exception('Failed to create video document: $e');
    }
  }

  // Get video metadata using VideoPlayerController
  Future<Map<String, dynamic>> getVideoMetadata(File videoFile) async {
    final controller = VideoPlayerController.file(videoFile);
    await controller.initialize();

    final metadata = {
      'duration': controller.value.duration.inSeconds.toDouble(),
      'width': controller.value.size.width.toInt(),
      'height': controller.value.size.height.toInt(),
    };

    await controller.dispose();
    return metadata;
  }

  // Get videos for feed (with pagination)
  Stream<List<Video>> getVideoFeed(
      {int limit = 10, DocumentSnapshot? startAfter}) {
    print('VideoService: Getting video feed with limit: $limit');
    try {
      // Create the base query
      Query query =
          _firestore.collection('videos').where('status', isEqualTo: 'active');

      // If we're paginating, add the startAfter
      if (startAfter != null) {
        print('VideoService: Using startAfter document: ${startAfter.id}');
        query = query.startAfterDocument(startAfter);
      }

      // Add ordering and limit
      query = query.orderBy('createdAt', descending: true).limit(limit);

      return query.snapshots().map((snapshot) {
        print(
            'VideoService: Got ${snapshot.docs.length} videos from Firestore');
        print(
            'VideoService: Document IDs: ${snapshot.docs.map((doc) => doc.id).join(', ')}');

        // Debug timestamp information
        for (final doc in snapshot.docs) {
          final data = doc.data() as Map<String, dynamic>;
          print('VideoService: Document ${doc.id}:');
          print('  - createdAt: ${data['createdAt']}');
          print('  - videoURL: ${data['videoURL']}');
          print('  - status: ${data['status']}');
        }

        // Use a map to ensure uniqueness and maintain order
        final Map<String, Video> uniqueVideos = {};

        for (final doc in snapshot.docs) {
          try {
            final data = doc.data() as Map<String, dynamic>;

            // Skip documents with null timestamps
            if (data['createdAt'] == null) {
              print(
                  'VideoService: Skipping doc ${doc.id} - timestamp not yet resolved');
              continue;
            }

            // Validate video URL
            if (data['videoURL'] == null ||
                data['videoURL'].toString().isEmpty) {
              print('VideoService: Skipping doc ${doc.id} - invalid video URL');
              continue;
            }

            final video = Video.fromFirestore(doc);
            uniqueVideos[doc.id] = video;
            print('VideoService: Successfully processed video ${doc.id}');
          } catch (e) {
            print('VideoService: Error parsing video doc ${doc.id}: $e');
          }
        }

        final result = uniqueVideos.values.toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

        print('VideoService: Returning ${result.length} unique videos');
        print(
            'VideoService: Video IDs in order: ${result.map((v) => v.id).join(', ')}');
        return result;
      });
    } catch (e) {
      print('VideoService: Error setting up video feed stream: $e');
      rethrow;
    }
  }

  // Get a batch of videos (non-stream version for pagination)
  Future<List<Video>> getVideoFeedBatch({
    int limit = 10,
    DocumentSnapshot? startAfter,
  }) async {
    print('VideoService: Getting video feed batch with limit: $limit');
    try {
      // Create the base query
      Query query =
          _firestore.collection('videos').where('status', isEqualTo: 'active');

      // If we're paginating, add the startAfter
      if (startAfter != null) {
        print('VideoService: Using startAfter document: ${startAfter.id}');
        query = query.startAfterDocument(startAfter);
      }

      // Add ordering and limit
      query = query.orderBy('createdAt', descending: true).limit(limit);

      final snapshot = await query.get();
      print('VideoService: Got ${snapshot.docs.length} videos from Firestore');
      print(
          'VideoService: Document IDs: ${snapshot.docs.map((doc) => doc.id).join(', ')}');

      // Debug timestamp information
      for (final doc in snapshot.docs) {
        final data = doc.data() as Map<String, dynamic>;
        print('VideoService: Document ${doc.id}:');
        print('  - createdAt: ${data['createdAt']}');
        print('  - videoURL: ${data['videoURL']}');
        print('  - status: ${data['status']}');
      }

      // Use a map to ensure uniqueness and maintain order
      final Map<String, Video> uniqueVideos = {};

      for (final doc in snapshot.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;

          // Skip documents with null timestamps
          if (data['createdAt'] == null) {
            print(
                'VideoService: Skipping doc ${doc.id} - timestamp not yet resolved');
            continue;
          }

          // Validate video URL
          if (data['videoURL'] == null || data['videoURL'].toString().isEmpty) {
            print('VideoService: Skipping doc ${doc.id} - invalid video URL');
            continue;
          }

          final video = Video.fromFirestore(doc);
          uniqueVideos[doc.id] = video;
          print('VideoService: Successfully processed video ${doc.id}');
        } catch (e) {
          print('VideoService: Error parsing video doc ${doc.id}: $e');
        }
      }

      final result = uniqueVideos.values.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

      print('VideoService: Returning ${result.length} unique videos');
      print(
          'VideoService: Video IDs in order: ${result.map((v) => v.id).join(', ')}');
      return result;
    } catch (e) {
      print('VideoService: Error getting video feed batch: $e');
      return [];
    }
  }

  // Get the document snapshot for a video by ID
  Future<DocumentSnapshot?> getLastDocument(String videoId) async {
    try {
      return await _firestore.collection('videos').doc(videoId).get();
    } catch (e) {
      print('Error getting last document: $e');
      return null;
    }
  }

  // Get videos by user
  Stream<List<Video>> getUserVideos(String userId) {
    print('VideoService: Fetching videos for user: $userId');
    try {
      return _firestore
          .collection('videos')
          .where('userId', isEqualTo: userId)
          // Temporarily remove the status filter and ordering to debug
          // .where('status', isEqualTo: 'active')
          // .orderBy('createdAt', descending: true)
          .snapshots()
          .map((snapshot) {
        print('VideoService: Got snapshot with ${snapshot.docs.length} videos');
        try {
          final videos = snapshot.docs
              .map((doc) {
                try {
                  final video = Video.fromFirestore(doc);
                  // Filter active status in memory
                  if (video.status == 'active') {
                    return video;
                  }
                  return null;
                } catch (e) {
                  print('VideoService: Error parsing video doc ${doc.id}: $e');
                  return null;
                }
              })
              .where((video) => video != null)
              .cast<Video>()
              .toList();

          // Sort in memory
          videos.sort((a, b) => b.createdAt.compareTo(a.createdAt));

          print(
              'VideoService: Successfully parsed ${videos.length} active videos');
          return videos;
        } catch (e) {
          print('VideoService: Error mapping snapshot: $e');
          rethrow;
        }
      });
    } catch (e) {
      print('VideoService: Error setting up stream: $e');
      rethrow;
    }
  }

  // Delete a video
  Future<void> deleteVideo(String videoId) async {
    try {
      // Soft delete by updating status
      await _firestore.collection('videos').doc(videoId).update({
        'status': 'deleted',
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error deleting video: $e');
      throw Exception('Failed to delete video');
    }
  }

  // Add reconciliation for video likes
  Future<void> reconcileVideoLikes(String videoId) async {
    print('\nVideoService: Starting like reconciliation for video $videoId');
    try {
      // Get actual likes count from likedVideos collection
      final likesQuery = await _firestore
          .collection('users')
          .doc(_currentUserId)
          .collection('likedVideos')
          .doc(videoId)
          .get();

      final videoDoc = await _firestore.collection('videos').doc(videoId).get();
      if (!videoDoc.exists) {
        print('VideoService: Video $videoId not found');
        return;
      }

      final actualLikeStatus = likesQuery.exists;
      final videoData = videoDoc.data()!;
      final currentLikesCount = videoData['likesCount'] as int? ?? 0;

      print('VideoService: Like status for video $videoId:');
      print('- User like status: $actualLikeStatus');
      print('- Current likes count: $currentLikesCount');

      // Store the reconciled count locally
      _localLikeCounts[videoId] = currentLikesCount;
    } catch (e) {
      print('VideoService: Error reconciling likes: $e');
    }
  }

  // Schedule reconciliation with debounce
  void _scheduleLikeReconciliation(String videoId) {
    print('VideoService: Scheduling like reconciliation for $videoId');

    // Cancel existing timer if any
    _reconciliationTimers[videoId]?.cancel();

    // Schedule new reconciliation
    _reconciliationTimers[videoId] = Timer(const Duration(seconds: 5), () {
      reconcileVideoLikes(videoId);
      _reconciliationTimers.remove(videoId);
    });
  }

  /// Likes a video and returns true if successful
  Future<bool> likeVideo(String videoId) async {
    if (_currentUserId.isEmpty) return false;

    try {
      print('VideoService: Attempting to like video $videoId');

      bool success = false;
      await _firestore.runTransaction((transaction) async {
        // Check current like status
        final userLikeRef = _firestore
            .collection('users')
            .doc(_currentUserId)
            .collection('likedVideos')
            .doc(videoId);

        final videoRef = _firestore.collection('videos').doc(videoId);

        final likeDoc = await transaction.get(userLikeRef);
        final videoDoc = await transaction.get(videoRef);

        if (!videoDoc.exists) {
          print('VideoService: Video $videoId not found');
          success = false;
          return;
        }

        if (likeDoc.exists) {
          print('VideoService: Video already liked');
          success = true;
          return;
        }

        // Add to user's liked videos
        transaction.set(userLikeRef, {
          'videoId': videoId,
          'likedAt': FieldValue.serverTimestamp(),
        });

        // Increment video likes count
        final currentLikes = (videoDoc.data()?['likesCount'] as int?) ?? 0;
        transaction.update(videoRef, {
          'likesCount': currentLikes + 1,
        });

        // Update local count
        _localLikeCounts[videoId] = currentLikes + 1;

        success = true;
      });

      if (success) {
        print('VideoService: Successfully liked video $videoId');
        _scheduleLikeReconciliation(videoId);
      }

      return success;
    } catch (e) {
      print('VideoService: Error liking video $videoId: $e');
      return false;
    }
  }

  /// Unlikes a video and returns true if successful
  Future<bool> unlikeVideo(String videoId) async {
    if (_currentUserId.isEmpty) return false;

    try {
      print('VideoService: Attempting to unlike video $videoId');

      bool success = false;
      await _firestore.runTransaction((transaction) async {
        // Check current like status
        final userLikeRef = _firestore
            .collection('users')
            .doc(_currentUserId)
            .collection('likedVideos')
            .doc(videoId);

        final videoRef = _firestore.collection('videos').doc(videoId);

        final likeDoc = await transaction.get(userLikeRef);
        final videoDoc = await transaction.get(videoRef);

        if (!videoDoc.exists) {
          print('VideoService: Video $videoId not found');
          success = false;
          return;
        }

        if (!likeDoc.exists) {
          print('VideoService: Video not liked');
          success = true;
          return;
        }

        // Remove from user's liked videos
        transaction.delete(userLikeRef);

        // Decrement video likes count
        final currentLikes = (videoDoc.data()?['likesCount'] as int?) ?? 0;
        transaction.update(videoRef, {
          'likesCount': math.max(0, currentLikes - 1),
        });

        // Update local count
        _localLikeCounts[videoId] = math.max(0, currentLikes - 1);

        success = true;
      });

      if (success) {
        print('VideoService: Successfully unliked video $videoId');
        _scheduleLikeReconciliation(videoId);
      }

      return success;
    } catch (e) {
      print('VideoService: Error unliking video $videoId: $e');
      return false;
    }
  }

  /// Checks if the current user has liked a video
  Future<bool> hasUserLikedVideo(String videoId) async {
    if (_currentUserId.isEmpty) return false;

    try {
      print('VideoService: Checking if user liked video $videoId');
      final doc = await _firestore
          .collection('users')
          .doc(_currentUserId)
          .collection('likedVideos')
          .doc(videoId)
          .get();

      return doc.exists;
    } catch (e) {
      print('VideoService: Error checking like status for video $videoId: $e');
      return false;
    }
  }

  /// Stream of the current user's like status for a video
  Stream<bool> watchUserLikeStatus(String videoId) {
    if (_currentUserId.isEmpty) {
      return Stream.value(false);
    }

    return _firestore
        .collection('users')
        .doc(_currentUserId)
        .collection('likedVideos')
        .doc(videoId)
        .snapshots()
        .map((doc) => doc.exists);
  }

  Stream<int> watchVideoCommentCount(String videoId) {
    return _firestore
        .collection('videos')
        .doc(videoId)
        .snapshots()
        .map((snapshot) => (snapshot.data()?['commentsCount'] as int?) ?? 0);
  }

  /// Stream to watch a video's like count in real-time
  Stream<int> watchVideoLikeCount(String videoId) {
    return _firestore
        .collection('videos')
        .doc(videoId)
        .snapshots()
        .map((snapshot) => (snapshot.data()?['likesCount'] as int?) ?? 0);
  }

  // Get videos from users that the current user follows
  Stream<List<Video>> getFollowingFeed({int limit = 10}) {
    print('VideoService: Getting following feed with limit: $limit');
    if (_currentUserId.isEmpty) {
      print('VideoService: No current user, returning empty stream');
      return Stream.value([]);
    }

    try {
      // First, get the list of users that the current user follows
      return _firestore
          .collection('follows')
          .where('followerId', isEqualTo: _currentUserId)
          .snapshots()
          .asyncMap((followSnapshot) async {
        print('VideoService: Got ${followSnapshot.docs.length} followed users');

        if (followSnapshot.docs.isEmpty) {
          print('VideoService: User is not following anyone');
          return [];
        }

        // Extract the IDs of followed users
        final followedUserIds = followSnapshot.docs
            .map((doc) => doc.data()['followingId'] as String)
            .toList();

        print('VideoService: Following users: $followedUserIds');

        // Get videos from followed users
        final videoQuery = await _firestore
            .collection('videos')
            .where('userId', whereIn: followedUserIds)
            .where('status', isEqualTo: 'active')
            .orderBy('createdAt', descending: true)
            .limit(limit)
            .get();

        print(
            'VideoService: Got ${videoQuery.docs.length} videos from followed users');

        final videos = videoQuery.docs
            .map((doc) {
              try {
                return Video.fromFirestore(doc);
              } catch (e) {
                print('VideoService: Error parsing video doc ${doc.id}: $e');
                return null;
              }
            })
            .where((video) => video != null)
            .cast<Video>()
            .toList();

        print(
            'VideoService: Returning ${videos.length} videos for following feed');
        return videos;
      });
    } catch (e) {
      print('VideoService: Error getting following feed: $e');
      return Stream.value([]);
    }
  }

  // Get a batch of following feed videos (for pagination)
  Future<List<Video>> getFollowingFeedBatch({
    int limit = 10,
    DocumentSnapshot? startAfter,
  }) async {
    print('VideoService: Getting following feed batch with limit: $limit');
    if (_currentUserId.isEmpty) {
      print('VideoService: No current user, returning empty list');
      return [];
    }

    try {
      // Get the list of users that the current user follows
      final followSnapshot = await _firestore
          .collection('follows')
          .where('followerId', isEqualTo: _currentUserId)
          .get();

      if (followSnapshot.docs.isEmpty) {
        print('VideoService: User is not following anyone');
        return [];
      }

      // Extract the IDs of followed users
      final followedUserIds = followSnapshot.docs
          .map((doc) => doc.data()['followingId'] as String)
          .toList();

      print('VideoService: Following users: $followedUserIds');

      // Create the base query
      Query query = _firestore
          .collection('videos')
          .where('userId', whereIn: followedUserIds)
          .where('status', isEqualTo: 'active')
          .orderBy('createdAt', descending: true);

      // If we're paginating, add the startAfter
      if (startAfter != null) {
        print('VideoService: Using startAfter document: ${startAfter.id}');
        query = query.startAfterDocument(startAfter);
      }

      query = query.limit(limit);

      final videoQuery = await query.get();
      print(
          'VideoService: Got ${videoQuery.docs.length} videos from followed users');

      final videos = videoQuery.docs
          .map((doc) {
            try {
              return Video.fromFirestore(doc);
            } catch (e) {
              print('VideoService: Error parsing video doc ${doc.id}: $e');
              return null;
            }
          })
          .where((video) => video != null)
          .cast<Video>()
          .toList();

      print(
          'VideoService: Returning ${videos.length} videos for following feed batch');
      return videos;
    } catch (e) {
      print('VideoService: Error getting following feed batch: $e');
      return [];
    }
  }

  // Get a single video by ID
  Future<Video?> getVideoById(String videoId) async {
    try {
      print('VideoService: Fetching video by ID: $videoId');
      final doc = await _firestore.collection('videos').doc(videoId).get();

      if (!doc.exists) {
        print('VideoService: Video not found: $videoId');
        return null;
      }

      final video = Video.fromFirestore(doc);
      print('VideoService: Successfully fetched video: ${video.id}');
      return video;
    } catch (e) {
      print('VideoService: Error fetching video by ID: $e');
      return null;
    }
  }
}
