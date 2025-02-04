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
      final ImagePicker picker = ImagePicker();
      final XFile? video = await picker.pickVideo(source: ImageSource.gallery);

      if (video != null) {
        setState(() {
          _videoFile = File(video.path);
          _error = null;
        });

        // Initialize video player
        _videoController?.dispose();
        _videoController = VideoPlayerController.file(_videoFile!)
          ..initialize().then((_) {
            setState(() {});
            _videoController?.play();
            _videoController?.setLooping(true);
          });
      }
    } catch (e) {
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
      _error = null;
    });

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('User not logged in');

      // Get video metadata
      final metadata = await _videoService.getVideoMetadata(_videoFile!);

      // Upload video file
      final videoURL = await _videoService.uploadVideo(user.uid, _videoFile!);

      // For now, we'll use a frame from the video as thumbnail
      // In a production app, you'd want to generate a proper thumbnail
      final thumbnailURL = videoURL; // Temporary solution

      // Create video document
      await _videoService.createVideo(
        userId: user.uid,
        videoURL: videoURL,
        thumbnailURL: thumbnailURL,
        duration: metadata['duration'],
        width: metadata['width'],
        height: metadata['height'],
        description: _descriptionController.text.trim(),
      );

      // Navigate back or to feed
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Video uploaded successfully!')),
        );
      }
    } catch (e) {
      setState(() {
        _error = 'Error uploading video: $e';
      });
    } finally {
      setState(() {
        _isUploading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Upload Video'),
        actions: [
          if (_videoFile != null)
            IconButton(
              icon: const Icon(Icons.check),
              onPressed: _isUploading ? null : _uploadVideo,
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
              if (_isUploading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16.0),
                  child: Center(child: CircularProgressIndicator()),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
