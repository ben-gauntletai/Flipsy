import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../../../services/video_service.dart';
import 'package:video_player/video_player.dart';
import '../widgets/upload_progress_dialog.dart';
import '../widgets/spiciness_selector.dart';

class VideoUploadScreen extends StatefulWidget {
  final Function(String)? onVideoUploaded;

  const VideoUploadScreen({
    super.key,
    this.onVideoUploaded,
  });

  @override
  State<VideoUploadScreen> createState() => _VideoUploadScreenState();
}

class _VideoUploadScreenState extends State<VideoUploadScreen> {
  final VideoService _videoService = VideoService();
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _budgetController = TextEditingController();
  final TextEditingController _caloriesController = TextEditingController();
  final TextEditingController _prepTimeController = TextEditingController();
  final ValueNotifier<double> _progressNotifier = ValueNotifier<double>(0.0);
  File? _videoFile;
  bool _isUploading = false;
  VideoPlayerController? _videoController;
  String? _error;
  bool _allowComments = true;
  String _privacy = 'everyone';
  bool _isCompleting = false;
  int _spiciness = 0;

  @override
  void dispose() {
    _descriptionController.dispose();
    _budgetController.dispose();
    _caloriesController.dispose();
    _prepTimeController.dispose();
    _videoController?.dispose();
    _progressNotifier.dispose();
    super.dispose();
  }

  Future<void> _pickVideo() async {
    try {
      print('Opening video picker');
      final ImagePicker picker = ImagePicker();
      final XFile? video = await picker.pickVideo(
        source: ImageSource.gallery,
        maxDuration: const Duration(minutes: 10),
      );

      if (video != null) {
        print('Video selected: ${video.path}');
        final videoFile = File(video.path);

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

    // Pause the video during upload
    _videoController?.pause();

    setState(() {
      _isUploading = true;
      _error = null;
    });
    _progressNotifier.value = 0.0;

    try {
      print('Starting upload process');
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('User not logged in');

      print('Getting video metadata');
      final metadata = await _videoService.getVideoMetadata(_videoFile!);
      print('Video metadata: $metadata');

      // Show upload progress dialog
      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) {
          return ValueListenableBuilder<double>(
            valueListenable: _progressNotifier,
            builder: (context, progress, _) {
              return UploadProgressDialog(
                progress: progress,
                isCompleting: _isCompleting,
                onCancel: () {
                  Navigator.of(context).pop();
                  _cancelUpload();
                },
              );
            },
          );
        },
      );

      print('Uploading video');
      final videoURL = await _videoService.uploadVideo(
        videoFile: _videoFile!,
        userId: user.uid,
        onProgress: (progress) {
          print('Progress callback received: $progress');
          _progressNotifier.value = progress;
          print(
              'Upload progress updated: ${(progress * 100).toStringAsFixed(2)}%');
        },
        description: _descriptionController.text.trim(),
        allowComments: _allowComments,
        privacy: _privacy,
        spiciness: _spiciness,
      );
      print('Video uploaded: $videoURL');

      // Update completing state
      if (mounted) {
        setState(() {
          _isCompleting = true;
        });
      }

      print('Creating video document');
      final video = await _videoService.createVideoDocument(
        userId: user.uid,
        videoURL: videoURL,
        duration: metadata['duration'],
        width: metadata['width'],
        height: metadata['height'],
        description: _descriptionController.text.trim(),
        videoFile: _videoFile,
        allowComments: _allowComments,
        privacy: _privacy,
        spiciness: _spiciness,
        budget: double.tryParse(_budgetController.text) ?? 0.0,
        calories: int.tryParse(_caloriesController.text) ?? 0,
        prepTimeMinutes: int.tryParse(_prepTimeController.text) ?? 0,
      );
      print('Video document created successfully with ID: ${video.id}');

      if (mounted) {
        Navigator.of(context).pop(); // Close progress dialog
        if (widget.onVideoUploaded != null) {
          widget.onVideoUploaded!(video.id);
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Video uploaded successfully!')),
        );
      }
    } catch (e) {
      print('Error in upload process: $e');
      if (mounted) {
        Navigator.of(context).pop(); // Close progress dialog
        setState(() {
          _error = 'Error uploading video: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isUploading = false;
          _isCompleting = false;
        });
      }
      // Resume video playback if upload was canceled
      if (_videoController?.value.isInitialized ?? false) {
        _videoController?.play();
      }
    }
  }

