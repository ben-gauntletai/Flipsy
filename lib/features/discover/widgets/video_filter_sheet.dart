import 'package:flutter/material.dart';
import '../models/video_filter.dart';

class VideoFilterSheet extends StatefulWidget {
  final VideoFilter initialFilter;
  final ValueChanged<VideoFilter> onFilterChanged;

  const VideoFilterSheet({
    super.key,
    required this.initialFilter,
    required this.onFilterChanged,
  });

  @override
  State<VideoFilterSheet> createState() => _VideoFilterSheetState();
}

class _VideoFilterSheetState extends State<VideoFilterSheet> {
  late VideoFilter _currentFilter;
  final TextEditingController _hashtagController = TextEditingController();
  final FocusNode _hashtagFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _currentFilter = widget.initialFilter;
  }

  @override
  void dispose() {
    _hashtagController.dispose();
    _hashtagFocusNode.dispose();
    super.dispose();
  }

  void _addHashtag(String hashtag) {
    if (hashtag.isEmpty) return;

    // Remove # if present and trim whitespace
    hashtag = hashtag.trim();
    if (hashtag.startsWith('#')) {
      hashtag = hashtag.substring(1);
    }

    if (hashtag.isNotEmpty) {
      setState(() {
        final newHashtags = Set<String>.from(_currentFilter.hashtags)
          ..add(hashtag);
        _currentFilter = _currentFilter.copyWith(hashtags: newHashtags);
        widget.onFilterChanged(_currentFilter);
      });
    }

    _hashtagController.clear();
  }

  void _removeHashtag(String hashtag) {
    setState(() {
      final newHashtags = Set<String>.from(_currentFilter.hashtags)
        ..remove(hashtag);
      _currentFilter = _currentFilter.copyWith(hashtags: newHashtags);
      widget.onFilterChanged(_currentFilter);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Filter Videos',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _currentFilter = const VideoFilter();
                      widget.onFilterChanged(_currentFilter);
                    });
                  },
                  child: const Text('Reset'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // Scrollable content
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                // Budget Range
                _buildRangeSlider(
                  title: 'Budget Range',
                  subtitle:
                      '\$${_currentFilter.budgetRange?.start.toStringAsFixed(0) ?? "0"} - \$${_currentFilter.budgetRange?.end.toStringAsFixed(0) ?? "100"}',
                  range: _currentFilter.budgetRange ??
                      VideoFilter.defaultBudgetRange,
                  min: VideoFilter.defaultBudgetRange.start,
                  max: VideoFilter.defaultBudgetRange.end,
                  onChanged: (range) {
                    setState(() {
                      _currentFilter =
                          _currentFilter.copyWith(budgetRange: range);
                      widget.onFilterChanged(_currentFilter);
                    });
                  },
                ),
                const Divider(),
                // Calories Range
                _buildRangeSlider(
                  title: 'Calories Range',
                  subtitle:
                      '${_currentFilter.caloriesRange?.start.toInt() ?? "0"} - ${_currentFilter.caloriesRange?.end.toInt() ?? "2000"} cal',
                  range: _currentFilter.caloriesRange ??
                      VideoFilter.defaultCaloriesRange,
                  min: VideoFilter.defaultCaloriesRange.start,
                  max: VideoFilter.defaultCaloriesRange.end,
                  onChanged: (range) {
                    setState(() {
                      _currentFilter =
                          _currentFilter.copyWith(caloriesRange: range);
                      widget.onFilterChanged(_currentFilter);
                    });
                  },
                ),
                const Divider(),
                // Prep Time Range
                _buildRangeSlider(
                  title: 'Prep Time Range',
                  subtitle:
                      '${_currentFilter.prepTimeRange?.start.toInt() ?? "0"} - ${_currentFilter.prepTimeRange?.end.toInt() ?? "180"} min',
                  range: _currentFilter.prepTimeRange ??
                      VideoFilter.defaultPrepTimeRange,
                  min: VideoFilter.defaultPrepTimeRange.start,
                  max: VideoFilter.defaultPrepTimeRange.end,
                  onChanged: (range) {
                    setState(() {
                      _currentFilter =
                          _currentFilter.copyWith(prepTimeRange: range);
                      widget.onFilterChanged(_currentFilter);
                    });
                  },
                ),
                const Divider(),
                // Spiciness Range
                _buildRangeSlider(
                  title: 'Spiciness Range',
                  subtitle:
                      '${_currentFilter.minSpiciness ?? 0} - ${_currentFilter.maxSpiciness ?? 5} peppers',
                  range: RangeValues(
                    (_currentFilter.minSpiciness ?? 0).toDouble(),
                    (_currentFilter.maxSpiciness ?? 5).toDouble(),
                  ),
                  min: VideoFilter.defaultSpicinessRange.start,
                  max: VideoFilter.defaultSpicinessRange.end,
                  divisions: 5,
                  onChanged: (range) {
                    setState(() {
                      _currentFilter = _currentFilter.copyWith(
                        minSpiciness: range.start.toInt(),
                        maxSpiciness: range.end.toInt(),
                      );
                      widget.onFilterChanged(_currentFilter);
                    });
                  },
                ),
                const Divider(),
                // Hashtags
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Hashtags',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _hashtagController,
                      focusNode: _hashtagFocusNode,
                      decoration: const InputDecoration(
                        hintText: 'Add hashtag (e.g., spicy, quick)',
                        prefixText: '#',
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: _addHashtag,
                      textInputAction: TextInputAction.done,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _currentFilter.hashtags.map((hashtag) {
                        return Chip(
                          label: Text('#$hashtag'),
                          onDeleted: () => _removeHashtag(hashtag),
                          backgroundColor:
                              Theme.of(context).colorScheme.primaryContainer,
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRangeSlider({
    required String title,
    required String subtitle,
    required RangeValues range,
    required double min,
    required double max,
    required ValueChanged<RangeValues> onChanged,
    int? divisions,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: TextStyle(
            fontSize: 14,
            color: Colors.grey[600],
          ),
        ),
        RangeSlider(
          values: range,
          min: min,
          max: max,
          divisions: divisions,
          labels: RangeLabels(
            range.start.toStringAsFixed(0),
            range.end.toStringAsFixed(0),
          ),
          onChanged: onChanged,
        ),
      ],
    );
  }
}
