import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../services/video_service.dart';
import 'package:video_player/video_player.dart';

class VideoUploadScreen extends StatefulWidget {
  const VideoUploadScreen({super.key});

  @override
  State<VideoUploadScreen> createState() => _VideoUploadScreenState();
}

class _VideoUploadScreenState extends State<VideoUploadScreen> {
  final VideoService _videoService = VideoService();
  final TextEditingController _descriptionController = TextEditingController();
  File? _videoFile;
  bool _isUploading = false;
  double _uploadProgress = 0.0;
  VideoPlayerController? _videoController;
  String? _error;

  @override
  void dispose() {
    _descriptionController.dispose();
    _videoController?.dispose();
    super.dispose();
  }

  Future<void> _pickVideo() async {
    try {
      print('Opening video picker');
      final ImagePicker picker = ImagePicker();
      final XFile? video = await picker.pickVideo(
        source: ImageSource.gallery,
        maxDuration: const Duration(minutes: 10), // Limit video duration
      );

      if (video != null) {
        print('Video selected: ${video.path}');
        final videoFile = File(video.path);

        // Check file size (limit to 500MB)
        final fileSize = await videoFile.length();
        if (fileSize > 500 * 1024 * 1024) {
          setState(() {
            _error = 'Video file size must be less than 500MB';
          });
          return;
        }

        setState(() {
          _videoFile = videoFile;
          _error = null;
        });

        // Initialize video player
        _videoController?.dispose();
        _videoController = VideoPlayerController.file(videoFile)
          ..initialize().then((_) {
            setState(() {});
            _videoController?.play();
            _videoController?.setLooping(true);
          });
      }
    } catch (e) {
      print('Error picking video: $e');
      setState(() {
        _error = 'Error picking video: $e';
      });
    }
  }

  Future<void> _uploadVideo() async {
    if (_videoFile == null) {
      setState(() {
        _error = 'Please select a video first';
      });
      return;
    }

    setState(() {
      _isUploading = true;
      _uploadProgress = 0.0;
      _error = null;
    });

    try {
      print('Starting video upload process');
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('User not logged in');

      // Get video metadata
      print('Getting video metadata');
      final metadata = await _videoService.getVideoMetadata(_videoFile!);
      print('Video metadata: $metadata');

      // Upload video file
      print('Uploading video');
      final videoURL = await _videoService.uploadVideo(user.uid, _videoFile!);
      print('Video uploaded: $videoURL');

      // Create video document
      print('Creating video document');
      await _videoService.createVideo(
        userId: user.uid,
        videoURL: videoURL,
        thumbnailURL: videoURL, // Using video URL as thumbnail for now
        duration: metadata['duration'],
        width: metadata['width'],
        height: metadata['height'],
        description: _descriptionController.text.trim(),
      );
      print('Video document created successfully');

      // Navigate back or to feed
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Video uploaded successfully!')),
        );
      }
    } catch (e) {
      print('Error in upload process: $e');
      setState(() {
        _error = 'Error uploading video: $e';
      });
    } finally {
      setState(() {
        _isUploading = false;
        _uploadProgress = 0.0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Upload Video'),
        actions: [
          if (_videoFile != null && !_isUploading)
            IconButton(
              icon: const Icon(Icons.check),
              onPressed: _uploadVideo,
            ),
        ],
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16.0),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              if (_videoController?.value.isInitialized ?? false)
                AspectRatio(
                  aspectRatio: _videoController!.value.aspectRatio,
                  child: VideoPlayer(_videoController!),
                ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _isUploading ? null : _pickVideo,
                icon: const Icon(Icons.video_library),
                label:
                    Text(_videoFile == null ? 'Select Video' : 'Change Video'),
              ),
              if (_videoFile != null) ...[
                const SizedBox(height: 16),
                TextField(
                  controller: _descriptionController,
                  decoration: const InputDecoration(
                    labelText: 'Description',
                    hintText: 'Write a description for your video...',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 3,
                  enabled: !_isUploading,
                ),
              ],
              if (_isUploading) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(value: _uploadProgress),
                const SizedBox(height: 8),
                const Center(
                  child: Text('Uploading video...',
                      style: TextStyle(fontStyle: FontStyle.italic)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
