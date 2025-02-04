import 'package:flutter/material.dart';

class UploadProgressDialog extends StatefulWidget {
  final double progress;
  final VoidCallback onCancel;
  final bool isCompleting;

  const UploadProgressDialog({
    super.key,
    required this.progress,
    required this.onCancel,
    this.isCompleting = false,
  });

  @override
  State<UploadProgressDialog> createState() => _UploadProgressDialogState();
}

class _UploadProgressDialogState extends State<UploadProgressDialog> {
  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.isCompleting) ...[
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              const Text(
                'Finalizing upload...',
                style: TextStyle(fontSize: 16),
              ),
            ] else ...[
              Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    height: 100,
                    width: 100,
                    child: CircularProgressIndicator(
                      value: widget.progress,
                      backgroundColor: Colors.grey[200],
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        Color(0xFFFF2B55),
                      ),
                      strokeWidth: 8,
                    ),
                  ),
                  Text(
                    '${(widget.progress * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const Text(
                'Uploading video...',
                style: TextStyle(fontSize: 16),
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
