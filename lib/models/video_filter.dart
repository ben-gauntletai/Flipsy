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
    // Remove leading #, trim whitespace, convert to lowercase
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

    if (budgetRange != defaultBudgetRange) {
      query['budget'] = {
        'start': budgetRange.start,
        'end': budgetRange.end,
      };
    }

    if (caloriesRange != defaultCaloriesRange) {
      query['calories'] = {
        'start': caloriesRange.start,
        'end': caloriesRange.end,
      };
    }

    if (prepTimeRange != defaultPrepTimeRange) {
      query['prepTimeMinutes'] = {
        'start': prepTimeRange.start,
        'end': prepTimeRange.end,
      };
    }

    if (minSpiciness != 0 || maxSpiciness != 5) {
      query['spiciness'] = {
        'min': minSpiciness,
        'max': maxSpiciness,
      };
    }

    if (hashtags.isNotEmpty) {
      if (hashtags.length > maxHashtags) {
        throw Exception('Maximum of $maxHashtags hashtags allowed');
      }
      query['hashtags'] = hashtags.toList();
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
}
