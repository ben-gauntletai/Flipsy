import 'package:flutter/material.dart';
import 'package:timeago/timeago.dart' as timeago;
import '../../../models/comment.dart';
import '../../../services/comment_service.dart';
import '../../../services/user_service.dart';
import '../../../widgets/user_avatar.dart';

class CommentBottomSheet extends StatefulWidget {
  final String videoId;
  final bool allowComments;

  const CommentBottomSheet({
    Key? key,
    required this.videoId,
    required this.allowComments,
  }) : super(key: key);

  static Future<void> show(
      BuildContext context, String videoId, bool allowComments) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final bottomNavHeight = kBottomNavigationBarHeight;
    final screenHeight = MediaQuery.of(context).size.height;
    final maxHeight = screenHeight * 0.7;

    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Padding(
        padding: EdgeInsets.only(bottom: bottomNavHeight + bottomPadding),
        child: Container(
          height: maxHeight,
          decoration: const BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
          ),
          child: CommentBottomSheet(
            videoId: videoId,
            allowComments: allowComments,
          ),
        ),
      ),
    );
  }

  @override
  State<CommentBottomSheet> createState() => _CommentBottomSheetState();
}

class _CommentBottomSheetState extends State<CommentBottomSheet> {
  final CommentService _commentService = CommentService();
  final TextEditingController _commentController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _isSubmitting = false;
  String? _replyToId;
  String? _replyToUsername;
  late Stream<List<Comment>> _commentStream;
  late Stream<int> _commentCountStream;

  @override
  void initState() {
    super.initState();
    print('CommentBottomSheet: Initializing for video ${widget.videoId}');
    _commentStream = _commentService.watchComments(widget.videoId);
    _commentCountStream = _commentService.watchCommentCount(widget.videoId);
  }

  @override
  void dispose() {
    print(
        'CommentBottomSheet: Disposing resources for video ${widget.videoId}');
    _commentController.dispose();
    _focusNode.dispose();
    _commentService.disposeVideo(widget.videoId);
    super.dispose();
  }

  Future<void> _submitComment() async {
    if (_commentController.text.trim().isEmpty || _isSubmitting) return;

    setState(() {
      _isSubmitting = true;
    });

    try {
      // Capitalize first letter of the comment
      String commentText = _commentController.text.trim();
      if (commentText.isNotEmpty) {
        commentText = commentText[0].toUpperCase() + commentText.substring(1);
      }

      await _commentService.addComment(
        widget.videoId,
        commentText,
        replyToId: _replyToId,
      );

      if (mounted) {
        _commentController.clear();
        setState(() {
          _replyToId = null;
          _replyToUsername = null;
          _isSubmitting = false;
        });
        _focusNode.unfocus();
      }
    } catch (e) {
      print('Error submitting comment: $e');
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to post comment')),
        );
      }
    }
  }

  void _cancelReply() {
    setState(() {
      _replyToId = null;
      _replyToUsername = null;
    });
    _commentController.clear();
    _focusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).viewInsets.bottom;

    return Column(
      children: [
        // Header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Colors.grey[800]!),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              StreamBuilder<int>(
                stream: _commentCountStream,
                builder: (context, snapshot) {
                  final count = snapshot.data ?? 0;
                  return Text(
                    '$count ${count == 1 ? 'comment' : 'comments'}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  );
                },
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.pop(context),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
        ),

        // Comments List
        Expanded(
          child: StreamBuilder<List<Comment>>(
            stream: _commentStream,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                print('CommentBottomSheet: Error in stream: ${snapshot.error}');
                return Center(
                  child: Text(
                    'Error loading comments: ${snapshot.error}',
                    style: const TextStyle(color: Colors.white),
                  ),
                );
              }

              if (!snapshot.hasData) {
                return const Center(
                  child: CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                );
              }

              final comments = snapshot.data!;
              print(
                  'CommentBottomSheet: Rendering ${comments.length} comments for video ${widget.videoId}');

              if (comments.isEmpty) {
                return const Center(
                  child: Text(
                    'No comments yet',
                    style: TextStyle(color: Colors.white54),
                  ),
                );
              }

              return ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: comments.length,
                itemBuilder: (context, index) {
                  final comment = comments[index];
                  return _CommentItem(
                    comment: comment,
                    onReply: (username) {
                      setState(() {
                        _replyToId = comment.id;
                        _replyToUsername = username;
                      });
                      _focusNode.requestFocus();
                    },
                  );
                },
              );
            },
          ),
        ),

        // Input Section
        if (widget.allowComments) ...[
          if (_replyToUsername != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Colors.grey[900],
              child: Row(
                children: [
                  Text(
                    'Replying to @$_replyToUsername',
                    style: const TextStyle(color: Colors.white54),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close,
                        size: 16, color: Colors.white54),
                    onPressed: _cancelReply,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
          Container(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 8 + bottomPadding),
            decoration: BoxDecoration(
              color: Colors.black,
              border: Border(
                top: BorderSide(color: Colors.grey[800]!),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _commentController,
                    focusNode: _focusNode,
                    textCapitalization: TextCapitalization.sentences,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Add a comment...',
                      hintStyle: const TextStyle(color: Colors.white54),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide(color: Colors.grey[800]!),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide(color: Colors.grey[800]!),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: const BorderSide(color: Colors.white24),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      filled: true,
                      fillColor: Colors.grey[900],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _isSubmitting ? null : _submitComment,
                  color: Colors.white,
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _CommentItem extends StatelessWidget {
  final Comment comment;
  final Function(String username) onReply;

  const _CommentItem({
    Key? key,
    required this.comment,
    required this.onReply,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Map<String, dynamic>>(
      stream: UserService().watchUserData(comment.userId),
      builder: (context, snapshot) {
        final userData = snapshot.data;
        final username = userData?['displayName'] ?? 'Unknown';
        final avatarURL = userData?['avatarURL'];

        return Padding(
          padding: EdgeInsets.only(
            left: 16 + (comment.depth * 20), // Indent replies
            right: 16,
            top: 8,
            bottom: 8,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              UserAvatar(
                avatarURL: avatarURL,
                radius: 16,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      username,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      comment.text,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text(
                          timeago.format(comment.createdAt),
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(width: 16),
                        GestureDetector(
                          onTap: () => onReply(username),
                          child: const Text(
                            'Reply',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              _CommentLikeButton(
                videoId: comment.videoId,
                commentId: comment.id,
                likesCount: comment.likesCount,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _CommentLikeButton extends StatelessWidget {
  final String videoId;
  final String commentId;
  final int likesCount;

  const _CommentLikeButton({
    Key? key,
    required this.videoId,
    required this.commentId,
    required this.likesCount,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final commentService = CommentService();

    return StreamBuilder<bool>(
      stream: commentService.watchCommentLikeStatus(videoId, commentId),
      builder: (context, snapshot) {
        final isLiked = snapshot.data ?? false;

        return Column(
          children: [
            IconButton(
              icon: Icon(
                isLiked ? Icons.favorite : Icons.favorite_border,
                size: 16,
                color: isLiked ? Colors.red : Colors.white54,
              ),
              onPressed: () {
                if (isLiked) {
                  commentService.unlikeComment(videoId, commentId);
                } else {
                  commentService.likeComment(videoId, commentId);
                }
              },
              constraints: const BoxConstraints(),
              padding: EdgeInsets.zero,
            ),
            const SizedBox(height: 2),
            Text(
              likesCount.toString(),
              style: const TextStyle(
                fontSize: 12,
                color: Colors.white54,
              ),
            ),
          ],
        );
      },
    );
  }
}
