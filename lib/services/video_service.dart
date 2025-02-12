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
import '../models/video_filter.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../models/collection.dart';
import 'video_cache_service.dart';
import 'package:flutter/foundation.dart';

class VideoService {
  static final VideoService _instance = VideoService._internal();
  factory VideoService() => _instance;

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;
  final FirebaseFunctions _functions = FirebaseFunctions.instance;
  final Map<String, Timer> _reconciliationTimers = {};
  final Map<String, int> _localLikeCounts = {};
  static const int _maxQueryLimit = 50;
  final Map<String, List<Video>> _queryCache = {};
  final Map<String, DateTime> _queryCacheTimestamps = {};
  static const Duration _cacheDuration = Duration(minutes: 5);
  final Map<int, VideoPlayerController> _controllers = {};
  final Map<int, String> _controllerUrls = {};
  final Map<int, Completer<void>> _initializationCompleters = {};
  final Map<int, bool> _initializationStarted = {};
  final Set<int> _disposingControllers = {};

  VideoService._internal();

  String get _currentUserId => FirebaseAuth.instance.currentUser?.uid ?? '';

  // Generate and upload thumbnail
  Future<String> generateAndUploadThumbnail(
      String userId, File videoFile) async {
    try {
      debugPrint('VideoService: Generating thumbnail...');
      debugPrint('VideoService: Current user: ${_currentUserId}');
      debugPrint('VideoService: Target user: $userId');
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

  // Private method to handle video file upload
  Future<String> _uploadVideoFile(
    File videoFile,
    String userId, {
    Function(double)? onProgress,
  }) async {
    try {
      final fileName = '${const Uuid().v4()}.mp4';
      final storageRef = _storage.ref().child('users/$userId/videos/$fileName');

      // Create metadata
      final metadata = SettableMetadata(
        contentType: 'video/mp4',
        customMetadata: {'userId': userId},
      );

      // Upload with metadata
      final uploadTask = storageRef.putFile(videoFile, metadata);

      // Monitor upload progress
      uploadTask.snapshotEvents.listen((TaskSnapshot snapshot) {
        final progress = snapshot.bytesTransferred / snapshot.totalBytes;
        onProgress?.call(progress);
        print('Upload progress: ${(progress * 100).toStringAsFixed(2)}%');
      }, onError: (error) {
        print('Error in upload stream: $error');
      });

      // Wait for upload to complete and get download URL
      final snapshot = await uploadTask;
      final downloadUrl = await snapshot.ref.getDownloadURL();

      print('Video file uploaded successfully: $downloadUrl');
      return downloadUrl;
    } catch (e) {
      print('Error uploading video file: $e');
      throw Exception('Failed to upload video file: $e');
    }
  }

  // Upload a video file to Firebase Storage
  Future<String> uploadVideo({
    required File videoFile,
    required String userId,
    Function(double)? onProgress,
    String? description,
    bool allowComments = true,
    String privacy = 'everyone',
    int spiciness = 0,
  }) async {
    try {
      print('VideoService: Starting video upload');

      // Upload video file directly without compression
      final videoURL = await _uploadVideoFile(
        videoFile,
        userId,
        onProgress: onProgress,
      );
      print('VideoService: Video uploaded successfully: $videoURL');

      // Generate and upload thumbnail
      print('VideoService: Generating and uploading thumbnail');
      final thumbnailURL = await generateAndUploadThumbnail(userId, videoFile);
      print('VideoService: Thumbnail uploaded successfully: $thumbnailURL');

      return videoURL;
    } catch (e) {
      print('VideoService: Error in upload process: $e');
      rethrow;
    }
  }

  Future<Video> createVideoDocument({
    required String userId,
    required String videoURL,
    required double duration,
    required int width,
    required int height,
    String? description,
    File? videoFile,
    bool allowComments = true,
    String privacy = 'everyone',
    int spiciness = 0,
    double budget = 0.0,
    int calories = 0,
    int prepTimeMinutes = 0,
  }) async {
    try {
      print('VideoService: Creating video document');
      print('VideoService: Video URL: $videoURL');
      print('VideoService: User ID: $userId');
      print('VideoService: Dimensions: ${width}x$height');
      print('VideoService: Duration: $duration seconds');
      print('VideoService: Privacy: $privacy');
      print('VideoService: Description: $description');
      print('VideoService: Video file exists: ${videoFile != null}');

      // Generate and upload thumbnail if videoFile is provided
      String thumbnailURL = '';
      if (videoFile != null) {
        print('VideoService: Generating and uploading thumbnail');
        thumbnailURL = await generateAndUploadThumbnail(userId, videoFile);
        print('VideoService: Thumbnail uploaded successfully: $thumbnailURL');
      }

      // Extract hashtags from description
      final List<String> hashtags = Video.extractHashtags(description);
      print('VideoService: Extracted hashtags: $hashtags');

      // Generate tags for filtering
      final tags = Video.generateTags(
        budget: budget,
        calories: calories,
        prepTimeMinutes: prepTimeMinutes,
        spiciness: spiciness,
        hashtags: hashtags,
      );
      print('VideoService: Generated tags: $tags');

      // Use current timestamp for immediate feed update
      final now = DateTime.now();

      final videoDoc = await _firestore.collection('videos').add({
        'userId': userId,
        'videoURL': videoURL,
        'thumbnailURL': thumbnailURL,
        'description': description,
        'createdAt': now,
        'updatedAt': now,
        'likesCount': 0,
        'commentsCount': 0,
        'shareCount': 0,
        'bookmarkCount': 0,
        'duration': duration,
        'width': width,
        'height': height,
        'status': 'active',
        'allowComments': allowComments,
        'privacy': privacy,
        'spiciness': spiciness,
        'budget': budget,
        'calories': calories,
        'prepTimeMinutes': prepTimeMinutes,
        'hashtags': hashtags,
        'tags': tags,
        'processingStatus': 'pending',
        'analysis': null,
      });

      print('VideoService: Created document with ID: ${videoDoc.id}');

      // Update with server timestamp after creation
      await videoDoc.update({
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Trigger video processing
      try {
        print('VideoService: Triggering video processing');
        final functions = FirebaseFunctions.instance;
        final callable = functions.httpsCallable('processVideo');
        await callable.call({
          'videoId': videoDoc.id,
          'videoURL': videoURL,
        });
        print('VideoService: Video processing triggered successfully');
      } catch (e) {
        print('VideoService: Error triggering video processing: $e');
        // Don't throw here - we still want to return the video object
        // The processing can be retried later if needed
      }

      // Get the document immediately after creation
      final doc = await videoDoc.get();
      if (!doc.exists) {
        throw Exception('Video document was not created properly');
      }

      final video = Video.fromFirestore(doc);
      print('VideoService: Created video object:');
      print('  - ID: ${video.id}');
      print('  - URL: ${video.videoURL}');
      print('  - Thumbnail: ${video.thumbnailURL}');
      print('  - Status: ${video.status}');
      print('  - Privacy: ${video.privacy}');

      // Clear query cache to ensure new video appears in feed
      _queryCache.clear();
      _queryCacheTimestamps.clear();
      print('VideoService: Cleared query cache for immediate feed update');

      return video;
    } catch (e) {
      print('VideoService: Error creating video document: $e');
      rethrow;
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

      return query.snapshots().map((snapshot) async {
        print(
            'VideoService: Got ${snapshot.docs.length} videos from Firestore');

        // Use a map to ensure uniqueness and maintain order
        final Map<String, Video> uniqueVideos = {};

        // Get the current user's following list if they're logged in
        Set<String> followedUsers = {};
        if (_currentUserId.isNotEmpty) {
          final followsSnapshot = await _firestore
              .collection('follows')
              .where('followerId', isEqualTo: _currentUserId)
              .get();
          followedUsers = followsSnapshot.docs
              .map((doc) => doc.data()['followingId'] as String)
              .toSet();
        }

        for (final doc in snapshot.docs) {
          try {
            final data = doc.data() as Map<String, dynamic>;
            final privacy = data['privacy'] as String? ?? 'everyone';
            final videoUserId = data['userId'] as String;

            // Include videos that are:
            // 1. Public (everyone)
            // 2. Don't have a privacy setting (defaults to everyone)
            // 3. Followers-only if the user is following or is the owner
            if (privacy == 'everyone' ||
                !data.containsKey('privacy') ||
                (privacy == 'followers' &&
                    (followedUsers.contains(videoUserId) ||
                        videoUserId == _currentUserId))) {
              final video = Video.fromFirestore(doc);
              uniqueVideos[doc.id] = video;
              print(
                  'VideoService: Successfully processed video ${doc.id} with privacy: $privacy');
            } else {
              print(
                  'VideoService: Skipping video ${doc.id} due to privacy settings: $privacy');
            }
          } catch (e) {
            print('VideoService: Error parsing video doc ${doc.id}: $e');
          }
        }

        final result = uniqueVideos.values.toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

        print('VideoService: Returning ${result.length} unique videos');
        return result;
      }).asyncMap((videos) async => videos);
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

      // Get the current user's following list
      Set<String> followedUsers = {};
      if (_currentUserId.isNotEmpty) {
        final followsSnapshot = await _firestore
            .collection('follows')
            .where('followerId', isEqualTo: _currentUserId)
            .get();
        followedUsers = followsSnapshot.docs
            .map((doc) => doc.data()['followingId'] as String)
            .toSet();
      }

      // Use a map to ensure uniqueness and maintain order
      final Map<String, Video> uniqueVideos = {};

      for (final doc in snapshot.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;
          final privacy = data['privacy'] as String? ?? 'everyone';
          final videoUserId = data['userId'] as String;

          // Include videos that are:
          // 1. Public (everyone)
          // 2. Don't have a privacy setting (defaults to everyone)
          // 3. Followers-only if the user is following or is the owner
          if (privacy == 'everyone' ||
              !data.containsKey('privacy') ||
              (privacy == 'followers' &&
                  (followedUsers.contains(videoUserId) ||
                      videoUserId == _currentUserId))) {
            final video = Video.fromFirestore(doc);
            uniqueVideos[doc.id] = video;
            print(
                'VideoService: Successfully processed video ${doc.id} with privacy: $privacy');
          } else {
            print(
                'VideoService: Skipping video ${doc.id} due to privacy settings: $privacy');
          }
        } catch (e) {
          print('VideoService: Error parsing video doc ${doc.id}: $e');
        }
      }

      final result = uniqueVideos.values.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

      print('VideoService: Returning ${result.length} unique videos');
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
      Query query = _firestore
          .collection('videos')
          .where('userId', isEqualTo: userId)
          .where('status', isEqualTo: 'active');

      // If viewing own profile, show all videos
      // If viewing other's profile, only show public and followers-only videos
      if (userId != _currentUserId) {
        query = query.where('privacy', whereIn: ['everyone', 'followers']);
      }

      return query.snapshots().map((snapshot) async {
        print('VideoService: Got snapshot with ${snapshot.docs.length} videos');

        // If viewing other's profile and they have followers-only videos,
        // check if current user is a follower
        Set<String> followedUsers = {};
        if (userId != _currentUserId) {
          final followsSnapshot = await _firestore
              .collection('follows')
              .where('followerId', isEqualTo: _currentUserId)
              .where('followingId', isEqualTo: userId)
              .get();
          followedUsers = followsSnapshot.docs
              .map((doc) => doc.data()['followingId'] as String)
              .toSet();
        }

        final videos = snapshot.docs
            .map((doc) {
              try {
                final video = Video.fromFirestore(doc);
                final isFollowing = followedUsers.contains(userId);

                // Skip followers-only videos if not following
                if (video.privacy == 'followers' &&
                    !isFollowing &&
                    userId != _currentUserId) {
                  return null;
                }

                return video;
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
      }).asyncMap((videos) async => videos);
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

        // Get videos from followed users - only filter by userId and status
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
                final video = Video.fromFirestore(doc);
                // Filter privacy in memory - include only 'everyone' and 'followers' videos
                if (video.privacy == 'private') {
                  return null;
                }
                return video;
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
      rethrow;
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

      // Create the base query - only filter by userId and status
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
              final data = doc.data() as Map<String, dynamic>;
              final videoId = data['videoId'] as String?;
              final video = Video.fromFirestore(doc);
              // Filter privacy in memory - include only 'everyone' and 'followers' videos
              if (video.privacy == 'private') {
                return null;
              }
              return video;
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

  // Get a single video by ID with detailed logging
  Future<Video?> getVideoById(String videoId) async {
    try {
      print('\nVideoService: Fetching video by ID: $videoId');
      print('VideoService: Current user ID: $_currentUserId');

      final doc = await _firestore.collection('videos').doc(videoId).get();

      if (!doc.exists) {
        print('VideoService: Video not found: $videoId');
        return null;
      }

      final video = Video.fromFirestore(doc);
      print('VideoService: Video found:');
      print('- Owner ID: ${video.userId}');
      print('- Privacy: ${video.privacy}');
      print('- Current user is owner: ${video.userId == _currentUserId}');

      // Check privacy settings
      if (video.privacy == 'private' && video.userId != _currentUserId) {
        print('VideoService: Video is private and user is not owner');
        return null;
      }

      if (video.privacy == 'followers' && video.userId != _currentUserId) {
        // Check if user is a follower
        print('VideoService: Checking if user is a follower');
        final followDoc = await _firestore
            .collection('follows')
            .doc('${_currentUserId}_${video.userId}')
            .get();

        print('VideoService: Follow status: ${followDoc.exists}');
        if (!followDoc.exists) {
          print(
              'VideoService: Video is followers-only and user is not a follower');
          return null;
        }
      }

      print('VideoService: Successfully fetched video: ${video.id}');
      return video;
    } catch (e, stackTrace) {
      print('VideoService: Error fetching video by ID: $e');
      print('VideoService: Stack trace: $stackTrace');
      return null;
    }
  }

  // Get videos for feed with filters
  Stream<List<Video>> getFilteredVideoFeed({
    required VideoFilter filter,
    int limit = 10,
    DocumentSnapshot? startAfter,
  }) {
    print('VideoService: Getting filtered video feed');
    try {
      // Create the base query
      Query query =
          _firestore.collection('videos').where('status', isEqualTo: 'active');

      // Generate filter tags
      final filterTags = filter.generateFilterTags();
      print('VideoService: Using filter tags: $filterTags');

      // Apply tag-based filtering if there are any tags
      if (filterTags.isNotEmpty) {
        query = query.where('tags', arrayContainsAny: filterTags);
      }

      // If we're paginating, add the startAfter
      if (startAfter != null) {
        print('VideoService: Using startAfter document: ${startAfter.id}');
        query = query.startAfterDocument(startAfter);
      }

      // Add ordering and limit
      query = query.orderBy('createdAt', descending: true).limit(limit);

      return query.snapshots().map((snapshot) {
        print('VideoService: Got ${snapshot.docs.length} filtered videos');

        final videos = snapshot.docs
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

        print('VideoService: Successfully parsed ${videos.length} videos');
        return videos;
      });
    } catch (e) {
      print('VideoService: Error setting up filtered video feed: $e');
      rethrow;
    }
  }

  void _clearExpiredCache() {
    final now = DateTime.now();
    final expiredKeys = _queryCacheTimestamps.entries
        .where((entry) => now.difference(entry.value) > _cacheDuration)
        .map((entry) => entry.key)
        .toList();

    for (final key in expiredKeys) {
      _queryCache.remove(key);
      _queryCacheTimestamps.remove(key);
    }
  }

  Future<List<Video>> getFilteredVideoFeedBatch({
    VideoFilter? filter,
    DocumentSnapshot? startAfter,
  }) async {
    print('VideoService: Getting filtered video feed batch');
    print('VideoService: Current filter state: ${filter?.toFirestoreQuery()}');

    try {
      // First, let's check what videos exist at all
      final allVideosSnapshot = await _firestore
          .collection('videos')
          .where('status', isEqualTo: 'active')
          .get();

      print('\nDiagnostic Information:');
      print(
          'Total active videos in database: ${allVideosSnapshot.docs.length}');

      // Analyze the tags in the database
      final Set<String> allBudgetTags = {};
      int videosWithBudgetTags = 0;
      int videosInBudgetRange = 0;

      for (final doc in allVideosSnapshot.docs) {
        final data = doc.data();
        final tags = (data['tags'] as List<dynamic>?)?.cast<String>() ?? [];
        final budgetTags =
            tags.where((tag) => tag.startsWith('budget_')).toList();
        allBudgetTags.addAll(budgetTags);

        if (budgetTags.isNotEmpty) {
          videosWithBudgetTags++;
        }

        final budget = (data['budget'] as num?)?.toDouble() ?? 0.0;
        if (budget >= 0 && budget <= 75) {
          videosInBudgetRange++;
        }

        print('\nAnalyzing video ${doc.id}:');
        print('- Budget: $budget');
        print('- Tags: $tags');
        print('- Budget tags: $budgetTags');
      }

      print('\nDatabase Analysis:');
      print('Videos with budget tags: $videosWithBudgetTags');
      print('Videos in budget range 0-75: $videosInBudgetRange');
      print('All budget tags found: $allBudgetTags');

      // Continue with the original query...
      Query<Map<String, dynamic>> query =
          _firestore.collection('videos').where('status', isEqualTo: 'active');

      if (filter != null && filter.hasFilters) {
        final queryData = filter.toFirestoreQuery();
        if (queryData.containsKey('where')) {
          final conditions = queryData['where'] as List<Map<String, dynamic>>;

          // Find the condition with the fewest tags to optimize the query
          Map<String, dynamic>? bestCondition;
          int minTagCount = double.maxFinite.toInt();

          print(
              'VideoService: Processing ${conditions.length} filter conditions');

          for (final condition in conditions) {
            if (condition.containsKey('tags')) {
              final tagsCondition = condition['tags'] as Map<String, dynamic>;
              if (tagsCondition.containsKey('arrayContainsAny')) {
                final tags = tagsCondition['arrayContainsAny'] as List<String>;
                print(
                    'VideoService: Found condition with ${tags.length} tags: $tags');
                if (tags.isNotEmpty && tags.length < minTagCount) {
                  minTagCount = tags.length;
                  bestCondition = condition;
                  print(
                      'VideoService: New best condition found with ${tags.length} tags');
                }
              }
            }
          }

          if (bestCondition != null) {
            final tagsCondition = bestCondition['tags'] as Map<String, dynamic>;
            final tags = tagsCondition['arrayContainsAny'] as List<String>;
            print('VideoService: Using arrayContainsAny with tags: $tags');
            query = query.where('tags', arrayContainsAny: tags);
          } else {
            print('VideoService: No valid tag conditions found');
          }
        } else {
          print('VideoService: No where conditions in query data');
        }
      } else {
        print('VideoService: No filters applied');
      }

      // Always add createdAt ordering
      query = query.orderBy('createdAt', descending: true);
      print('VideoService: Added createdAt ordering');

      // Get videos with limit
      query =
          query.limit(20); // Increased limit since we'll filter more in memory
      print('VideoService: Set limit to 20');

      if (startAfter != null) {
        query = query.startAfterDocument(startAfter);
        print('VideoService: Added startAfter cursor');
      }

      print(
          'VideoService: Executing query with structure: ${query.toString()}');
      final querySnapshot = await query.get();
      print(
          'VideoService: Got ${querySnapshot.docs.length} videos from initial query');

      if (querySnapshot.docs.isEmpty) {
        print('VideoService: Query returned no results. This could indicate:');
        print('1. No videos match the status=active condition');
        print('2. No videos have the required tags');
        print('3. Index might be missing or not yet built');
        return [];
      }

      // Convert to Video objects and filter out any that might be invalid
      List<Video> videos = [];
      for (final doc in querySnapshot.docs) {
        try {
          if (!doc.exists) {
            print('VideoService: Document ${doc.id} does not exist, skipping');
            continue;
          }

          final data = doc.data();
          if (data['status'] != 'active') {
            print('VideoService: Video ${doc.id} is not active, skipping');
            continue;
          }

          final video = Video.fromFirestore(doc);
          print(
              'VideoService: Processing video ${doc.id} with tags: ${video.tags}');

          // If we have filters, verify all conditions are met
          if (filter != null && filter.hasFilters) {
            final queryData = filter.toFirestoreQuery();
            if (queryData.containsKey('where')) {
              final conditions =
                  queryData['where'] as List<Map<String, dynamic>>;
              bool matchesAllConditions = true;

              for (final condition in conditions) {
                if (condition.containsKey('tags')) {
                  final tagsCondition =
                      condition['tags'] as Map<String, dynamic>;
                  if (tagsCondition.containsKey('arrayContainsAny')) {
                    final requiredTags =
                        tagsCondition['arrayContainsAny'] as List<String>;
                    if (!requiredTags.any((tag) => video.tags.contains(tag))) {
                      matchesAllConditions = false;
                      print(
                          'VideoService: Video ${doc.id} does not match condition for tags: $requiredTags');
                      break;
                    }
                  }
                }
              }

              if (!matchesAllConditions) {
                print(
                    'VideoService: Video ${doc.id} does not match all conditions, skipping');
                continue;
              }
            }
          }

          videos.add(video);
          print('VideoService: Added video ${doc.id} to results');
        } catch (e) {
          print('VideoService: Error parsing video ${doc.id}: $e');
          continue;
        }
      }

      print(
          'VideoService: Successfully processed ${videos.length} valid videos');

      // Sort by createdAt to maintain consistency
      videos.sort((a, b) => b.createdAt.compareTo(a.createdAt));

      // Limit to 10 videos after all filtering
      if (videos.length > 10) {
        videos = videos.sublist(0, 10);
      }

      return videos;
    } catch (e) {
      print('VideoService: Error getting filtered videos: $e');
      return [];
    }
  }

  /// Bookmarks a video and returns true if successful
  Future<bool> bookmarkVideo(String videoId) async {
    if (_currentUserId.isEmpty) return false;

    try {
      print('VideoService: Attempting to bookmark video $videoId');

      bool success = false;
      await _firestore.runTransaction((transaction) async {
        // Check current bookmark status
        final userBookmarkRef = _firestore
            .collection('users')
            .doc(_currentUserId)
            .collection('bookmarkedVideos')
            .doc(videoId);

        final videoRef = _firestore.collection('videos').doc(videoId);

        final bookmarkDoc = await transaction.get(userBookmarkRef);
        final videoDoc = await transaction.get(videoRef);

        if (!videoDoc.exists) {
          print('VideoService: Video $videoId not found');
          success = false;
          return;
        }

        if (bookmarkDoc.exists) {
          print('VideoService: Video already bookmarked');
          success = true;
          return;
        }

        // Add to user's bookmarked videos
        transaction.set(userBookmarkRef, {
          'videoId': videoId,
          'bookmarkedAt': FieldValue.serverTimestamp(),
        });

        // Increment video bookmark count
        final currentBookmarks =
            (videoDoc.data()?['bookmarkCount'] as int?) ?? 0;
        transaction.update(videoRef, {
          'bookmarkCount': currentBookmarks + 1,
        });

        success = true;
      });

      return success;
    } catch (e) {
      print('VideoService: Error bookmarking video $videoId: $e');
      return false;
    }
  }

  /// Removes bookmark from a video and returns true if successful
  Future<bool> unbookmarkVideo(String videoId) async {
    if (_currentUserId.isEmpty) return false;

    try {
      print('VideoService: Attempting to unbookmark video $videoId');

      bool success = false;
      await _firestore.runTransaction((transaction) async {
        // Check current bookmark status
        final userBookmarkRef = _firestore
            .collection('users')
            .doc(_currentUserId)
            .collection('bookmarkedVideos')
            .doc(videoId);

        final videoRef = _firestore.collection('videos').doc(videoId);

        final bookmarkDoc = await transaction.get(userBookmarkRef);
        final videoDoc = await transaction.get(videoRef);

        if (!videoDoc.exists) {
          print('VideoService: Video $videoId not found');
          success = false;
          return;
        }

        if (!bookmarkDoc.exists) {
          print('VideoService: Video not bookmarked');
          success = true;
          return;
        }

        // Remove from user's bookmarked videos
        transaction.delete(userBookmarkRef);

        // Decrement video bookmark count
        final currentBookmarks =
            (videoDoc.data()?['bookmarkCount'] as int?) ?? 0;
        transaction.update(videoRef, {
          'bookmarkCount': math.max(0, currentBookmarks - 1),
        });

        success = true;
      });

      return success;
    } catch (e) {
      print('VideoService: Error unbookmarking video $videoId: $e');
      return false;
    }
  }

  /// Checks if the current user has bookmarked a video
  Future<bool> hasUserBookmarkedVideo(String videoId) async {
    if (_currentUserId.isEmpty) return false;

    try {
      print('VideoService: Checking if user bookmarked video $videoId');
      final doc = await _firestore
          .collection('users')
          .doc(_currentUserId)
          .collection('bookmarkedVideos')
          .doc(videoId)
          .get();

      return doc.exists;
    } catch (e) {
      print(
          'VideoService: Error checking bookmark status for video $videoId: $e');
      return false;
    }
  }

  /// Stream of the current user's bookmark status for a video
  Stream<bool> watchUserBookmarkStatus(String videoId) {
    if (_currentUserId.isEmpty) {
      return Stream.value(false);
    }

    return _firestore
        .collection('users')
        .doc(_currentUserId)
        .collection('bookmarkedVideos')
        .doc(videoId)
        .snapshots()
        .map((doc) => doc.exists);
  }

  /// Stream to watch a video's bookmark count in real-time
  Stream<int> watchVideoBookmarkCount(String videoId) {
    return _firestore
        .collection('videos')
        .doc(videoId)
        .snapshots()
        .map((snapshot) => (snapshot.data()?['bookmarkCount'] as int?) ?? 0);
  }

  /// Get bookmarked videos for the current user
  Stream<List<Video>> getBookmarkedVideos(
      {int limit = 10, DocumentSnapshot? startAfter}) {
    if (_currentUserId.isEmpty) {
      print('VideoService: No current user, returning empty list');
      return Stream.value([]);
    }

    try {
      print('VideoService: Getting bookmarked videos');
      Query query = _firestore
          .collection('users')
          .doc(_currentUserId)
          .collection('bookmarkedVideos')
          .orderBy('bookmarkedAt', descending: true);

      if (startAfter != null) {
        query = query.startAfterDocument(startAfter);
      }

      query = query.limit(limit);

      return query.snapshots().handleError((error) {
        print('VideoService: Error accessing bookmarked videos: $error');
        // Return empty list on permission error or any other error
        return [];
      }).asyncMap((snapshot) async {
        print('VideoService: Got ${snapshot.docs.length} bookmarked videos');

        final List<Video> videos = [];
        for (final doc in snapshot.docs) {
          try {
            final data = doc.data() as Map<String, dynamic>;
            final videoId = data['videoId'] as String?;
            if (videoId == null) continue;

            final videoDoc =
                await _firestore.collection('videos').doc(videoId).get();
            if (videoDoc.exists) {
              final video = Video.fromFirestore(videoDoc);
              videos.add(video);
            }
          } catch (e) {
            print('VideoService: Error fetching bookmarked video: $e');
          }
        }

        return videos;
      });
    } catch (e) {
      print('VideoService: Error getting bookmarked videos: $e');
      return Stream.value([]);
    }
  }

  // Call the migration function to update videos with bucket fields
  Future<Map<String, dynamic>> migrateVideosToBuckets() async {
    try {
      print('VideoService: Starting video bucket migration');

      final callable = _functions.httpsCallable('migrateVideosToBuckets');
      final result = await callable.call();

      print('VideoService: Migration completed: ${result.data}');
      return result.data as Map<String, dynamic>;
    } catch (e) {
      print('VideoService: Error in migration: $e');
      rethrow;
    }
  }

  // Call the migration function to update videos with tags
  Future<Map<String, dynamic>> migrateVideosToTags() async {
    try {
      print('VideoService: Starting video tag migration');

      final callable = _functions.httpsCallable('migrateVideosToTags');
      final result = await callable.call();

      print('VideoService: Migration completed: ${result.data}');
      return result.data as Map<String, dynamic>;
    } catch (e) {
      print('VideoService: Error in migration: $e');
      rethrow;
    }
  }

  Future<List<Video>> getCollectionVideos(String collectionId) async {
    print('VideoService: Getting videos for collection $collectionId');
    try {
      // First get the video references from the collection
      final collectionVideosSnapshot = await _firestore
          .collection('collections')
          .doc(collectionId)
          .collection('videos')
          .orderBy('addedAt', descending: true)
          .get();

      print(
          'VideoService: Found ${collectionVideosSnapshot.docs.length} video references');

      // Get the actual video documents
      final List<Video> videos = [];
      for (var doc in collectionVideosSnapshot.docs) {
        try {
          final data = doc.data();
          final videoId = data['videoId'] as String?;

          if (videoId == null) {
            print(
                'VideoService: Warning - Document ${doc.id} has no videoId field. Data: $data');
            continue;
          }

          print('VideoService: Fetching video data for $videoId');

          final videoDoc =
              await _firestore.collection('videos').doc(videoId).get();
          if (videoDoc.exists && videoDoc.data()?['status'] == 'active') {
            try {
              final video = Video.fromFirestore(videoDoc);
              videos.add(video);
              print('VideoService: Successfully added video ${video.id}');
            } catch (e) {
              print('VideoService: Error parsing video $videoId: $e');
            }
          } else {
            print('VideoService: Video $videoId not found or not active');
          }
        } catch (e) {
          print(
              'VideoService: Error processing collection video document ${doc.id}: $e');
          // Continue to next document instead of crashing
          continue;
        }
      }

      print('VideoService: Returning ${videos.length} videos');
      return videos;
    } catch (e) {
      print('VideoService: Error getting collection videos: $e');
      rethrow;
    }
  }

  Future<List<Collection>> getUserCollections(String userId) async {
    print('\nVideoService: Getting collections for user $userId');
    try {
      print('VideoService: Building query for collections');
      Query query = _firestore
          .collection('collections')
          .where('userId', isEqualTo: userId)
          .orderBy('createdAt', descending: true);

      // If not viewing own collections, filter out private ones
      if (_currentUserId != userId) {
        query = query.where('isPrivate', isEqualTo: false);
      }

      print('VideoService: Executing query');
      final snapshot = await query.get();
      print('VideoService: Got ${snapshot.docs.length} collection documents');

      final collections = snapshot.docs.map((doc) {
        try {
          print('VideoService: Converting doc ${doc.id} to Collection');
          final collection = Collection.fromFirestore(doc);
          print(
              'VideoService: Successfully converted collection ${collection.id}');
          return collection;
        } catch (e, stackTrace) {
          print(
              'VideoService: Error converting doc ${doc.id} to Collection: $e');
          print('VideoService: Stack trace: $stackTrace');
          rethrow;
        }
      }).toList();

      print(
          'VideoService: Successfully converted ${collections.length} collections');
      return collections;
    } catch (e, stackTrace) {
      print('VideoService: Error getting user collections: $e');
      print('VideoService: Stack trace: $stackTrace');
      rethrow;
    }
  }

  Future<Collection> createCollection({
    required String userId,
    required String name,
    bool isPrivate = false,
  }) async {
    try {
      print('\nVideoService: Starting collection creation');
      print('VideoService: userId=$userId, name=$name, isPrivate=$isPrivate');

      final collectionRef = _firestore.collection('collections').doc();
      print('VideoService: Generated collection ID: ${collectionRef.id}');

      final now = DateTime.now();

      // Create local Collection object
      final collection = Collection(
        id: collectionRef.id,
        userId: userId,
        name: name,
        createdAt: now,
        updatedAt: now,
        videoCount: 0,
        isPrivate: isPrivate,
      );

      // Create Firestore data with server timestamp
      final data = {
        'userId': userId,
        'name': name,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'videoCount': 0,
        'isPrivate': isPrivate,
      };

      print('VideoService: Setting collection data in Firestore');
      await collectionRef.set(data);
      print('VideoService: Successfully created collection in Firestore');

      // Verify the collection was created
      final verifyDoc = await collectionRef.get();
      print(
          'VideoService: Verification - Collection exists: ${verifyDoc.exists}');
      if (verifyDoc.exists) {
        print(
            'VideoService: Verification - Collection data: ${verifyDoc.data()}');
      }

      return collection;
    } catch (e, stackTrace) {
      print('VideoService: Error creating collection: $e');
      print('VideoService: Stack trace: $stackTrace');
      rethrow;
    }
  }

  Future<void> addVideoToCollection({
    required String collectionId,
    required String videoId,
  }) async {
    print(
        '\nVideoService: Starting to add video $videoId to collection $collectionId');
    print('VideoService: Current user: $_currentUserId');

    try {
      // First verify the collection exists and user owns it
      final collectionRef =
          _firestore.collection('collections').doc(collectionId);
      final collectionDoc = await collectionRef.get();

      if (!collectionDoc.exists) {
        print('VideoService: Collection not found');
        throw Exception('Collection not found');
      }

      final collectionData = collectionDoc.data();
      final collectionOwnerId = collectionData?['userId'] as String?;
      final currentVideoCount = collectionData?['videoCount'] as int? ?? 0;
      print(
          'VideoService: Current video count in collection: $currentVideoCount');
      print('VideoService: Collection owner: $collectionOwnerId');
      print('VideoService: Current user: $_currentUserId');

      // Only check if the user owns the collection
      if (collectionData == null || collectionOwnerId != _currentUserId) {
        print(
            'VideoService: Permission denied - Collection owner: $collectionOwnerId, Current user: $_currentUserId');
        throw Exception('You can only add videos to your own collections');
      }

      // Verify the video exists and is accessible
      final videoRef = _firestore.collection('videos').doc(videoId);
      final videoDoc = await videoRef.get();

      if (!videoDoc.exists) {
        print('VideoService: Video not found');
        throw Exception('Video not found');
      }

      final videoData = videoDoc.data();
      if (videoData == null) {
        print('VideoService: Video data is null');
        throw Exception('Invalid video data');
      }

      // Check if video is already in the collection
      final existingVideo =
          await collectionRef.collection('videos').doc(videoId).get();
      if (existingVideo.exists) {
        print('VideoService: Video already exists in collection');
        return;
      }

      print('VideoService: Starting batch operation');
      print('VideoService: Current video count: $currentVideoCount');

      // Use current timestamp for immediate updates
      final now = DateTime.now();
      final timestamp = Timestamp.fromDate(now);

      // Use a batch to ensure both operations succeed or fail together
      final batch = _firestore.batch();

      // Add video to collection's videos subcollection
      print('VideoService: Adding video to collection subcollection');
      final collectionVideoRef =
          collectionRef.collection('videos').doc(videoId);
      batch.set(collectionVideoRef, {
        'addedAt': timestamp,
        'addedBy': _currentUserId,
        'videoId': videoId,
        'thumbnailURL': videoData['thumbnailURL'],
      });

      // Update collection's video count and thumbnail
      print('VideoService: Updating collection metadata');
      print('VideoService: Incrementing video count from $currentVideoCount');
      batch.update(collectionRef, {
        'videoCount': FieldValue.increment(1),
        'updatedAt': timestamp,
        'thumbnailUrl': videoData['thumbnailURL'],
      });

      // Commit both operations
      await batch.commit();
      print('VideoService: Successfully committed batch operations');

      // Verify the update
      final updatedDoc = await collectionRef.get();
      final updatedCount = updatedDoc.data()?['videoCount'] as int? ?? 0;
      print('VideoService: Updated video count in collection: $updatedCount');

      // Force a refresh of the collection stream
      print('VideoService: Forcing collection stream refresh');
      await _firestore.collection('collections').doc(collectionId).get();
    } catch (e, stackTrace) {
      print('VideoService: Error adding video to collection:');
      print('Error: $e');
      print('Stack trace: $stackTrace');
      rethrow;
    }
  }

  Future<void> removeVideoFromCollection(
      String collectionId, String videoId) async {
    try {
      final batch = _firestore.batch();

      // Remove video from collection's videos subcollection
      final videoRef = _firestore
          .collection('collections')
          .doc(collectionId)
          .collection('videos')
          .doc(videoId);

      batch.delete(videoRef);

      // Update collection's video count
      final collectionRef =
          _firestore.collection('collections').doc(collectionId);
      batch.update(collectionRef, {
        'videoCount': FieldValue.increment(-1),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      await batch.commit();
    } catch (e) {
      print('VideoService: Error removing video from collection: $e');
      rethrow;
    }
  }

  Future<void> updateCollection({
    required String collectionId,
    String? name,
    bool? isPrivate,
  }) async {
    try {
      final updates = <String, dynamic>{
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (name != null) updates['name'] = name;
      if (isPrivate != null) updates['isPrivate'] = isPrivate;

      await _firestore
          .collection('collections')
          .doc(collectionId)
          .update(updates);
    } catch (e) {
      print('VideoService: Error updating collection: $e');
      rethrow;
    }
  }

  Future<void> deleteCollection(String collectionId) async {
    try {
      // First, delete all videos in the collection
      final videosSnapshot = await _firestore
          .collection('collections')
          .doc(collectionId)
          .collection('videos')
          .get();

      final batch = _firestore.batch();
      for (var doc in videosSnapshot.docs) {
        batch.delete(doc.reference);
      }

      // Then delete the collection document
      batch.delete(_firestore.collection('collections').doc(collectionId));

      await batch.commit();
    } catch (e) {
      print('VideoService: Error deleting collection: $e');
      rethrow;
    }
  }

  Future<VideoPlayerController?> getController(int index) async {
    print('VideoControllerManager: Getting controller for index $index');
    print(
        'VideoControllerManager: Current auth state: ${FirebaseAuth.instance.currentUser?.uid ?? 'not signed in'}');

    // Don't return a controller that's being disposed
    if (_disposingControllers.contains(index)) {
      print(
          'VideoControllerManager: Controller $index is being disposed, returning null');
      return null;
    }

    if (!_controllers.containsKey(index)) {
      print('VideoControllerManager: No controller exists for index $index');
      return null;
    }

    try {
      if (_initializationCompleters.containsKey(index)) {
        // ... existing code ...
      }
    } catch (e) {
      print('VideoService: Error getting controller: $e');
      return null;
    }
  }

  Future<void> _initializeController(int index, Video video) async {
    debugPrint(
        'VideoControllerManager: Entering _initializeController for index $index');
    debugPrint('VideoControllerManager: Video URL: ${video.videoURL}');
    debugPrint('VideoControllerManager: Video privacy: ${video.privacy}');
    debugPrint('VideoControllerManager: Video owner: ${video.userId}');
    debugPrint(
        'VideoControllerManager: Current user: ${FirebaseAuth.instance.currentUser?.uid ?? 'not signed in'}');

    if (_disposingControllers.contains(index)) {
      // ... existing code ...
    }
  }

  Stream<List<Collection>> watchUserCollections(String userId) {
    print('\nVideoService: Starting to watch collections for user $userId');

    Query query = _firestore
        .collection('collections')
        .where('userId', isEqualTo: userId)
        .orderBy('updatedAt', descending: true);

    // If not viewing own collections, filter out private ones
    if (_currentUserId != userId) {
      query = query.where('isPrivate', isEqualTo: false);
    }

    return query.snapshots().map((snapshot) {
      print('\nVideoService: Received collections snapshot');
      print('VideoService: Number of documents: ${snapshot.docs.length}');

      final collections = <Collection>[];

      for (var doc in snapshot.docs) {
        try {
          print('\nVideoService: Processing collection document ${doc.id}');
          print('VideoService: Document data: ${doc.data()}');

          final collection = Collection.fromFirestore(doc);
          collections.add(collection);

          print(
              'VideoService: Successfully processed collection ${collection.id}');
          print('- Name: ${collection.name}');
          print('- Video Count: ${collection.videoCount}');
          print('- Is Private: ${collection.isPrivate}');

          // Start watching video count for this collection
          _watchCollectionVideoCount(collection.id);
        } catch (e, stackTrace) {
          print('VideoService: Error processing collection document ${doc.id}');
          print('Error: $e');
          print('Stack trace: $stackTrace');
          // Continue processing other documents
        }
      }

      print('\nVideoService: Finished processing collections');
      print('VideoService: Returning ${collections.length} collections');
      return collections;
    }).handleError((error, stackTrace) {
      print('\nVideoService: Error in collections stream');
      print('Error: $error');
      print('Stack trace: $stackTrace');
      return <Collection>[];
    });
  }

  // Add this method to watch video count for a specific collection
  Stream<int> watchCollectionVideoCount(String collectionId) {
    return _firestore
        .collection('collections')
        .doc(collectionId)
        .snapshots()
        .map((doc) => (doc.data()?['videoCount'] as int?) ?? 0);
  }

  // Keep track of video count subscriptions
  final Map<String, StreamSubscription<int>> _videoCountSubscriptions = {};

  void _watchCollectionVideoCount(String collectionId) {
    // Cancel existing subscription if any
    _videoCountSubscriptions[collectionId]?.cancel();

    // Start new subscription
    _videoCountSubscriptions[collectionId] =
        watchCollectionVideoCount(collectionId).listen((count) {
      print(
          'VideoService: Collection $collectionId video count updated to: $count');
    });
  }

  // Don't forget to cancel subscriptions when they're no longer needed
  void cancelVideoCountSubscriptions() {
    for (var subscription in _videoCountSubscriptions.values) {
      subscription.cancel();
    }
    _videoCountSubscriptions.clear();
  }

  /// Performs a semantic search for videos
  Future<List<Video>> searchContent(String query) async {
    try {
      print('VideoService: Starting search with query: "$query"');

      final callable =
          FirebaseFunctions.instance.httpsCallable('searchContent');
      print('VideoService: Calling cloud function searchContent');

      final result = await callable.call({
        'query': query,
        'limit': 20,
      });

      print('VideoService: Search results received');
      print('VideoService: Raw response data: ${result.data}');

      if (result.data == null) {
        print('VideoService: No results returned from search');
        return [];
      }

      final List<dynamic> results =
          (result.data['results'] as List<dynamic>?) ?? [];
      print('VideoService: Processing ${results.length} results');

      // Get the IDs from the search results
      final videoIds = results.map((result) {
        final metadata = Map<String, dynamic>.from(result['metadata'] as Map);
        return metadata['videoId'].toString();
      }).toList();

      print('VideoService: Found video IDs: $videoIds');

      // Fetch all videos in parallel
      final videos = await Future.wait(
        videoIds.map((id) => getVideoById(id)).toList(),
      );

      // Filter out nulls and return valid videos
      final validVideos = videos.where((v) => v != null).cast<Video>().toList();
      print('VideoService: Returning ${validVideos.length} valid videos');
      return validVideos;
    } catch (e, stackTrace) {
      print('VideoService: Error in searchContent: $e');
      print('VideoService: Stack trace: $stackTrace');
      rethrow;
    }
  }
}
