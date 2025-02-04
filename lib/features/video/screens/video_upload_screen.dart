import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../../../services/video_service.dart';
import 'package:video_player/video_player.dart';
import '../widgets/upload_progress_dialog.dart';

class VideoUploadScreen extends StatefulWidget {
  const VideoUploadScreen({super.key});

  @override
  State<VideoUploadScreen> createState() => _VideoUploadScreenState();
}

class _VideoUploadScreenState extends State<VideoUploadScreen> {
  final VideoService _videoService = VideoService();
  final TextEditingController _descriptionController = TextEditingController();
  final ValueNotifier<double> _progressNotifier = ValueNotifier<double>(0.0);
  File? _videoFile;
  bool _isUploading = false;
  VideoPlayerController? _videoController;
  String? _error;
  bool _allowComments = true;
  String _privacy = 'Everyone';
  bool _isCompleting = false;

  @override
  void dispose() {
    _descriptionController.dispose();
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
        user.uid,
        _videoFile!,
        onProgress: (progress) {
          print('Progress callback received: $progress');
          _progressNotifier.value = progress;
          print(
              'Upload progress updated: ${(progress * 100).toStringAsFixed(2)}%');
        },
        onCanceled: () {
          if (mounted) {
            Navigator.of(context).pop(); // Close progress dialog
            Navigator.of(context).pop(); // Return to previous screen
          }
        },
      );
      print('Video uploaded: $videoURL');

      // Update completing state
      if (mounted) {
        setState(() {
          _isCompleting = true;
        });
      }

      print('Creating video document');
      final video = await _videoService.createVideo(
        userId: user.uid,
        videoURL: videoURL,
        duration: metadata['duration'],
        width: metadata['width'],
        height: metadata['height'],
        description: _descriptionController.text.trim(),
        videoFile: _videoFile,
        allowComments: _allowComments,
      );
      print('Video document created successfully with ID: ${video.id}');

      if (mounted) {
        Navigator.of(context).pop(); // Close progress dialog
        Navigator.of(context)
            .pop(video.id); // Return to previous screen with video ID
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
            icon: const Icon(Icons.arrow_back, color: Colors.black),
            onPressed: () => Navigator.pop(context),
          ),
          title: const Text(
            'Post',
            style: TextStyle(color: Colors.black, fontWeight: FontWeight.w600),
          ),
          centerTitle: true,
          actions: [
            if (!_isUploading)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: TextButton(
                  onPressed: _videoFile != null ? _uploadVideo : null,
                  child: Text(
                    'Post',
                    style: TextStyle(
                      color: _videoFile != null
                          ? const Color(0xFFFF2B55)
                          : Colors.grey,
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                  ),
                ),
              ),
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
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
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
                            maxLines: 4,
                            minLines: 1,
                            style: const TextStyle(fontSize: 15),
                            enabled: !_isUploading,
                          ),
                        ),
                        const SizedBox(width: 12),
                        if (_videoController?.value.isInitialized ?? false)
                          Container(
                            width: 80,
                            height: 120,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.grey[200]!),
                            ),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: VideoPlayer(_videoController!),
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
                        else
                          GestureDetector(
                            onTap: _isUploading ? null : _pickVideo,
                            child: Container(
                              width: 80,
                              height: 120,
                              decoration: BoxDecoration(
                                color: Colors.grey[100],
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.video_library,
                                    size: 24,
                                    color: Colors.grey[600],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Select',
                                    style: TextStyle(
                                      color: Colors.grey[600],
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _buildActionChip(
                          icon: Icons.tag,
                          label: 'Hashtags',
                          onTap: () {},
                        ),
                        _buildActionChip(
                          icon: Icons.alternate_email,
                          label: 'Mention',
                          onTap: () {},
                        ),
                        _buildActionChip(
                          icon: Icons.video_library,
                          label: 'Videos',
                          onTap: () {},
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.person_outline),
                    title: const Text('Tag people'),
                    trailing: const Icon(Icons.chevron_right, size: 20),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    minLeadingWidth: 24,
                    horizontalTitleGap: 8,
                    dense: true,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.link),
                    title: const Text('Add link'),
                    trailing: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF2B55),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child:
                          const Icon(Icons.add, color: Colors.white, size: 16),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    minLeadingWidth: 24,
                    horizontalTitleGap: 8,
                    dense: true,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.lock_outline),
                    title: const Text('Who can watch this video'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _privacy,
                          style:
                              TextStyle(color: Colors.grey[600], fontSize: 14),
                        ),
                        const Icon(Icons.chevron_right, size: 20),
                      ],
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    minLeadingWidth: 24,
                    horizontalTitleGap: 8,
                    dense: true,
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
                        horizontal: 16, vertical: 12),
                    activeColor: const Color(0xFF00F2EA),
                    dense: true,
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Share to:',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: Colors.black87,
                            ),
                          ),
                          const Spacer(),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            children: [
                              _buildSocialShareButton(
                                icon: 'facebook',
                                label: 'Facebook',
                                onTap: () {},
                              ),
                              _buildSocialShareButton(
                                icon: 'instagram',
                                label: 'Instagram',
                                onTap: () {},
                              ),
                              _buildSocialShareButton(
                                icon: 'whatsapp',
                                label: 'WhatsApp',
                                onTap: () {},
                              ),
                              _buildSocialShareButton(
                                icon: 'twitter',
                                label: 'Twitter',
                                onTap: () {},
                              ),
                            ],
                          ),
                          const Spacer(),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
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

  Widget _buildActionChip({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.grey[50],
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.grey[200]!),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: Colors.grey[700]),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[700],
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSocialButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey[300]!),
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          size: 18,
          color: Colors.grey[600],
        ),
      ),
    );
  }

  Widget _buildSocialShareButton({
    required String icon,
    required String label,
    required VoidCallback onTap,
  }) {
    IconData getIcon() {
      switch (icon) {
        case 'facebook':
          return FontAwesomeIcons.facebookF;
        case 'instagram':
          return FontAwesomeIcons.instagram;
        case 'whatsapp':
          return FontAwesomeIcons.whatsapp;
        case 'twitter':
          return FontAwesomeIcons.twitter;
        default:
          return FontAwesomeIcons.share;
      }
    }

    Color getIconColor() {
      switch (icon) {
        case 'facebook':
          return const Color(0xFF1877F2);
        case 'instagram':
          return const Color(0xFFE4405F);
        case 'whatsapp':
          return const Color(0xFF25D366);
        case 'twitter':
          return const Color(0xFF1DA1F2);
        default:
          return Colors.grey[800]!;
      }
    }

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Colors.grey[100],
              shape: BoxShape.circle,
            ),
            child: Center(
              child: FaIcon(
                getIcon(),
                size: 20,
                color: getIconColor(),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[700],
            ),
          ),
        ],
      ),
    );
  }
}
