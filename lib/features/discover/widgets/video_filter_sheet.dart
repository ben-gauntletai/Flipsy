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
  late VideoFilter _tempFilter; // Temporary filter for storing changes
  final TextEditingController _hashtagController = TextEditingController();
  final FocusNode _hashtagFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _currentFilter = widget.initialFilter;
    _tempFilter = widget.initialFilter; // Initialize temp filter
  }

  @override
  void dispose() {
    _hashtagController.dispose();
    _hashtagFocusNode.dispose();
    super.dispose();
  }

  void _addHashtag(String hashtag) {
    if (hashtag.isEmpty) return;

    print('VideoFilterSheet: Adding hashtag: $hashtag');
    setState(() {
      _tempFilter = _tempFilter.addHashtag(hashtag);
    });
    print('VideoFilterSheet: Current hashtags: ${_tempFilter.hashtags}');

    _hashtagController.clear();
    _hashtagFocusNode.requestFocus(); // Keep focus for adding more hashtags
  }

  void _removeHashtag(String hashtag) {
    print('VideoFilterSheet: Removing hashtag: $hashtag');
    setState(() {
      _tempFilter = _tempFilter.removeHashtag(hashtag);
    });
    print('VideoFilterSheet: Current hashtags: ${_tempFilter.hashtags}');
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: keyboardHeight),
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
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
                        print('VideoFilterSheet: Resetting filter');
                        setState(() {
                          _tempFilter = const VideoFilter();
                        });
                        print(
                            'VideoFilterSheet: Filter reset, hashtags: ${_tempFilter.hashtags}');
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
                          '\$${_tempFilter.budgetRange?.start.toStringAsFixed(0) ?? "0"} - \$${_tempFilter.budgetRange?.end.toStringAsFixed(0) ?? "100"}',
                      range: _tempFilter.budgetRange ??
                          VideoFilter.defaultBudgetRange,
                      min: VideoFilter.defaultBudgetRange.start,
                      max: VideoFilter.defaultBudgetRange.end,
                      onChanged: (range) {
                        setState(() {
                          _tempFilter =
                              _tempFilter.copyWith(budgetRange: range);
                        });
                      },
                    ),
                    const Divider(),
                    // Calories Range
                    _buildRangeSlider(
                      title: 'Calories Range',
                      subtitle:
                          '${_tempFilter.caloriesRange?.start.toInt() ?? "0"} - ${_tempFilter.caloriesRange?.end.toInt() ?? "2000"} cal',
                      range: _tempFilter.caloriesRange ??
                          VideoFilter.defaultCaloriesRange,
                      min: VideoFilter.defaultCaloriesRange.start,
                      max: VideoFilter.defaultCaloriesRange.end,
                      onChanged: (range) {
                        setState(() {
                          _tempFilter =
                              _tempFilter.copyWith(caloriesRange: range);
                        });
                      },
                    ),
                    const Divider(),
                    // Prep Time Range
                    _buildRangeSlider(
                      title: 'Prep Time Range',
                      subtitle:
                          '${_tempFilter.prepTimeRange?.start.toInt() ?? "0"} - ${_tempFilter.prepTimeRange?.end.toInt() ?? "180"} min',
                      range: _tempFilter.prepTimeRange ??
                          VideoFilter.defaultPrepTimeRange,
                      min: VideoFilter.defaultPrepTimeRange.start,
                      max: VideoFilter.defaultPrepTimeRange.end,
                      onChanged: (range) {
                        setState(() {
                          _tempFilter =
                              _tempFilter.copyWith(prepTimeRange: range);
                        });
                      },
                    ),
                    const Divider(),
                    // Spiciness Range
                    _buildRangeSlider(
                      title: 'Spiciness Range',
                      subtitle:
                          '${_tempFilter.minSpiciness ?? 0} - ${_tempFilter.maxSpiciness ?? 5} peppers',
                      range: RangeValues(
                        (_tempFilter.minSpiciness ?? 0).toDouble(),
                        (_tempFilter.maxSpiciness ?? 5).toDouble(),
                      ),
                      min: VideoFilter.defaultSpicinessRange.start,
                      max: VideoFilter.defaultSpicinessRange.end,
                      divisions: 5,
                      onChanged: (range) {
                        setState(() {
                          _tempFilter = _tempFilter.copyWith(
                            minSpiciness: range.start.toInt(),
                            maxSpiciness: range.end.toInt(),
                          );
                        });
                      },
                    ),
                    const Divider(),
                    // Hashtags
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
                      decoration: InputDecoration(
                        hintText: 'Add hashtag (e.g., spicy, quick)',
                        prefixText: '#',
                        border: OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.add),
                          onPressed: () {
                            if (_hashtagController.text.isNotEmpty) {
                              _addHashtag(_hashtagController.text);
                            }
                          },
                        ),
                      ),
                      onSubmitted: (value) {
                        if (value.isNotEmpty) {
                          _addHashtag(value);
                        }
                      },
                      textInputAction: TextInputAction.done,
                      onEditingComplete: () {
                        if (_hashtagController.text.isNotEmpty) {
                          _addHashtag(_hashtagController.text);
                        }
                      },
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _tempFilter.hashtags.map((hashtag) {
                        return Chip(
                          label: Text('#$hashtag'),
                          onDeleted: () => _removeHashtag(hashtag),
                          backgroundColor:
                              Theme.of(context).colorScheme.primaryContainer,
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
              // Apply Button
              Container(
                padding: EdgeInsets.fromLTRB(16, 8, 16, bottomPadding + 16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 5,
                      offset: const Offset(0, -3),
                    ),
                  ],
                ),
                child: ElevatedButton(
                  onPressed: () {
                    widget.onFilterChanged(_tempFilter);
                    Navigator.pop(context);
                  },
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 48),
                    backgroundColor: Theme.of(context).primaryColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text(
                    'Apply Filters',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
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
