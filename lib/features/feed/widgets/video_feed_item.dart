import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../../../models/video.dart';
import '../../../services/recipe_service.dart';
import '../../../widgets/user_avatar.dart';
import '../../../features/profile/screens/profile_screen.dart';
import '../../../features/feed/widgets/comment_bottom_sheet.dart';

class VideoFeedItem extends StatefulWidget {
  final Video video;
  final Map<String, dynamic>? userData;
  final bool isVisible;

  const VideoFeedItem({
    Key? key,
    required this.video,
    this.userData,
    this.isVisible = true,
  }) : super(key: key);

  @override
  _VideoFeedItemState createState() => _VideoFeedItemState();
}

class _VideoFeedItemState extends State<VideoFeedItem> {
  final RecipeService _recipeService = RecipeService();
  int _commentCount = 0;
  bool _localLikeState = false;
  int _localLikesCount = 0;
  VideoPlayerController? _videoController;
  bool _isPlaying = true;

  @override
  void initState() {
    super.initState();
    _localLikesCount = widget.video.likesCount;
  }

  void _navigateToProfile(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ProfileScreen(userId: widget.video.userId),
      ),
    );
  }

  void _handleLikeAction() {
    setState(() {
      _localLikeState = !_localLikeState;
      _localLikesCount += _localLikeState ? 1 : -1;
    });
    // TODO: Implement like action with backend
  }

  void _showComments(BuildContext context) {
    // Reset and pause video while comments are shown
    if (_videoController != null) {
      _videoController!.seekTo(Duration.zero);
      if (_isPlaying) {
        _videoController!.pause();
        _isPlaying = false;
      }
    }

    CommentBottomSheet.show(
      context,
      widget.video.id,
      widget.video.allowComments,
    ).then((_) {
      // Resume video when comments are closed if still visible
      if (widget.isVisible && mounted && _videoController != null) {
        _videoController!.play();
        _isPlaying = true;
      }
    });
  }

  void _showRecipePanel(BuildContext context) {
    // Reset and pause video while recipe panel is shown
    if (_videoController != null) {
      _videoController!.seekTo(Duration.zero);
      if (_isPlaying) {
        _videoController!.pause();
        _isPlaying = false;
      }
    }

    final analysis = widget.video.analysis;
    if (analysis == null) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.9,
        minChildSize: 0.5,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) => SingleChildScrollView(
          controller: scrollController,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Recipe Title
                Text(
                  widget.video.description ?? 'Recipe Details',
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 20),

                // Tools Section
                if (analysis.tools.isNotEmpty) ...[
                  const Text(
                    'Tools Needed',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: analysis.tools
                        .map((tool) => Chip(
                              label: Text(tool),
                              backgroundColor: Colors.grey[200],
                            ))
                        .toList(),
                  ),
                  const SizedBox(height: 20),
                ],

                // Ingredients Section
                if (analysis.ingredients.isNotEmpty) ...[
                  const Text(
                    'Ingredients',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 10),
                  ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: analysis.ingredients.length,
                    itemBuilder: (context, index) {
                      final ingredient = analysis.ingredients[index];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.check_circle_outline),
                        title: Text(ingredient),
                        trailing: IconButton(
                          icon: const Icon(Icons.swap_horiz),
                          onPressed: () =>
                              _showSubstitutionsDialog(context, ingredient),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 20),
                ],

                // Steps Section
                if (analysis.steps.isNotEmpty) ...[
                  const Text(
                    'Steps',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 10),
                  ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: analysis.steps.length,
                    itemBuilder: (context, index) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 24,
                              height: 24,
                              margin: const EdgeInsets.only(right: 12),
                              decoration: BoxDecoration(
                                color: Theme.of(context).primaryColor,
                                shape: BoxShape.circle,
                              ),
                              child: Center(
                                child: Text(
                                  '${index + 1}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                analysis.steps[index],
                                style: const TextStyle(fontSize: 16),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ).then((_) {
      // Resume video when recipe panel is closed if still visible
      if (widget.isVisible && mounted && _videoController != null) {
        _videoController!.play();
        _isPlaying = true;
      }
    });
  }

  Future<void> _showSubstitutionsDialog(
      BuildContext context, String ingredient) async {
    final recipeService = RecipeService();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: CircularProgressIndicator(),
      ),
    );

    try {
      final substitutions =
          await recipeService.generateSubstitutions(ingredient);
      if (!mounted) return;

      Navigator.pop(context); // Dismiss loading dialog

      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Substitutions for $ingredient'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: substitutions
                .map((sub) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text('• $sub'),
                    ))
                .toList(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;

      Navigator.pop(context); // Dismiss loading dialog

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to generate substitutions. Please try again.'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                widget.video.description ?? 'No description',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              // Right side with action buttons
              SafeArea(
                child: Container(
                  alignment: Alignment.bottomRight,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // User Avatar
                      GestureDetector(
                        onTap: () => _navigateToProfile(context),
                        child: UserAvatar(
                          avatarURL: widget.userData?['avatarURL'],
                          radius: 25,
                        ),
                      ),
                      const SizedBox(height: 20),

                      // Like Button
                      Column(
                        children: [
                          IconButton(
                            onPressed: _handleLikeAction,
                            icon: Icon(
                              _localLikeState
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                              color:
                                  _localLikeState ? Colors.red : Colors.white,
                              size: 32,
                            ),
                          ),
                          Text(
                            _localLikesCount.toString(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),

                      // Comment Button
                      Column(
                        children: [
                          IconButton(
                            onPressed: () => _showComments(context),
                            icon: const Icon(
                              Icons.comment,
                              color: Colors.white,
                              size: 32,
                            ),
                          ),
                          Text(
                            _commentCount.toString(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),

                      // Recipe Button
                      Column(
                        children: [
                          IconButton(
                            onPressed: () {
                              if (widget.video.analysis == null) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                        'Recipe details are not available yet. Please try again later.'),
                                    duration: Duration(seconds: 2),
                                  ),
                                );
                                return;
                              }
                              _showRecipePanel(context);
                            },
                            icon: const Icon(
                              Icons.restaurant_menu,
                              color: Colors.white,
                              size: 32,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.5),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Text(
                              'Recipe',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Rest of the widget code...
        ],
      ),
    );
  }
}
