import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:async';

class UploadProgressDialog extends StatefulWidget {
  final double progress;
  final VoidCallback onCancel;
  final bool isCompleting;
  final String? videoId;

  const UploadProgressDialog({
    super.key,
    required this.progress,
    required this.onCancel,
    this.isCompleting = false,
    this.videoId,
  });

  @override
  State<UploadProgressDialog> createState() => _UploadProgressDialogState();
}

class _UploadProgressDialogState extends State<UploadProgressDialog>
    with SingleTickerProviderStateMixin {
  StreamSubscription<DocumentSnapshot>? _processingSubscription;
  late AnimationController _dotsAnimationController;
  int _dotCount = 0;
  Timer? _dotsTimer;

  @override
  void initState() {
    super.initState();
    _startProcessingListener();
    _dotsAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..repeat(reverse: true);
    _startDotsAnimation();
  }

  @override
  void dispose() {
    _processingSubscription?.cancel();
    _dotsAnimationController.dispose();
    _dotsTimer?.cancel();
    super.dispose();
  }

  void _startDotsAnimation() {
    _dotsTimer?.cancel();
    _dotsTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (mounted) {
        setState(() {
          _dotCount = (_dotCount + 1) % 4;
        });
      }
    });
  }

  void _startProcessingListener() {
    if (widget.videoId != null && widget.isCompleting) {
      print('Starting processing listener for video ${widget.videoId}');
      print('Current isCompleting state: ${widget.isCompleting}');

      _processingSubscription = FirebaseFirestore.instance
          .collection('videos')
          .doc(widget.videoId)
          .snapshots()
          .listen((snapshot) {
        if (!mounted) return;

        final status = snapshot.data()?['processingStatus'] as String?;
        print('Processing status update received: $status');
        print('Current isCompleting state: ${widget.isCompleting}');

        if (status == 'completed' || status == 'failed') {
          print('Processing finished with status: $status');
          Navigator.of(context).pop();
        }
      });
    }
  }

  @override
  void didUpdateWidget(UploadProgressDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    print(
        'Dialog widget updated - videoId: ${widget.videoId}, isCompleting: ${widget.isCompleting}, progress: ${widget.progress}');

    // If we've just completed the upload (progress = 100%) and isCompleting is true
    if (widget.progress >= 1.0 &&
        widget.isCompleting &&
        !oldWidget.isCompleting) {
      print('Upload complete, transitioning to processing state');
      _startProcessingListener();
    }

    if (widget.videoId != oldWidget.videoId ||
        widget.isCompleting != oldWidget.isCompleting) {
      print('Relevant props changed, restarting processing listener');
      _processingSubscription?.cancel();
      _startProcessingListener();
    }
  }

  String _getStatusMessage() {
    if (!widget.isCompleting) {
      if (widget.progress >= 1.0) {
        return 'Processing video${'.' * _dotCount}';
      }
      return 'Uploading video...';
    }
    return 'Processing video${'.' * _dotCount}';
  }

  Widget _buildProgressIndicator() {
    if (!widget.isCompleting && widget.progress < 1.0) {
      return CircularProgressIndicator(
        value: widget.progress,
        backgroundColor: Colors.grey[200],
        valueColor: const AlwaysStoppedAnimation<Color>(
          Color(0xFFFF2B55),
        ),
        strokeWidth: 8,
      );
    } else {
      return Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                _getStatusMessage(),
                style: const TextStyle(fontSize: 16),
              ),
              if (widget.isCompleting)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 500),
                  child: Text(
                    '.' * _dotCount,
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
            ],
          ),
          if (widget.isCompleting) ...[
            const SizedBox(height: 8),
            Text(
              'This may take a few minutes',
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey[600],
              ),
            ),
          ],
        ],
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!widget.isCompleting && widget.progress < 1.0)
              SizedBox(
                height: 100,
                width: 100,
                child: Center(
                  child: _buildProgressIndicator(),
                ),
              )
            else
              _buildProgressIndicator(),
            if (!widget.isCompleting && widget.progress < 1.0) ...[
              const SizedBox(height: 20),
              Text(
                _getStatusMessage(),
                style: const TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 20),
              TextButton(
                onPressed: widget.onCancel,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.grey[700],
                ),
                child: const Text('Cancel'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
