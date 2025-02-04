import 'package:flutter/material.dart';
import '../widgets/discover_grid_item.dart';
import '../widgets/discover_bubble.dart';

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  final TextEditingController _searchController = TextEditingController();

  // AI content suggestions
  final List<String> _aiSuggestions = [
    'Transform my living room',
    'Cozy bedroom ideas',
    'Modern kitchen design',
    'Small space solutions',
    'Color palette generator',
    'Minimalist office setup',
    'Storage solutions',
    'Lighting ideas',
    'Plant arrangement',
    'Wall decor inspiration',
  ];

  // Sample video categories with thumbnails
  final List<Map<String, dynamic>> _categories = [
    {
      'title': 'Room Makeover',
      'thumbnailUrl': 'https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg',
      'videoCount': 156,
    },
    {
      'title': 'DIY Home Projects',
      'thumbnailUrl': 'https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg',
      'videoCount': 89,
    },
    {
      'title': 'Interior Design Tips',
      'thumbnailUrl': 'https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg',
      'videoCount': 234,
    },
    {
      'title': 'Home Organization',
      'thumbnailUrl': 'https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg',
      'videoCount': 167,
    },
    {
      'title': 'Furniture Flips',
      'thumbnailUrl': 'https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg',
      'videoCount': 145,
    },
    {
      'title': 'Before & After',
      'thumbnailUrl': 'https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg',
      'videoCount': 198,
    },
  ];

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Search Bar
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: TextField(
                controller: _searchController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Search videos',
                  hintStyle: const TextStyle(color: Colors.grey),
                  prefixIcon: const Icon(Icons.search, color: Colors.grey),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: Colors.grey[800]!),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: Colors.grey[800]!),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Colors.white),
                  ),
                  filled: true,
                  fillColor: Colors.grey[900],
                ),
              ),
            ),

            // AI Content Suggestions
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16.0),
              child: Text(
                'Try these AI ideas',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            SizedBox(
              height: 50,
              child: ListView.builder(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                scrollDirection: Axis.horizontal,
                itemCount: _aiSuggestions.length,
                itemBuilder: (context, index) {
                  return DiscoverBubble(
                    text: _aiSuggestions[index],
                    onTap: () {
                      // TODO: Handle AI suggestion tap
                      print('Using AI suggestion: ${_aiSuggestions[index]}');
                    },
                  );
                },
              ),
            ),

            // Categories Header
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Text(
                'Popular Categories',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),

            // Grid View
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  childAspectRatio: 1.0,
                  crossAxisSpacing: 8.0,
                  mainAxisSpacing: 8.0,
                ),
                itemCount: _categories.length,
                itemBuilder: (context, index) {
                  final category = _categories[index];
                  return DiscoverGridItem(
                    title:
                        '${category['title']} • ${category['videoCount']} videos',
                    thumbnailUrl: category['thumbnailUrl'],
                    onTap: () {
                      // TODO: Navigate to category videos
                      print('Viewing videos in category: ${category['title']}');
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
