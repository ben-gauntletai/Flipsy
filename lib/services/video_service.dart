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

class VideoService {
  static final VideoService _instance = VideoService._internal();
  factory VideoService() => _instance;

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;
  final Map<String, Timer> _reconciliationTimers = {};
  final Map<String, int> _localLikeCounts = {};
  static const int _maxQueryLimit = 50;
  final Map<String, List<Video>> _queryCache = {};
  final Map<String, DateTime> _queryCacheTimestamps = {};
  static const Duration _cacheDuration = Duration(minutes: 5);

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

      // Use current timestamp for immediate feed update
      final now = DateTime.now();

      final videoDoc = await _firestore.collection('videos').add({
        'userId': userId,
        'videoURL': videoURL,
        'thumbnailURL': thumbnailURL,
        'description': description,
        'createdAt': now, // Use current timestamp first
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
      });

      print('VideoService: Created document with ID: ${videoDoc.id}');

      // Update with server timestamp after creation
      await videoDoc.update({
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

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

      // Check privacy settings
      if (video.privacy == 'private' && video.userId != _currentUserId) {
        print('VideoService: Video is private and user is not owner');
        return null;
      }

      if (video.privacy == 'followers' && video.userId != _currentUserId) {
        // Check if user is a follower
        final followDoc = await _firestore
            .collection('follows')
            .doc('${_currentUserId}_${video.userId}')
            .get();

        if (!followDoc.exists) {
          print(
              'VideoService: Video is followers-only and user is not a follower');
          return null;
        }
      }

      print('VideoService: Successfully fetched video: ${video.id}');
      return video;
    } catch (e) {
      print('VideoService: Error fetching video by ID: $e');
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

      // Apply budget range filter
      if (filter.budgetRange != null) {
        query = query
            .where('budget', isGreaterThanOrEqualTo: filter.budgetRange!.start)
            .where('budget', isLessThanOrEqualTo: filter.budgetRange!.end);
      }

      // Apply calories range filter
      if (filter.caloriesRange != null) {
        query = query
            .where('calories',
                isGreaterThanOrEqualTo: filter.caloriesRange!.start.toInt())
            .where('calories',
                isLessThanOrEqualTo: filter.caloriesRange!.end.toInt());
      }

      // Apply prep time range filter
      if (filter.prepTimeRange != null) {
        query = query
            .where('prepTimeMinutes',
                isGreaterThanOrEqualTo: filter.prepTimeRange!.start.toInt())
            .where('prepTimeMinutes',
                isLessThanOrEqualTo: filter.prepTimeRange!.end.toInt());
      }

      // Apply spiciness range filter
      if (filter.minSpiciness != null || filter.maxSpiciness != null) {
        query = query
            .where('spiciness',
                isGreaterThanOrEqualTo: filter.minSpiciness ?? 0)
            .where('spiciness', isLessThanOrEqualTo: filter.maxSpiciness ?? 5);
      }

      // Apply hashtag filter
      if (filter.hashtags.isNotEmpty) {
        // Extract hashtags from description field
        // Note: This is a simple implementation. For better hashtag support,
        // consider creating a separate 'hashtags' array field in the video document
        query = query.where('description',
            arrayContainsAny: filter.hashtags.map((tag) => '#$tag').toList());
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
      // Clear expired cache entries
      _clearExpiredCache();

      // Generate cache key
      final cacheKey = '${filter?.toFirestoreQuery()}_${startAfter?.id}';

      // Check cache first
      if (_queryCache.containsKey(cacheKey)) {
        print('VideoService: Returning cached results for key: $cacheKey');
        return _queryCache[cacheKey]!;
      }

      Query<Map<String, dynamic>> query =
          _firestore.collection('videos').where('status', isEqualTo: 'active');

      // Store conditions at a wider scope for use in memory filtering
      final conditions = filter?.toFirestoreQuery() ?? {};

      // Apply only one numeric filter in Firestore, handle others in memory
      if (filter != null) {
        // Try to apply the most selective filter first
        if (conditions.containsKey('calories')) {
          final caloriesRange = conditions['calories'];
          query = query
              .where('calories', isGreaterThanOrEqualTo: caloriesRange['start'])
              .where('calories', isLessThanOrEqualTo: caloriesRange['end']);
        } else if (conditions.containsKey('budget')) {
          final budgetRange = conditions['budget'];
          query = query
              .where('budget', isGreaterThanOrEqualTo: budgetRange['start'])
              .where('budget', isLessThanOrEqualTo: budgetRange['end']);
        } else if (conditions.containsKey('prepTimeMinutes')) {
          final prepTimeRange = conditions['prepTimeMinutes'];
          query = query
              .where('prepTimeMinutes',
                  isGreaterThanOrEqualTo: prepTimeRange['start'])
              .where('prepTimeMinutes',
                  isLessThanOrEqualTo: prepTimeRange['end']);
        } else if (conditions.containsKey('spiciness')) {
          final spicinessRange = conditions['spiciness'];
          query = query
              .where('spiciness', isGreaterThanOrEqualTo: spicinessRange['min'])
              .where('spiciness', isLessThanOrEqualTo: spicinessRange['max']);
        }

        // Apply hashtag filter using arrayContainsAny
        if (conditions.containsKey('hashtags')) {
          final hashtags = conditions['hashtags'] as List<String>;
          if (hashtags.isNotEmpty) {
            if (hashtags.length > VideoFilter.maxHashtags) {
              throw Exception(
                  'Maximum of ${VideoFilter.maxHashtags} hashtags allowed');
            }
            query = query.where('hashtags', arrayContainsAny: hashtags);
          }
        }
      }

      // Always add createdAt ordering
      query = query.orderBy('createdAt', descending: true);

      // Get more videos than needed to account for additional memory filtering
      query = query.limit(_maxQueryLimit);

      if (startAfter != null) {
        query = query.startAfterDocument(startAfter);
      }

      print('VideoService: Executing query');
      final querySnapshot = await query.get();
      print('VideoService: Got ${querySnapshot.docs.length} videos');

      // Convert to Video objects
      List<Video> videos =
          querySnapshot.docs.map((doc) => Video.fromFirestore(doc)).toList();

      // Apply remaining filters in memory
      if (filter != null) {
        videos = videos.where((video) {
          // Check budget if not already filtered in Firestore
          if (filter.budgetRange != VideoFilter.defaultBudgetRange &&
              !conditions.containsKey('budget') &&
              (video.budget < filter.budgetRange.start ||
                  video.budget > filter.budgetRange.end)) {
            return false;
          }

          // Check calories if not already filtered in Firestore
          if (filter.caloriesRange != VideoFilter.defaultCaloriesRange &&
              !conditions.containsKey('calories') &&
              (video.calories < filter.caloriesRange.start ||
                  video.calories > filter.caloriesRange.end)) {
            return false;
          }

          // Check prep time if not already filtered in Firestore
          if (filter.prepTimeRange != VideoFilter.defaultPrepTimeRange &&
              !conditions.containsKey('prepTimeMinutes') &&
              (video.prepTimeMinutes < filter.prepTimeRange.start ||
                  video.prepTimeMinutes > filter.prepTimeRange.end)) {
            return false;
          }

          // Check spiciness if not already filtered in Firestore
          if ((filter.minSpiciness != 0 || filter.maxSpiciness != 5) &&
              !conditions.containsKey('spiciness') &&
              (video.spiciness < filter.minSpiciness ||
                  video.spiciness > filter.maxSpiciness)) {
            return false;
          }

          return true;
        }).toList();
      }

      // Take only the first 10 videos after all filtering
      videos = videos.take(10).toList();

      // Cache the results
      _queryCache[cacheKey] = videos;
      _queryCacheTimestamps[cacheKey] = DateTime.now();

      print('VideoService: Returning ${videos.length} videos after filtering');
      return videos;
    } catch (e) {
      print('VideoService: Error getting filtered videos: $e');
      rethrow;
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
}
