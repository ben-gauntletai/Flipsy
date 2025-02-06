import 'package:flutter/material.dart';

class NumericRange {
  final double start;
  final double end;

  const NumericRange(this.start, this.end);

  factory NumericRange.fromRangeValues(RangeValues values) {
    return NumericRange(values.start, values.end);
  }

  RangeValues toRangeValues() {
    return RangeValues(start, end);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NumericRange &&
          runtimeType == other.runtimeType &&
          start == other.start &&
          end == other.end;

  @override
  int get hashCode => start.hashCode ^ end.hashCode;
}

class VideoFilter {
  static const NumericRange defaultBudgetRange = NumericRange(0, 100);
  static const NumericRange defaultCaloriesRange = NumericRange(0, 2000);
  static const NumericRange defaultPrepTimeRange = NumericRange(0, 180);
  static const NumericRange defaultSpicinessRange = NumericRange(0, 5);
  static const int maxHashtags = 10;

  final NumericRange budgetRange;
  final NumericRange caloriesRange;
  final NumericRange prepTimeRange;
  final int minSpiciness;
  final int maxSpiciness;
  final Set<String> hashtags;

  // Helper getters for bucket ranges
  List<String> get budgetBuckets {
    final List<String> buckets = [];
    final List<String> allBuckets = [
      '0-10',
      '10-25',
      '25-50',
      '50-100',
      '100+'
    ];

    for (var bucket in allBuckets) {
      final parts = bucket.split('-');
      final start = double.parse(parts[0]);
      final end = parts.length > 1 && !parts[1].endsWith('+')
          ? double.parse(parts[1])
          : double.infinity;

      if (end >= budgetRange.start && start <= budgetRange.end) {
        buckets.add(bucket);
      }
    }
    return buckets;
  }

  List<String> get caloriesBuckets {
    final List<String> buckets = [];
    final List<String> allBuckets = [
      '0-300',
      '300-600',
      '600-1000',
      '1000-1500',
      '1500+'
    ];

    for (var bucket in allBuckets) {
      final parts = bucket.split('-');
      final start = double.parse(parts[0]);
      final end = parts.length > 1 && !parts[1].endsWith('+')
          ? double.parse(parts[1])
          : double.infinity;

      if (end >= caloriesRange.start && start <= caloriesRange.end) {
        buckets.add(bucket);
      }
    }
    return buckets;
  }

  List<String> get prepTimeBuckets {
    final List<String> buckets = [];
    final List<String> allBuckets = [
      '0-15',
      '15-30',
      '30-60',
      '60-120',
      '120+'
    ];

    for (var bucket in allBuckets) {
      final parts = bucket.split('-');
      final start = double.parse(parts[0]);
      final end = parts.length > 1 && !parts[1].endsWith('+')
          ? double.parse(parts[1])
          : double.infinity;

      if (end >= prepTimeRange.start && start <= prepTimeRange.end) {
        buckets.add(bucket);
      }
    }
    return buckets;
  }

  const VideoFilter({
    this.budgetRange = defaultBudgetRange,
    this.caloriesRange = defaultCaloriesRange,
    this.prepTimeRange = defaultPrepTimeRange,
    this.minSpiciness = 0,
    this.maxSpiciness = 5,
    Set<String>? hashtags,
  }) : hashtags = hashtags ?? const {};

  bool get hasFilters {
    return budgetRange != defaultBudgetRange ||
        caloriesRange != defaultCaloriesRange ||
        prepTimeRange != defaultPrepTimeRange ||
        minSpiciness != 0 ||
        maxSpiciness != 5 ||
        hashtags.isNotEmpty;
  }

  static bool isValidHashtag(String tag) {
    return RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(tag);
  }

  static String normalizeHashtag(String tag) {
    final normalized = tag
        .replaceAll(RegExp(r'^#'), '')
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]'), '');

    print('VideoFilter: Normalizing hashtag: $tag -> $normalized');
    return normalized;
  }

