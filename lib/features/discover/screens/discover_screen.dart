import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../services/video_service.dart';
import '../../../models/video.dart';
import '../widgets/video_filter_sheet.dart';
import '../../../models/video_filter.dart';
import '../../navigation/screens/main_navigation_screen.dart';
import '../../../services/user_service.dart';
import '../../profile/screens/profile_screen.dart';

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  final VideoService _videoService = VideoService();
  final UserService _userService = UserService();
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  VideoFilter _currentFilter = const VideoFilter();
  List<Video> _videos = [];
  List<Map<String, dynamic>> _users = [];
  bool _isLoading = false;
  bool _hasMore = true;
  DocumentSnapshot? _lastDocument;
  String? _error;
  bool _isSearchingUsers = false;

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

  void _handleSearch(String value) async {
    final searchText = value.trim();
    if (searchText.isEmpty) {
      setState(() {
        _users = [];
        _isSearchingUsers = false;
      });
      return;
    }

    // If search starts with @, search for users
    if (searchText.startsWith('@')) {
      setState(() {
        _isSearchingUsers = true;
        _isLoading = true;
      });

      try {
        final userQuery = searchText.substring(1); // Remove @ symbol
        final users = await _userService.searchUsers(userQuery);
        setState(() {
          _users = users;
          _isLoading = false;
        });
      } catch (e) {
        setState(() {
          _error = 'Error searching users: $e';
          _isLoading = false;
        });
      }
    } else if (searchText.startsWith('#')) {
      // Handle hashtag search
      setState(() {
        _isSearchingUsers = false;
      });
      try {
        setState(() {
          _currentFilter = _currentFilter
              .addHashtag(searchText.substring(1)); // Remove # symbol
          _searchController.clear();
        });
        _loadVideos(refresh: true);
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString()),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } else {
      // Handle semantic search (RAG)
      setState(() {
        _isSearchingUsers = false;
        _isLoading = true;
      });
      try {
        final videos = await _videoService.searchContent(searchText);
        print('Search returned ${videos.length} videos');

        setState(() {
          _videos = videos;
          _searchController.clear();
          _isLoading = false;
        });

        if (videos.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  'No relevant videos found. Try a different search term.'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      } catch (e) {
        print('Search error: $e');
        setState(() {
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error performing search: $e'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        final navigator = Navigator.of(context);
        if (navigator.canPop()) {
          navigator.pop();
          return false;
        }
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
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        decoration: InputDecoration(
                          hintText: 'Search @users or #hashtags',
                          prefixIcon: const Icon(Icons.search),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                        ),
                        onSubmitted: _handleSearch,
                        onChanged: (value) {
                          if (value.isEmpty) {
                            setState(() {
                              _users = [];
                              _isSearchingUsers = false;
                            });
                          } else if (value.startsWith('@')) {
                            _handleSearch(value);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Only show filter button when not searching users
                    if (!_isSearchingUsers)
                      Row(
                        children: [
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
                          const SizedBox(width: 8),
                          IconButton.filled(
                            onPressed: () {
                              setState(() {
                                _currentFilter = const VideoFilter();
                                _searchController.clear();
                                _users = [];
                                _isSearchingUsers = false;
                              });
                              _loadVideos(refresh: true);
                            },
                            icon: const Icon(Icons.refresh),
                            style: IconButton.styleFrom(
                              backgroundColor:
                                  Theme.of(context).colorScheme.secondary,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),

              // Active Filters Chips (only show when not searching users)
              if (!_isSearchingUsers && _currentFilter.hasFilters)
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

              // Content Area
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
                                  _error = null;
                                });
                                _loadVideos(refresh: true);
                              },
                              child: const Text('Clear filters'),
                            ),
                          ],
                        ),
                      )
                    : _isSearchingUsers
                        ? _buildUserSearchResults()
                        : RefreshIndicator(
                            onRefresh: () => _loadVideos(refresh: true),
                            child: _buildVideoGrid(),
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUserSearchResults() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_users.isEmpty) {
      return const Center(
        child: Text('No users found'),
      );
    }

    return ListView.builder(
      itemCount: _users.length,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemBuilder: (context, index) {
        final user = _users[index];
        return ListTile(
          leading: CircleAvatar(
            backgroundImage: user['avatarURL'] != null
                ? NetworkImage(user['avatarURL'])
                : null,
            child: user['avatarURL'] == null
                ? Text(user['displayName'][0].toUpperCase())
                : null,
          ),
          title: Text(user['displayName']),
          subtitle: Text(
            '${user['followersCount']} followers • ${user['totalLikes']} likes',
          ),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => ProfileScreen(userId: user['id']),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildVideoGrid() {
    return GridView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.8,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: _videos.length + (_isLoading && _hasMore ? 1 : 0),
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
                      crossAxisAlignment: CrossAxisAlignment.start,
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
    );
  }
}
