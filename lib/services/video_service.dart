import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:video_player/video_player.dart';
import '../models/video.dart';

class VideoService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;

  // Upload a video file to Firebase Storage
  Future<String> uploadVideo(String userId, File videoFile) async {
    try {
      final String fileName =
          '${DateTime.now().millisecondsSinceEpoch}_$userId.mp4';
      final Reference ref = _storage.ref().child('videos/$userId/$fileName');

      final UploadTask uploadTask = ref.putFile(videoFile);
      final TaskSnapshot snapshot = await uploadTask;

      return await snapshot.ref.getDownloadURL();
    } catch (e) {
      print('Error uploading video: $e');
      throw Exception('Failed to upload video');
    }
  }

  // Generate and upload thumbnail
  Future<String> uploadThumbnail(String userId, File thumbnailFile) async {
    try {
      final String fileName =
          '${DateTime.now().millisecondsSinceEpoch}_$userId.jpg';
      final Reference ref =
          _storage.ref().child('thumbnails/$userId/$fileName');

      final UploadTask uploadTask = ref.putFile(thumbnailFile);
      final TaskSnapshot snapshot = await uploadTask;

      return await snapshot.ref.getDownloadURL();
    } catch (e) {
      print('Error uploading thumbnail: $e');
      throw Exception('Failed to upload thumbnail');
    }
  }

  // Create a new video document in Firestore
  Future<Video> createVideo({
    required String userId,
    required String videoURL,
    required String thumbnailURL,
    required double duration,
    required int width,
    required int height,
    String? description,
  }) async {
    try {
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
      };

      final DocumentReference docRef =
          await _firestore.collection('videos').add(videoData);
      final DocumentSnapshot doc = await docRef.get();

      return Video.fromFirestore(doc);
    } catch (e) {
      print('Error creating video document: $e');
      throw Exception('Failed to create video document');
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
    Query query = _firestore
        .collection('videos')
        .where('status', isEqualTo: 'active')
        .orderBy('createdAt', descending: true)
        .limit(limit);

    if (startAfter != null) {
      query = query.startAfterDocument(startAfter);
    }

    return query.snapshots().map((snapshot) {
      return snapshot.docs.map((doc) => Video.fromFirestore(doc)).toList();
    });
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
}