  VideoFilter addHashtag(String tag) {
    if (hashtags.length >= maxHashtags) {
      throw Exception('Maximum of $maxHashtags hashtags allowed');
    }

    final normalized = normalizeHashtag(tag);
    if (normalized.isEmpty) {
      print('VideoFilter: Skipping empty hashtag');
      return this;
    }

    if (!isValidHashtag(normalized)) {
      throw Exception('Invalid hashtag format');
    }

    print('VideoFilter: Adding hashtag: $tag (normalized: $normalized)');
    final newHashtags = Set<String>.from(hashtags)..add(normalized);
    print('VideoFilter: Updated hashtags: $newHashtags');
    return copyWith(hashtags: newHashtags);
  }

  VideoFilter removeHashtag(String tag) {
    final normalized = normalizeHashtag(tag);
    print('VideoFilter: Removing hashtag: $tag (normalized: $normalized)');
    final newHashtags = Set<String>.from(hashtags)..remove(normalized);
    print('VideoFilter: Updated hashtags: $newHashtags');
    return copyWith(hashtags: newHashtags);
  }

  Map<String, dynamic> toFirestoreQuery() {
    final Map<String, dynamic> query = {};
    final List<String> filterTags = [];

    if (budgetRange != defaultBudgetRange) {
      filterTags.addAll(budgetBuckets.map((bucket) => 'budget_$bucket'));
    }

    if (caloriesRange != defaultCaloriesRange) {
      filterTags.addAll(caloriesBuckets.map((bucket) => 'calories_$bucket'));
    }

    if (prepTimeRange != defaultPrepTimeRange) {
      filterTags.addAll(prepTimeBuckets.map((bucket) => 'prep_$bucket'));
    }

    if (minSpiciness != 0 || maxSpiciness != 5) {
      for (int i = minSpiciness; i <= maxSpiciness; i++) {
        filterTags.add('spicy_$i');
      }
    }

    if (hashtags.isNotEmpty) {
      filterTags.addAll(hashtags.map((tag) => 'tag_$tag'));
    }

    if (filterTags.isNotEmpty) {
      query['tags'] = {
        'arrayContainsAny': filterTags,
      };
    }

    return query;
  }

  VideoFilter copyWith({
    NumericRange? budgetRange,
    NumericRange? caloriesRange,
    NumericRange? prepTimeRange,
    int? minSpiciness,
    int? maxSpiciness,
    Set<String>? hashtags,
  }) {
    return VideoFilter(
      budgetRange: budgetRange ?? this.budgetRange,
      caloriesRange: caloriesRange ?? this.caloriesRange,
      prepTimeRange: prepTimeRange ?? this.prepTimeRange,
      minSpiciness: minSpiciness ?? this.minSpiciness,
      maxSpiciness: maxSpiciness ?? this.maxSpiciness,
      hashtags: hashtags ?? this.hashtags,
    );
  }

  /// Generates a list of tags based on the current filter settings
  List<String> generateFilterTags() {
    print('VideoFilter: Generating filter tags');
    final List<String> tags = [];

    // Add budget tags
    print(
        'VideoFilter: Processing budget range: ${budgetRange.start} - ${budgetRange.end}');
    final budgetTags = _getBudgetBuckets(budgetRange);
    print('VideoFilter: Generated budget tags: $budgetTags');
    tags.addAll(budgetTags.map((bucket) => 'budget_$bucket'));

    // Add calories tags
    print(
        'VideoFilter: Processing calories range: ${caloriesRange.start} - ${caloriesRange.end}');
    final calorieTags = _getCaloriesBuckets(caloriesRange);
    print('VideoFilter: Generated calorie tags: $calorieTags');
    tags.addAll(calorieTags.map((bucket) => 'calories_$bucket'));

    // Add prep time tags
    print(
        'VideoFilter: Processing prep time range: ${prepTimeRange.start} - ${prepTimeRange.end}');
    final prepTimeTags = _getPrepTimeBuckets(prepTimeRange);
    print('VideoFilter: Generated prep time tags: $prepTimeTags');
    tags.addAll(prepTimeTags.map((bucket) => 'prep_$bucket'));

    // Add spiciness tags
    print(
        'VideoFilter: Processing spiciness range: $minSpiciness - $maxSpiciness');
    for (var i = minSpiciness; i <= maxSpiciness; i++) {
      tags.add('spicy_$i');
    }

    print('VideoFilter: Final generated tags: $tags');
    return tags;
  }

