import 'package:flutter/material.dart';
import 'package:flipsy/models/video.dart';
import 'package:flipsy/models/collection.dart';
import 'package:flipsy/services/video_service.dart';

class CollectionSelectionSheet extends StatefulWidget {
  final Video video;
  final List<Collection> collections;
  final VoidCallback onCreateCollection;

  const CollectionSelectionSheet({
    Key? key,
    required this.video,
    required this.collections,
    required this.onCreateCollection,
  }) : super(key: key);

  @override
  State<CollectionSelectionSheet> createState() =>
      _CollectionSelectionSheetState();
}

class _CollectionSelectionSheetState extends State<CollectionSelectionSheet> {
  bool _isLoading = false;
  final _videoService = VideoService();

  Future<void> _addToCollection(Collection collection) async {
    setState(() => _isLoading = true);

    try {
      print('\nAdding video ${widget.video.id} to collection ${collection.id}');
      await _videoService.addVideoToCollection(
        collectionId: collection.id,
        videoId: widget.video.id,
      );
      print('Successfully added video to collection');

      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added to ${collection.name}')),
      );
    } catch (e) {
      print('Error adding video to collection: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error adding to collection: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Add to Collection',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          ListTile(
            leading: const CircleAvatar(
              backgroundColor: Colors.blue,
              child: Icon(Icons.add, color: Colors.white),
            ),
            title: const Text('Create New Collection'),
            onTap: widget.onCreateCollection,
          ),
          const SizedBox(height: 8),
          if (widget.collections.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'No collections yet',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.grey,
                  fontSize: 16,
                ),
              ),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: widget.collections.length,
                itemBuilder: (context, index) {
                  final collection = widget.collections[index];
                  return ListTile(
                    leading: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.grey[300],
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: collection.thumbnailUrl != null
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: Image.network(
                                collection.thumbnailUrl!,
                                fit: BoxFit.cover,
                              ),
                            )
                          : const Icon(Icons.collections, color: Colors.grey),
                    ),
                    title: Text(collection.name),
                    subtitle: Text('${collection.videoCount} videos'),
                    onTap:
                        _isLoading ? null : () => _addToCollection(collection),
                  );
                },
              ),
            ),
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }
}
