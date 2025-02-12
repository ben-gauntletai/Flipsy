import 'package:flutter/material.dart';
import '../../../models/collection.dart';
import '../screens/collection_details_screen.dart';

class CollectionsGrid extends StatelessWidget {
  final List<Collection> collections;
  final VoidCallback? onCreateCollection;
  final bool isLoading;
  final Function(Collection) onCollectionSelected;

  const CollectionsGrid({
    super.key,
    required this.collections,
    this.onCreateCollection,
    required this.isLoading,
    required this.onCollectionSelected,
  });

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (collections.isEmpty) {
      if (onCreateCollection == null) {
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.collections_bookmark_outlined,
                  size: 48, color: Colors.grey[400]),
              const SizedBox(height: 16),
              Text(
                'No collections yet',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
        );
      }

      return GridView.builder(
        padding: const EdgeInsets.all(1),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          childAspectRatio: 0.8,
          crossAxisSpacing: 1,
          mainAxisSpacing: 1,
        ),
        itemCount: 1,
        itemBuilder: (context, index) => _buildNewCollectionCard(context),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(1),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.8,
        crossAxisSpacing: 1,
        mainAxisSpacing: 1,
      ),
      itemCount: collections.length + (onCreateCollection != null ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == 0 && onCreateCollection != null) {
          return GestureDetector(
            onTap: onCreateCollection,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.grey[100],
                border: Border.all(color: Colors.grey[300]!),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add_circle_outline,
                      size: 32, color: Colors.grey[600]),
                  const SizedBox(height: 8),
                  Text(
                    'Create\nCollection',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        final collection =
            collections[onCreateCollection != null ? index - 1 : index];
        return _buildCollectionCard(context, collection);
      },
    );
  }

  Widget _buildNewCollectionCard(BuildContext context) {
    return Material(
      color: Colors.grey[100],
      child: InkWell(
        onTap: onCreateCollection,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.add,
                size: 24,
                color: Theme.of(context).primaryColor,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'New',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).primaryColor,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCollectionCard(BuildContext context, Collection collection) {
    return Material(
      color: Colors.black,
      child: InkWell(
        onTap: () => onCollectionSelected(collection),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (collection.thumbnailUrl != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.network(
                  collection.thumbnailUrl!,
                  width: double.infinity,
                  height: double.infinity,
                  fit: BoxFit.cover,
                ),
              )
            else
              Container(
                color: Colors.grey[900],
                child: Icon(
                  Icons.photo_library,
                  size: 32,
                  color: Colors.grey[700],
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
                      Colors.transparent,
                      Colors.black.withOpacity(0.8),
                    ],
                  ),
                ),
              ),
            ),

            // Collection Info
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    collection.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        '${collection.videoCount} videos',
                        style: TextStyle(
                          color: Colors.grey[300],
                          fontSize: 10,
                        ),
                      ),
                      if (collection.isPrivate) ...[
                        const SizedBox(width: 4),
                        Icon(
                          Icons.lock,
                          color: Colors.grey[300],
                          size: 10,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
