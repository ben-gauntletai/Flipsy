import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../../../services/video_service.dart';
import 'package:video_player/video_player.dart';
import '../widgets/upload_progress_dialog.dart';
import '../widgets/spiciness_selector.dart';
import '../../../models/video.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

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
  final ScrollController _scrollController = ScrollController();
  bool _keyboardVisible = false;
  File? _videoFile;
  bool _isUploading = false;
  VideoPlayerController? _videoController;
  String? _error;
  bool _allowComments = true;
  String _privacy = 'everyone';
  bool _isCompleting = false;
  int _spiciness = 0;
  Video? _video;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      setState(() {
        _keyboardVisible = MediaQuery.of(context).viewInsets.bottom > 0;
      });
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
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

      // Show upload progress dialog only for the file upload phase
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

      // Create video document with processing status
      print('Creating video document');
      _video = await _videoService.createVideoDocument(
        userId: user.uid,
        videoURL: videoURL,
        duration: metadata['duration'] / 1000,
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
      print('Video document created with ID: ${_video!.id}');

      // Close the upload progress dialog
      if (mounted) {
        Navigator.of(context).pop(); // Close progress dialog
      }

      // First dispose the video controller
      await _videoController?.dispose();
      _videoController = null;

      // Then reset the form state
      _resetForm();

      // Show success message
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Video uploaded! Processing will continue in the background.'),
            duration: Duration(seconds: 4),
          ),
        );
      }

      // Finally trigger navigation callback
      if (widget.onVideoUploaded != null) {
        widget.onVideoUploaded!(_video!.id);
      }
    } catch (e) {
      print('Error in upload process: $e');
      if (mounted) {
        setState(() {
          _error = 'Error uploading video: $e';
        });
        Navigator.of(context).pop(); // Close progress dialog
      }
    } finally {
      if (mounted) {
        setState(() {
          _isUploading = false;
        });
      }
    }
  }

  void _resetForm() {
    setState(() {
      _videoFile = null;
      _descriptionController.clear();
      _budgetController.clear();
      _caloriesController.clear();
      _prepTimeController.clear();
      _allowComments = true;
      _privacy = 'everyone';
      _spiciness = 0;
      _error = null;
      _videoController = null;
    });
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
    _keyboardVisible = MediaQuery.of(context).viewInsets.bottom > 0;

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
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.red, fontSize: 13),
                ),
              ),
            // Main content area
            Expanded(
              child: SingleChildScrollView(
                controller: _scrollController,
                reverse: true,
                physics: _keyboardVisible
                    ? const ClampingScrollPhysics()
                    : const NeverScrollableScrollPhysics(),
                child: Column(
                  children: [
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
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              border: Border(
                                bottom: BorderSide(color: Colors.grey[200]!),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      Icons.edit_note_rounded,
                                      size: 16,
                                      color: Colors.grey[600],
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      'Description',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.grey[700],
                                        letterSpacing: 0.3,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                TextField(
                                  controller: _descriptionController,
                                  decoration: InputDecoration(
                                    hintText:
                                        'Share the story behind your recipe...',
                                    hintStyle: TextStyle(
                                      color: Colors.grey[400],
                                      fontSize: 12,
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide:
                                          BorderSide(color: Colors.grey[300]!),
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide:
                                          BorderSide(color: Colors.grey[300]!),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: BorderSide(
                                          color:
                                              Theme.of(context).primaryColor),
                                    ),
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 10),
                                    isDense: true,
                                    prefixIcon: Icon(Icons.description_outlined,
                                        size: 18, color: Colors.grey[600]),
                                  ),
                                  maxLines: 2,
                                  minLines: 2,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    height: 1.2,
                                  ),
                                  enabled: !_isUploading,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Add #hashtags to help others discover your recipe',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey[500],
                                    height: 1.3,
                                  ),
                                ),
                                if (_descriptionController.text.isNotEmpty) ...[
                                  const SizedBox(height: 12),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: _descriptionController.text
                                        .split(' ')
                                        .where((word) => word.startsWith('#'))
                                        .map((tag) => Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 10,
                                                vertical: 6,
                                              ),
                                              decoration: BoxDecoration(
                                                color: Theme.of(context)
                                                    .primaryColor
                                                    .withOpacity(0.1),
                                                borderRadius:
                                                    BorderRadius.circular(16),
                                              ),
                                              child: Text(
                                                tag,
                                                style: TextStyle(
                                                  color: Theme.of(context)
                                                      .primaryColor,
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                            ))
                                        .toList(),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const Divider(height: 1),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.grey[50],
                              border: Border(
                                bottom: BorderSide(color: Colors.grey[200]!),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      Icons.restaurant_menu,
                                      size: 16,
                                      color: Colors.grey[600],
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      'Recipe Details',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.grey[700],
                                        letterSpacing: 0.3,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: _budgetController,
                                        decoration: InputDecoration(
                                          labelText: 'Cost',
                                          prefixIcon: Icon(
                                              Icons.attach_money_outlined,
                                              size: 18),
                                          border: OutlineInputBorder(
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            borderSide: BorderSide(
                                                color: Colors.grey[300]!),
                                          ),
                                          enabledBorder: OutlineInputBorder(
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            borderSide: BorderSide(
                                                color: Colors.grey[300]!),
                                          ),
                                          focusedBorder: OutlineInputBorder(
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            borderSide: BorderSide(
                                                color: Theme.of(context)
                                                    .primaryColor),
                                          ),
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                                  horizontal: 8, vertical: 8),
                                          isDense: true,
                                          floatingLabelBehavior:
                                              FloatingLabelBehavior.never,
                                          labelStyle: TextStyle(
                                            color: Colors.grey[600],
                                            fontSize: 13,
                                          ),
                                        ),
                                        keyboardType: const TextInputType
                                            .numberWithOptions(decimal: true),
                                        enabled: !_isUploading,
                                        style: const TextStyle(fontSize: 13),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: TextField(
                                        controller: _caloriesController,
                                        decoration: InputDecoration(
                                          labelText: 'Calories',
                                          prefixIcon: Icon(
                                              Icons
                                                  .local_fire_department_outlined,
                                              size: 18),
                                          suffixText: 'cal',
                                          border: OutlineInputBorder(
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            borderSide: BorderSide(
                                                color: Colors.grey[300]!),
                                          ),
                                          enabledBorder: OutlineInputBorder(
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            borderSide: BorderSide(
                                                color: Colors.grey[300]!),
                                          ),
                                          focusedBorder: OutlineInputBorder(
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            borderSide: BorderSide(
                                                color: Theme.of(context)
                                                    .primaryColor),
                                          ),
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                                  horizontal: 8, vertical: 8),
                                          isDense: true,
                                          floatingLabelBehavior:
                                              FloatingLabelBehavior.never,
                                          labelStyle: TextStyle(
                                            color: Colors.grey[600],
                                            fontSize: 13,
                                          ),
                                        ),
                                        keyboardType: TextInputType.number,
                                        enabled: !_isUploading,
                                        style: const TextStyle(fontSize: 13),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: _prepTimeController,
                                        decoration: InputDecoration(
                                          labelText: 'Prep Time',
                                          prefixIcon: Icon(Icons.timer_outlined,
                                              size: 18),
                                          suffixText: 'min',
                                          border: OutlineInputBorder(
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            borderSide: BorderSide(
                                                color: Colors.grey[300]!),
                                          ),
                                          enabledBorder: OutlineInputBorder(
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            borderSide: BorderSide(
                                                color: Colors.grey[300]!),
                                          ),
                                          focusedBorder: OutlineInputBorder(
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            borderSide: BorderSide(
                                                color: Theme.of(context)
                                                    .primaryColor),
                                          ),
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                                  horizontal: 8, vertical: 8),
                                          isDense: true,
                                          floatingLabelBehavior:
                                              FloatingLabelBehavior.never,
                                          labelStyle: TextStyle(
                                            color: Colors.grey[600],
                                            fontSize: 13,
                                          ),
                                        ),
                                        keyboardType: TextInputType.number,
                                        enabled: !_isUploading,
                                        style: const TextStyle(fontSize: 13),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 8, vertical: 6),
                                            decoration: BoxDecoration(
                                              border: Border.all(
                                                  color: Colors.grey[300]!),
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              color: Colors.white,
                                            ),
                                            child: SpicinessSelector(
                                              value: _spiciness,
                                              onChanged: (value) {
                                                setState(() {
                                                  _spiciness = value;
                                                });
                                              },
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const Divider(height: 1),
                          Row(
                            children: [
                              // Privacy Settings
                              Expanded(
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.grey[50],
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: ListTile(
                                    leading: Icon(Icons.lock_outline,
                                        size: 18, color: Colors.grey[700]),
                                    title: Text(
                                      'Privacy',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey[800],
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
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
                                            fontSize: 11,
                                          ),
                                        ),
                                        Icon(Icons.chevron_right,
                                            color: Colors.grey[400], size: 16),
                                      ],
                                    ),
                                    dense: true,
                                    visualDensity: const VisualDensity(
                                      horizontal: 0,
                                      vertical: -2,
                                    ),
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 8),
                                    minLeadingWidth: 20,
                                    horizontalTitleGap: 6,
                                    onTap: _isUploading
                                        ? null
                                        : () {
                                            showModalBottomSheet(
                                              context: context,
                                              builder: (context) => SafeArea(
                                                child: Column(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment
                                                          .stretch,
                                                  children: [
                                                    Padding(
                                                      padding:
                                                          const EdgeInsets.all(
                                                              12),
                                                      child: Text(
                                                        'Who can watch this video',
                                                        style: TextStyle(
                                                          fontSize: 16,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                          color:
                                                              Colors.grey[800],
                                                        ),
                                                      ),
                                                    ),
                                                    const Divider(height: 1),
                                                    ListTile(
                                                      title: const Text(
                                                          'Everyone'),
                                                      subtitle: const Text(
                                                          'Anyone on Flipsy can watch this video'),
                                                      trailing: _privacy ==
                                                              'everyone'
                                                          ? const Icon(
                                                              Icons.check,
                                                              color: Color(
                                                                  0xFFFF2B55))
                                                          : null,
                                                      onTap: () {
                                                        setState(() =>
                                                            _privacy =
                                                                'everyone');
                                                        Navigator.pop(context);
                                                      },
                                                    ),
                                                    ListTile(
                                                      title: const Text(
                                                          'Followers'),
                                                      subtitle: const Text(
                                                          'Only your followers can watch this video'),
                                                      trailing: _privacy ==
                                                              'followers'
                                                          ? const Icon(
                                                              Icons.check,
                                                              color: Color(
                                                                  0xFFFF2B55))
                                                          : null,
                                                      onTap: () {
                                                        setState(() =>
                                                            _privacy =
                                                                'followers');
                                                        Navigator.pop(context);
                                                      },
                                                    ),
                                                    ListTile(
                                                      title:
                                                          const Text('Private'),
                                                      subtitle: const Text(
                                                          'Only you can watch this video'),
                                                      trailing: _privacy ==
                                                              'private'
                                                          ? const Icon(
                                                              Icons.check,
                                                              color: Color(
                                                                  0xFFFF2B55))
                                                          : null,
                                                      onTap: () {
                                                        setState(() =>
                                                            _privacy =
                                                                'private');
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
                                ),
                              ),
                              const SizedBox(width: 8),
                              // Comments Setting
                              Expanded(
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.grey[50],
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: ListTile(
                                    leading: Icon(Icons.chat_bubble_outline,
                                        size: 18, color: Colors.grey[700]),
                                    title: Text(
                                      'Comments',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: Colors.grey[800],
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    trailing: Switch(
                                      value: _allowComments,
                                      onChanged: _isUploading
                                          ? null
                                          : (bool value) {
                                              setState(() {
                                                _allowComments = value;
                                              });
                                            },
                                      activeColor: const Color(0xFF34C759),
                                      materialTapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    dense: true,
                                    visualDensity: const VisualDensity(
                                      horizontal: 0,
                                      vertical: -2,
                                    ),
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 8),
                                    minLeadingWidth: 24,
                                    horizontalTitleGap: 8,
                                    onTap: _isUploading
                                        ? null
                                        : () {
                                            setState(() {
                                              _allowComments = !_allowComments;
                                            });
                                          },
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const Divider(height: 1),
                        ],
                      ),
                    ),
                    SizedBox(
                      height: MediaQuery.of(context).size.height * 0.35,
                      child: _videoController?.value.isInitialized ?? false
                          ? Container(
                              width: double.infinity,
                              height: double.infinity,
                              margin: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.black,
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.08),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Stack(
                                  children: [
                                    Center(
                                      child: AspectRatio(
                                        aspectRatio:
                                            _videoController!.value.aspectRatio,
                                        child: VideoPlayer(_videoController!),
                                      ),
                                    ),
                                    // Gradient overlay
                                    Positioned.fill(
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            begin: Alignment.topCenter,
                                            end: Alignment.bottomCenter,
                                            colors: [
                                              Colors.black.withOpacity(0.3),
                                              Colors.transparent,
                                              Colors.black.withOpacity(0.3),
                                            ],
                                            stops: const [0.0, 0.5, 1.0],
                                          ),
                                        ),
                                      ),
                                    ),
                                    // Video duration
                                    Positioned(
                                      top: 12,
                                      right: 12,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.black.withOpacity(0.5),
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          _formatDuration(
                                              _videoController!.value.duration),
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                    ),
                                    // Cover selection button
                                    Positioned(
                                      bottom: 12,
                                      left: 0,
                                      right: 0,
                                      child: Center(
                                        child: Material(
                                          color: Colors.transparent,
                                          child: InkWell(
                                            onTap: () {
                                              // TODO: Implement cover selection
                                            },
                                            borderRadius:
                                                BorderRadius.circular(24),
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 16,
                                                vertical: 10,
                                              ),
                                              decoration: BoxDecoration(
                                                color: Colors.black
                                                    .withOpacity(0.5),
                                                borderRadius:
                                                    BorderRadius.circular(24),
                                                border: Border.all(
                                                  color: Colors.white
                                                      .withOpacity(0.2),
                                                ),
                                              ),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: const [
                                                  Icon(
                                                    Icons.image_outlined,
                                                    color: Colors.white,
                                                    size: 18,
                                                  ),
                                                  SizedBox(width: 8),
                                                  Text(
                                                    'Select cover',
                                                    style: TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 13,
                                                      fontWeight:
                                                          FontWeight.w500,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : GestureDetector(
                              onTap: _isUploading ? null : _pickVideo,
                              child: Container(
                                margin: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.grey[50],
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: Colors.grey[200]!,
                                    width: 1,
                                  ),
                                ),
                                child: Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(16),
                                        decoration: BoxDecoration(
                                          color: Colors.grey[100],
                                          shape: BoxShape.circle,
                                        ),
                                        child: Icon(
                                          Icons.video_library_outlined,
                                          size: 32,
                                          color: Theme.of(context).primaryColor,
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        'Tap to select a video',
                                        style: TextStyle(
                                          color: Colors.grey[800],
                                          fontSize: 15,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        'MP4 or MOV up to 500MB',
                                        style: TextStyle(
                                          color: Colors.grey[600],
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                    ),
                  ].reversed.toList(),
                ),
              ),
            ),
            // Post button
            Container(
              padding: EdgeInsets.fromLTRB(12, 4, 12, 4 + bottomPadding),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border(
                  top: BorderSide(color: Colors.grey[200]!),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.03),
                    blurRadius: 8,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: ElevatedButton(
                onPressed:
                    _videoFile != null && !_isUploading ? _uploadVideo : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF2B55),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  disabledBackgroundColor: Colors.grey[300],
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  minimumSize: const Size(double.infinity, 0),
                ),
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.celebration_outlined,
                        size: 18,
                        color: _videoFile != null
                            ? Colors.white
                            : Colors.grey[400],
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Share',
                        style: TextStyle(
                          color: _videoFile != null
                              ? Colors.white
                              : Colors.grey[400],
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "${duration.inHours > 0 ? '${twoDigits(duration.inHours)}:' : ''}$twoDigitMinutes:$twoDigitSeconds";
  }
}