  void _cancelUpload() {
    // The upload will be canceled in the VideoService
    setState(() {
      _isUploading = false;
      _error = 'Upload canceled';
    });
    _progressNotifier.value = 0.0;
    // Resume video playback
    if (_videoController?.value.isInitialized ?? false) {
      _videoController?.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).viewPadding.bottom;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(44),
        child: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          leading: IconButton(
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.close, color: Colors.black),
            onPressed: () => setState(() {
              _videoFile = null;
              _descriptionController.clear();
              _budgetController.clear();
              _caloriesController.clear();
              _prepTimeController.clear();
              _videoController?.dispose();
              _videoController = null;
            }),
          ),
          title: const Text(
            'Post',
            style: TextStyle(color: Colors.black, fontWeight: FontWeight.w600),
          ),
          centerTitle: true,
          actions: [
            // Removed the post button from here
          ],
        ),
      ),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            if (_error != null)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.red, fontSize: 13),
                ),
              ),
            // Main content area
            Expanded(
              child: Column(
                children: [
                  // Video takes all remaining space
                  Expanded(
                    child: _videoController?.value.isInitialized ?? false
                        ? Container(
                            width: double.infinity,
                            height: double.infinity,
                            color: Colors.black,
                            child: Stack(
                              children: [
                                Center(
                                  child: AspectRatio(
                                    aspectRatio:
                                        _videoController!.value.aspectRatio,
                                    child: VideoPlayer(_videoController!),
                                  ),
                                ),
                                Positioned(
                                  bottom: 8,
                                  left: 0,
                                  right: 0,
                                  child: Center(
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withOpacity(0.6),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: const Text(
                                        'Select cover',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          )
                        : GestureDetector(
                            onTap: _isUploading ? null : _pickVideo,
                            child: Container(
                              color: Colors.black,
                              child: Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.video_library,
                                      size: 48,
                                      color: Colors.white.withOpacity(0.8),
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      'Select Video',
                                      style: TextStyle(
                                        color: Colors.white.withOpacity(0.8),
                                        fontSize: 16,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                  ),
                  // Bottom section with description and settings
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border(
                        top: BorderSide(color: Colors.grey[200]!),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Divider(height: 1),
                        // Description field remains full width
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                          child: TextField(
                            controller: _descriptionController,
                            decoration: const InputDecoration(
                              hintText:
                                  'Describe your post, add hashtags, or mention creators that inspired you',
                              hintStyle:
                                  TextStyle(color: Colors.grey, fontSize: 15),
                              border: InputBorder.none,
                              isDense: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                            maxLines: 3,
                            minLines: 1,
                            style: const TextStyle(fontSize: 15),
                            enabled: !_isUploading,
                          ),
                        ),
                        const Divider(height: 1),
                        // Cost and Calories in one row
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                          child: Row(
                            children: [
                              // Budget field
                              Expanded(
                                child: TextField(
                                  controller: _budgetController,
                                  decoration: const InputDecoration(
                                    labelText: 'Cost',
                                    hintText: 'Meal cost',
                                    prefixText: '\$',
                                    border: OutlineInputBorder(),
                                    contentPadding: EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 16),
                                  ),
                                  keyboardType: TextInputType.numberWithOptions(
                                      decimal: true),
                                  enabled: !_isUploading,
                                ),
                              ),
                              const SizedBox(width: 12),
                              // Calories field
                              Expanded(
                                child: TextField(
                                  controller: _caloriesController,
                                  decoration: const InputDecoration(
                                    labelText: 'Calories',
                                    hintText: 'Cal count',
                                    suffixText: 'cal',
                                    border: OutlineInputBorder(),
                                    contentPadding: EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 16),
                                  ),
                                  keyboardType: TextInputType.number,
                                  enabled: !_isUploading,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        // Prep Time and Spiciness in one row
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                          child: Row(
                            children: [
                              // Prep Time field
                              Expanded(
                                child: TextField(
                                  controller: _prepTimeController,
                                  decoration: const InputDecoration(
                                    labelText: 'Prep Time',
                                    hintText: 'Minutes',
                                    suffixText: 'min',
                                    border: OutlineInputBorder(),
                                    contentPadding: EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 16),
                                  ),
                                  keyboardType: TextInputType.number,
                                  enabled: !_isUploading,
                                ),
                              ),
                              const SizedBox(width: 12),
                              // Spiciness field
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Padding(
                                      padding:
                                          EdgeInsets.only(left: 12, bottom: 4),
                                      child: Text(
                                        'Spiciness',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.black54,
                                        ),
                                      ),
                                    ),
                                    SpicinessSelector(
                                      value: _spiciness,
                                      onChanged: (value) {
                                        setState(() {
                                          _spiciness = value;
                                        });
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        ListTile(
                          leading: const Icon(Icons.lock_outline),
                          title: const Text('Who can watch this video'),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _privacy == 'everyone'
                                    ? 'Everyone'
                                    : _privacy == 'followers'
                                        ? 'Followers'
                                        : 'Private',
                                style: TextStyle(
                                  color: Colors.grey[600],
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(Icons.chevron_right,
                                  color: Colors.grey[400]),
                            ],
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          minLeadingWidth: 24,
                          horizontalTitleGap: 8,
                          dense: true,
                          onTap: _isUploading
                              ? null
                              : () {
                                  showModalBottomSheet(
                                    context: context,
                                    builder: (context) => SafeArea(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          Padding(
                                            padding: const EdgeInsets.all(16),
                                            child: Text(
                                              'Who can watch this video',
                                              style: TextStyle(
                                                fontSize: 16,
                                                fontWeight: FontWeight.w600,
                                                color: Colors.grey[800],
                                              ),
                                            ),
                                          ),
                                          const Divider(height: 1),
                                          ListTile(
                                            title: const Text('Everyone'),
                                            subtitle: const Text(
                                                'Anyone on Flipsy can watch this video'),
                                            trailing: _privacy == 'everyone'
                                                ? const Icon(Icons.check,
                                                    color: Color(0xFFFF2B55))
                                                : null,
                                            onTap: () {
                                              setState(
                                                  () => _privacy = 'everyone');
                                              Navigator.pop(context);
                                            },
                                          ),
                                          ListTile(
                                            title: const Text('Followers'),
                                            subtitle: const Text(
                                                'Only your followers can watch this video'),
                                            trailing: _privacy == 'followers'
                                                ? const Icon(Icons.check,
                                                    color: Color(0xFFFF2B55))
                                                : null,
                                            onTap: () {
                                              setState(
                                                  () => _privacy = 'followers');
                                              Navigator.pop(context);
                                            },
                                          ),
                                          ListTile(
                                            title: const Text('Private'),
                                            subtitle: const Text(
                                                'Only you can watch this video'),
                                            trailing: _privacy == 'private'
                                                ? const Icon(Icons.check,
                                                    color: Color(0xFFFF2B55))
                                                : null,
                                            onTap: () {
                                              setState(
                                                  () => _privacy = 'private');
                                              Navigator.pop(context);
                                            },
                                          ),
                                        ],
                                      ),
                                    ),
                                    backgroundColor: Colors.white,
                                  );
                                },
                        ),
                        const Divider(height: 1),
                        SwitchListTile(
                          value: _allowComments,
                          onChanged: (bool value) {
                            setState(() {
                              _allowComments = value;
                            });
                          },
                          title: const Text('Allow comments'),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          activeColor: const Color(0xFF00F2EA),
                          dense: true,
                        ),
                        const Divider(height: 1),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // Post button
            Container(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + bottomPadding),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border(
                  top: BorderSide(color: Colors.grey[200]!),
                ),
              ),
              child: ElevatedButton(
                onPressed:
                    _videoFile != null && !_isUploading ? _uploadVideo : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF2B55),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  disabledBackgroundColor: Colors.grey[300],
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.celebration,
                      size: 16,
                      color:
                          _videoFile != null ? Colors.white : Colors.grey[400],
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Post',
                      style: TextStyle(
                        color: _videoFile != null
                            ? Colors.white
                            : Colors.grey[400],
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
