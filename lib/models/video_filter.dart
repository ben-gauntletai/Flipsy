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
      try {
        if (bucket.endsWith('+')) {
          final start = double.parse(bucket.substring(0, bucket.length - 1));
          if (budgetRange.end >= start) {
            buckets.add(bucket);
          }
          continue;
        }

        final parts = bucket.split('-');
        if (parts.length != 2) continue;

        final start = double.parse(parts[0]);
        final end = double.parse(parts[1]);

        if (budgetRange.start <= end && budgetRange.end > start) {
          buckets.add(bucket);
        }
      } catch (e) {
        print('Error processing budget bucket: $e');
        continue;
      }
    }
    print(
        'VideoFilter: Generated budget buckets: $buckets for range ${budgetRange.start}-${budgetRange.end}');
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
      try {
        if (bucket.endsWith('+')) {
          final start = double.parse(bucket.substring(0, bucket.length - 1));
          if (caloriesRange.end >= start) {
            buckets.add(bucket);
          }
          continue;
        }

        final parts = bucket.split('-');
        if (parts.length != 2) continue;

        final start = double.parse(parts[0]);
        final end = double.parse(parts[1]);

        if (end >= caloriesRange.start && start <= caloriesRange.end) {
          buckets.add(bucket);
        }
      } catch (e) {
        print('Error processing calories bucket: $e');
        continue;
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
      try {
        if (bucket.endsWith('+')) {
          final start = double.parse(bucket.substring(0, bucket.length - 1));
          if (prepTimeRange.end >= start) {
            buckets.add(bucket);
          }
          continue;
        }

        final parts = bucket.split('-');
        if (parts.length != 2) continue;

        final start = double.parse(parts[0]);
        final end = double.parse(parts[1]);

        if (end >= prepTimeRange.start && start <= prepTimeRange.end) {
          buckets.add(bucket);
        }
      } catch (e) {
        print('Error processing prep time bucket: $e');
        continue;
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
    final List<Map<String, dynamic>> conditions = [];

    // Add budget condition if range is not default
    if (budgetRange != defaultBudgetRange) {
      final budgetTags =
          budgetBuckets.map((bucket) => 'budget_$bucket').toList();
      if (budgetTags.isNotEmpty) {
        conditions.add({
          'tags': {
            'arrayContainsAny': budgetTags,
          }
        });
      }
    }

    // Add calories condition if range is not default
    if (caloriesRange != defaultCaloriesRange) {
      final calorieTags =
          caloriesBuckets.map((bucket) => 'calories_$bucket').toList();
      if (calorieTags.isNotEmpty) {
        conditions.add({
          'tags': {
            'arrayContainsAny': calorieTags,
          }
        });
      }
    }

    // Add prep time condition if range is not default
    if (prepTimeRange != defaultPrepTimeRange) {
      final prepTimeTags =
          prepTimeBuckets.map((bucket) => 'prep_$bucket').toList();
      if (prepTimeTags.isNotEmpty) {
        conditions.add({
          'tags': {
            'arrayContainsAny': prepTimeTags,
          }
        });
      }
    }

    // Add spiciness condition if not default range
    if (minSpiciness != 0 || maxSpiciness != 5) {
      final List<String> spicyTags = [];
      for (int i = minSpiciness; i <= maxSpiciness; i++) {
        spicyTags.add('spicy_$i');
      }
      conditions.add({
        'tags': {
          'arrayContainsAny': spicyTags,
        }
      });
    }

    // Add hashtag condition if any hashtags are specified
    if (hashtags.isNotEmpty) {
      final hashtagTags = hashtags.map((tag) => 'tag_$tag').toList();
      conditions.add({
        'tags': {
          'arrayContainsAny': hashtagTags,
        }
      });
    }

    // If we have conditions, add them to the query
    if (conditions.isNotEmpty) {
      query['where'] = conditions;
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

    // Add budget tags only if range is not default
    if (budgetRange != defaultBudgetRange) {
      print(
          'VideoFilter: Processing budget range: ${budgetRange.start} - ${budgetRange.end}');
      final budgetTags = _getBudgetBuckets(budgetRange);
      print('VideoFilter: Generated budget tags: $budgetTags');
      tags.addAll(budgetTags.map((bucket) => 'budget_$bucket'));
    }

    // Add calories tags only if range is not default
    if (caloriesRange != defaultCaloriesRange) {
      print(
          'VideoFilter: Processing calories range: ${caloriesRange.start} - ${caloriesRange.end}');
      final calorieTags = _getCaloriesBuckets(caloriesRange);
      print('VideoFilter: Generated calorie tags: $calorieTags');
      tags.addAll(calorieTags.map((bucket) => 'calories_$bucket'));
    }

    // Add prep time tags only if range is not default
    if (prepTimeRange != defaultPrepTimeRange) {
      print(
          'VideoFilter: Processing prep time range: ${prepTimeRange.start} - ${prepTimeRange.end}');
      final prepTimeTags = _getPrepTimeBuckets(prepTimeRange);
      print('VideoFilter: Generated prep time tags: $prepTimeTags');
      tags.addAll(prepTimeTags.map((bucket) => 'prep_$bucket'));
    }

    // Add spiciness tags only if range is not default
    if (minSpiciness != 0 || maxSpiciness != 5) {
      print(
          'VideoFilter: Processing spiciness range: $minSpiciness - $maxSpiciness');
      for (var i = minSpiciness; i <= maxSpiciness; i++) {
        tags.add('spicy_$i');
      }
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
        if (bucket.endsWith('+')) {
          // Handle infinity bucket (e.g., '100+')
          final start = double.parse(bucket.substring(0, bucket.length - 1));
          if (range.end >= start) {
            buckets.add(bucket);
          }
          continue;
        }

        final parts = bucket.split('-');
        if (parts.length != 2) {
          print('VideoFilter: Invalid bucket format: $bucket');
          continue;
        }

        final start = double.parse(parts[0]);
        final end = double.parse(parts[1]);

        if (range.end >= start && range.start <= end) {
          buckets.add(bucket);
        }
      } catch (e) {
        print('VideoFilter: Error processing budget bucket $bucket: $e');
        continue; // Skip this bucket instead of throwing
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
        if (bucket.endsWith('+')) {
          // Handle infinity bucket (e.g., '1500+')
          final start = double.parse(bucket.substring(0, bucket.length - 1));
          if (range.end >= start) {
            buckets.add(bucket);
          }
          continue;
        }

        final parts = bucket.split('-');
        if (parts.length != 2) {
          print('VideoFilter: Invalid bucket format: $bucket');
          continue;
        }

        final start = double.parse(parts[0]);
        final end = double.parse(parts[1]);

        if (range.end >= start && range.start <= end) {
          buckets.add(bucket);
        }
      } catch (e) {
        print('VideoFilter: Error processing calories bucket $bucket: $e');
        continue; // Skip this bucket instead of throwing
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
        if (bucket.endsWith('+')) {
          // Handle infinity bucket (e.g., '120+')
          final start = double.parse(bucket.substring(0, bucket.length - 1));
          if (range.end >= start) {
            buckets.add(bucket);
          }
          continue;
        }

        final parts = bucket.split('-');
        if (parts.length != 2) {
          print('VideoFilter: Invalid bucket format: $bucket');
          continue;
        }

        final start = double.parse(parts[0]);
        final end = double.parse(parts[1]);

        if (range.end >= start && range.start <= end) {
          buckets.add(bucket);
        }
      } catch (e) {
        print('VideoFilter: Error processing prep time bucket $bucket: $e');
        continue; // Skip this bucket instead of throwing
      }
    }

    print('VideoFilter: Returning prep time buckets: $buckets');
    return buckets;
  }
}
