import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../services/video_service.dart';
import '../../../models/video.dart';
import '../widgets/video_filter_sheet.dart';
import '../../../models/video_filter.dart';
import '../../navigation/screens/main_navigation_screen.dart';

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  final VideoService _videoService = VideoService();
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  VideoFilter _currentFilter = const VideoFilter();
  List<Video> _videos = [];
  bool _isLoading = false;
  bool _hasMore = true;
  DocumentSnapshot? _lastDocument;
  String? _error;

  @override
  void initState() {
    super.initState();
    Future.microtask(() => _loadVideos());
    _scrollController.addListener(_onScroll);

    // Run migration if needed
    _migrateVideosToTags();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadVideos({bool refresh = false}) async {
    if (_isLoading || (!_hasMore && !refresh)) return;

    print('DiscoverScreen: Loading videos with filter');
    print('DiscoverScreen: Current hashtags: ${_currentFilter.hashtags}');

    setState(() {
      _isLoading = true;
      if (refresh) {
        _videos = [];
        _lastDocument = null;
        _hasMore = true;
        _error = null;
      }
    });

    try {
      final videos = await _videoService.getFilteredVideoFeedBatch(
        filter: _currentFilter,
        startAfter: _lastDocument,
      );

      DocumentSnapshot? lastDoc;
      if (videos.isNotEmpty) {
        lastDoc = await _videoService.getLastDocument(videos.last.id);
      }

      setState(() {
        if (refresh) {
          _videos = videos;
        } else {
          _videos.addAll(videos);
        }
        _isLoading = false;
        _hasMore = videos.length == 10; // Assuming batch size is 10
        _lastDocument = lastDoc;
      });
    } catch (e) {
      setState(() {
        _error = 'Error loading videos: $e';
        _isLoading = false;
      });
    }
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadVideos();
    }
  }

  void _showFilterSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.9,
        maxChildSize: 0.9,
        minChildSize: 0.5,
        expand: false,
        builder: (context, scrollController) => VideoFilterSheet(
          initialFilter: _currentFilter,
          onFilterChanged: (VideoFilter? newFilter) {
            print('DiscoverScreen: Filter changed');
            print('DiscoverScreen: New hashtags: ${newFilter?.hashtags ?? {}}');
            setState(() {
              if (newFilter != null) {
                _currentFilter = newFilter;
              }
            });
            _loadVideos(refresh: true);
          },
        ),
      ),
    );
  }

  Future<void> _migrateVideosToTags() async {
    try {
      final result = await _videoService.migrateVideosToTags();
      print('Migration result: $result');

      if (result['updatedCount'] > 0) {
        // Refresh the videos list if any videos were updated
        await _loadVideos(refresh: true);
      }
    } catch (e) {
      print('Error migrating videos: $e');
      // Don't show error to user since this is a background operation
    }
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        // First check if there's any modal or dialog to dismiss
        final navigator = Navigator.of(context);
        if (navigator.canPop()) {
          navigator.pop();
          return false;
        }

        // Let the MainNavigationScreen handle the back button
        return true;
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              // Search and Filter Bar
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    // Search Field
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        decoration: InputDecoration(
                          hintText: 'Search videos',
                          prefixIcon: const Icon(Icons.search),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                        ),
                        onSubmitted: (value) {
                          // TODO: Implement search
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Filter Button
                    IconButton.filled(
                      onPressed: _showFilterSheet,
                      icon: Stack(
                        children: [
                          const Icon(Icons.tune),
                          if (_currentFilter.hasFilters)
                            Positioned(
                              right: 0,
                              top: 0,
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: const BoxDecoration(
                                  color: Colors.red,
                                  shape: BoxShape.circle,
                                ),
                                constraints: const BoxConstraints(
                                  minWidth: 8,
                                  minHeight: 8,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // Active Filters Chips
              if (_currentFilter.hasFilters)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (_currentFilter.budgetRange !=
                          VideoFilter.defaultBudgetRange)
                        Chip(
                          label: Text(
                            '\$${_currentFilter.budgetRange.start.toStringAsFixed(0)} - \$${_currentFilter.budgetRange.end.toStringAsFixed(0)}',
                          ),
                          onDeleted: () {
                            setState(() {
                              _currentFilter = _currentFilter.copyWith(
                                budgetRange: VideoFilter.defaultBudgetRange,
                              );
                            });
                            _loadVideos(refresh: true);
                          },
                        ),
                      if (_currentFilter.caloriesRange !=
                          VideoFilter.defaultCaloriesRange)
                        Chip(
                          label: Text(
                            '${_currentFilter.caloriesRange.start.toInt()} - ${_currentFilter.caloriesRange.end.toInt()} cal',
                          ),
                          onDeleted: () {
                            setState(() {
                              _currentFilter = _currentFilter.copyWith(
                                caloriesRange: VideoFilter.defaultCaloriesRange,
                              );
                            });
                            _loadVideos(refresh: true);
                          },
                        ),
                      if (_currentFilter.prepTimeRange !=
                          VideoFilter.defaultPrepTimeRange)
                        Chip(
                          label: Text(
                            '${_currentFilter.prepTimeRange.start.toInt()} - ${_currentFilter.prepTimeRange.end.toInt()} min',
                          ),
                          onDeleted: () {
                            setState(() {
                              _currentFilter = _currentFilter.copyWith(
                                prepTimeRange: VideoFilter.defaultPrepTimeRange,
                              );
                            });
                            _loadVideos(refresh: true);
                          },
                        ),
                      if (_currentFilter.minSpiciness != 0 ||
                          _currentFilter.maxSpiciness != 5)
                        Chip(
                          label: Text(
                            '${_currentFilter.minSpiciness} - ${_currentFilter.maxSpiciness} 🌶️',
                          ),
                          onDeleted: () {
                            setState(() {
                              _currentFilter = _currentFilter.copyWith(
                                minSpiciness: 0,
                                maxSpiciness: 5,
                              );
                            });
                            _loadVideos(refresh: true);
                          },
                        ),
                      ..._currentFilter.hashtags.map(
                        (tag) => Chip(
                          label: Text('#$tag'),
                          deleteIcon: const Icon(Icons.close, size: 18),
                          onDeleted: () {
                            setState(() {
                              _currentFilter =
                                  _currentFilter.removeHashtag(tag);
                            });
                            _loadVideos(refresh: true);
                          },
                        ),
                      ),
                    ],
                  ),
                ),

              // Videos Grid
              Expanded(
                child: _error != null
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(_error!),
                            const SizedBox(height: 16),
                            ElevatedButton(
                              onPressed: () {
                                setState(() {
                                  _currentFilter = const VideoFilter();
                                });
                                _loadVideos(refresh: true);
                              },
                              child: const Text('Clear filters'),
                            ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: () => _loadVideos(refresh: true),
                        child: GridView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.all(8),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            childAspectRatio: 0.8,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                          ),
                          itemCount:
                              _videos.length + (_isLoading && _hasMore ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (index >= _videos.length) {
                              return const Center(
                                child: CircularProgressIndicator(),
                              );
                            }

                            final video = _videos[index];
                            return GestureDetector(
                              onTap: () {
                                MainNavigationScreen.jumpToVideo(
                                  context,
                                  video.id,
                                  showBackButton: true,
                                );
                              },
                              child: Card(
                                clipBehavior: Clip.antiAlias,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    Image.network(
                                      video.thumbnailURL,
                                      fit: BoxFit.cover,
                                    ),
                                    // Video metadata overlay
                                    Positioned(
                                      left: 0,
                                      right: 0,
                                      bottom: 0,
                                      child: Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            begin: Alignment.bottomCenter,
                                            end: Alignment.topCenter,
                                            colors: [
                                              Colors.black.withOpacity(0.8),
                                              Colors.transparent,
                                            ],
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (video.budget > 0)
                                              Text(
                                                '\$${video.budget.toStringAsFixed(2)}',
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            if (video.calories > 0)
                                              Text(
                                                '${video.calories} cal',
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                ),
                                              ),
                                            if (video.prepTimeMinutes > 0)
                                              Text(
                                                '${video.prepTimeMinutes} min',
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                ),
                                              ),
                                            if (video.spiciness > 0)
                                              Text(
                                                '🌶️' * video.spiciness,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