  /// Helper method to get budget buckets for a range
  List<String> _getBudgetBuckets(NumericRange range) {
    print(
        'VideoFilter: Getting budget buckets for range: ${range.start} - ${range.end}');
    final List<String> buckets = [];
    final ranges = ['0-10', '10-25', '25-50', '50-100', '100+'];

    for (final bucket in ranges) {
      try {
        print('VideoFilter: Processing budget bucket: $bucket');
        final parts = bucket.split('-');
        print('VideoFilter: Split parts: $parts');
        final start = double.parse(parts[0].replaceAll('+', ''));
        final end = parts.length == 1 && parts[0].endsWith('+')
            ? double.infinity
            : double.parse(parts[1]);
        print('VideoFilter: Parsed range: $start - $end');

        if (range.end >= start && range.start <= end) {
          print('VideoFilter: Adding bucket: $bucket');
          buckets.add(bucket);
        }
      } catch (e) {
        print('VideoFilter: Error processing budget bucket $bucket: $e');
        rethrow;
      }
    }

    print('VideoFilter: Returning budget buckets: $buckets');
    return buckets;
  }

  /// Helper method to get calories buckets for a range
  List<String> _getCaloriesBuckets(NumericRange range) {
    print(
        'VideoFilter: Getting calories buckets for range: ${range.start} - ${range.end}');
    final List<String> buckets = [];
    final ranges = ['0-300', '300-600', '600-1000', '1000-1500', '1500+'];

    for (final bucket in ranges) {
      try {
        print('VideoFilter: Processing calories bucket: $bucket');
        final parts = bucket.split('-');
        print('VideoFilter: Split parts: $parts');
        final start = double.parse(parts[0].replaceAll('+', ''));
        final end = parts.length == 1 && parts[0].endsWith('+')
            ? double.infinity
            : double.parse(parts[1]);
        print('VideoFilter: Parsed range: $start - $end');

        if (range.end >= start && range.start <= end) {
          print('VideoFilter: Adding bucket: $bucket');
          buckets.add(bucket);
        }
      } catch (e) {
        print('VideoFilter: Error processing calories bucket $bucket: $e');
        rethrow;
      }
    }

    print('VideoFilter: Returning calories buckets: $buckets');
    return buckets;
  }

  /// Helper method to get prep time buckets for a range
  List<String> _getPrepTimeBuckets(NumericRange range) {
    print(
        'VideoFilter: Getting prep time buckets for range: ${range.start} - ${range.end}');
    final List<String> buckets = [];
    final ranges = ['0-15', '15-30', '30-60', '60-120', '120+'];

    for (final bucket in ranges) {
      try {
        print('VideoFilter: Processing prep time bucket: $bucket');
        final parts = bucket.split('-');
        print('VideoFilter: Split parts: $parts');
        final start = double.parse(parts[0].replaceAll('+', ''));
        final end = parts.length == 1 && parts[0].endsWith('+')
            ? double.infinity
            : double.parse(parts[1]);
        print('VideoFilter: Parsed range: $start - $end');

        if (range.end >= start && range.start <= end) {
          print('VideoFilter: Adding bucket: $bucket');
          buckets.add(bucket);
        }
      } catch (e) {
        print('VideoFilter: Error processing prep time bucket $bucket: $e');
        rethrow;
      }
    }

    print('VideoFilter: Returning prep time buckets: $buckets');
    return buckets;
  }
}
