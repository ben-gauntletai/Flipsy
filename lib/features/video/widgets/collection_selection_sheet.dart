import 'package:flutter/material.dart';
import 'package:flipsy/models/video.dart';
import 'package:flipsy/models/collection.dart';
import 'package:flipsy/services/video_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:async';

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
  final _firestore = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;
  List<Collection> _collections = [];
  StreamSubscription<List<Collection>>? _collectionsSubscription;
  Map<String, bool> _videoInCollection = {};
  Map<String, StreamSubscription> _videoSubscriptions = {};

  String get _currentUserId => _auth.currentUser?.uid ?? '';

  @override
  void initState() {
    super.initState();
    _collections = widget.collections;
    if (_currentUserId.isNotEmpty) {
      _startListeningToCollections();
      _checkVideoInCollections();
    } else {
      print('CollectionSelectionSheet: No current user ID available');
    }
  }

  void _startListeningToCollections() {
    print(
        'CollectionSelectionSheet: Starting to listen to collections for user $_currentUserId');
    _collectionsSubscription = _videoService
        .watchUserCollections(_currentUserId)
        .listen((collections) {
      if (mounted) {
        setState(() {
          _collections = collections;
          print(
              'CollectionSelectionSheet: Updated collections, count: ${collections.length}');
        });
        _checkVideoInCollections();
      }
    }, onError: (error) {
      print('CollectionSelectionSheet: Error watching collections: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Error loading collections'),
            backgroundColor: Colors.red,
          ),
        );
      }
    });
  }

  void _checkVideoInCollections() {
    print('CollectionSelectionSheet: Checking video in collections');
    // Cancel existing subscriptions
    for (var subscription in _videoSubscriptions.values) {
      subscription.cancel();
    }
    _videoSubscriptions.clear();

    // Start new subscriptions for each collection
    for (var collection in _collections) {
      final subscription = _firestore
          .collection('collections')
          .doc(collection.id)
          .collection('videos')
          .doc(widget.video.id)
          .snapshots()
          .listen((snapshot) {
        if (mounted) {
          setState(() {
            _videoInCollection[collection.id] = snapshot.exists;
            print(
                'CollectionSelectionSheet: Video ${widget.video.id} in collection ${collection.id}: ${snapshot.exists}');
          });
        }
      }, onError: (error) {
        print(
            'CollectionSelectionSheet: Error checking video in collection ${collection.id}: $error');
      });

      _videoSubscriptions[collection.id] = subscription;
    }
  }

  @override
  void dispose() {
    _collectionsSubscription?.cancel();
    for (var subscription in _videoSubscriptions.values) {
      subscription.cancel();
    }
    super.dispose();
  }

  Future<void> _addToCollection(Collection collection) async {
    setState(() => _isLoading = true);

    try {
      print(
          '\nCollectionSelectionSheet: Adding video ${widget.video.id} to collection ${collection.id}');
      await _videoService.addVideoToCollection(
        collectionId: collection.id,
        videoId: widget.video.id,
      );
      print('CollectionSelectionSheet: Successfully added video to collection');

      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added to ${collection.name}')),
      );
    } catch (e) {
      print('CollectionSelectionSheet: Error adding video to collection: $e');
      if (!mounted) return;

      String errorMessage = 'Error adding to collection';
      if (e.toString().contains('permission')) {
        errorMessage = 'You do not have permission to modify this collection';
      } else if (e.toString().contains('not found')) {
        errorMessage = 'Collection not found';
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(errorMessage),
          backgroundColor: Colors.red,
        ),
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
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 16),
          ListTile(
            leading: const CircleAvatar(
              backgroundColor: Colors.blue,
              child: Icon(Icons.add, color: Colors.white),
            ),
            title: const Text(
              'Create New Collection',
              style: TextStyle(color: Colors.black87),
            ),
            onTap: widget.onCreateCollection,
          ),
          const SizedBox(height: 8),
          if (_collections.isEmpty)
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
                itemCount: _collections.length,
                itemBuilder: (context, index) {
                  final collection = _collections[index];
                  final isInCollection =
                      _videoInCollection[collection.id] ?? false;

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
                    title: Text(
                      collection.name,
                      style: const TextStyle(color: Colors.black87),
                    ),
                    subtitle: Text(
                      '${collection.videoCount} videos',
                      style: const TextStyle(color: Colors.black54),
                    ),
                    trailing: isInCollection
                        ? const Icon(Icons.check_circle, color: Colors.green)
                        : null,
                    onTap: _isLoading || isInCollection
                        ? null
                        : () => _addToCollection(collection),
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
