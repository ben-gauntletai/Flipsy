import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import '../models/video.dart';
import 'package:uuid/uuid.dart';

class VideoService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;

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

  // Generate a thumbnail from the first frame of the video
  Future<String> generateAndUploadThumbnail(
      String userId, File videoFile) async {
    try {
      // Generate thumbnail using video_thumbnail package
      final tempDir = await getTemporaryDirectory();
      final thumbnailPath = '${tempDir.path}/${const Uuid().v4()}.jpg';

      // Generate the thumbnail
      final thumbnailFile = await VideoThumbnail.thumbnailFile(
        video: videoFile.path,
        thumbnailPath: thumbnailPath,
        imageFormat: ImageFormat.JPEG,
        maxHeight: 720,
        quality: 75,
      );

      if (thumbnailFile == null) {
        throw Exception('Failed to generate thumbnail');
      }

      // Upload the thumbnail
      final fileName = '${const Uuid().v4()}.jpg';
      final storageRef = FirebaseStorage.instance
          .ref()
          .child('users/$userId/thumbnails/$fileName');

      final metadata = SettableMetadata(
        contentType: 'image/jpeg',
        customMetadata: {'userId': userId},
      );

      await storageRef.putFile(File(thumbnailFile), metadata);
      final thumbnailUrl = await storageRef.getDownloadURL();

      // Clean up
      await File(thumbnailFile).delete();

      return thumbnailUrl;
    } catch (e) {
      print('Error generating thumbnail: $e');
      throw Exception('Failed to generate thumbnail: $e');
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
  }) async {
    try {
      // Generate and upload thumbnail if video file is provided
      String thumbnailURL;
      if (videoFile != null) {
        thumbnailURL = await generateAndUploadThumbnail(userId, videoFile);
      } else {
        // Fallback to video URL if no file provided
        thumbnailURL = videoURL;
      }

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
