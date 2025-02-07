import 'package:flutter/material.dart';
import 'package:flipsy/models/video.dart';
import 'package:flipsy/services/video_service.dart';
import 'package:flipsy/features/video/widgets/collection_selection_sheet.dart';
import 'package:firebase_auth/firebase_auth.dart';

class VideoPlayerControls extends StatefulWidget {
  final Video video;

  const VideoPlayerControls({Key? key, required this.video}) : super(key: key);

  @override
  _VideoPlayerControlsState createState() => _VideoPlayerControlsState();
}

class _VideoPlayerControlsState extends State<VideoPlayerControls> {
  late VideoService _videoService;
  String get _currentUserId => FirebaseAuth.instance.currentUser?.uid ?? '';

  @override
  void initState() {
    super.initState();
    _videoService = VideoService();
  }

  @override
  Widget build(BuildContext context) {
    return const SizedBox
        .shrink(); // Return empty widget since controls are in feed screen
  }
}
