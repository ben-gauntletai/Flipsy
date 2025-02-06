import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart' show RangeValues;
import '../../../models/video.dart';

class VideoFilter extends Equatable {
  final RangeValues budgetRange;
  final RangeValues caloriesRange;
  final RangeValues prepTimeRange;
  final int minSpiciness;
  final int maxSpiciness;
  final Set<String> hashtags;

  const VideoFilter({
    RangeValues? budgetRange,
    RangeValues? caloriesRange,
    RangeValues? prepTimeRange,
    int? minSpiciness,
    int? maxSpiciness,
    this.hashtags = const {},
  })  : budgetRange = budgetRange ?? defaultBudgetRange,
        caloriesRange = caloriesRange ?? defaultCaloriesRange,
        prepTimeRange = prepTimeRange ?? defaultPrepTimeRange,
        minSpiciness = minSpiciness ?? 0,
        maxSpiciness = maxSpiciness ?? 5;

  // Default ranges for the filters
  static const defaultBudgetRange = RangeValues(0, 100); // $0 - $100
  static const defaultCaloriesRange = RangeValues(0, 2000); // 0 - 2000 calories
  static const defaultPrepTimeRange = RangeValues(0, 180); // 0 - 180 minutes
  static const defaultSpicinessRange = RangeValues(0, 5); // 0 - 5 peppers

  bool get hasFilters {
    // Check if any filter differs from its default value
    final hasBudgetFilter = budgetRange.start != defaultBudgetRange.start ||
        budgetRange.end != defaultBudgetRange.end;

    final hasCaloriesFilter =
        caloriesRange.start != defaultCaloriesRange.start ||
            caloriesRange.end != defaultCaloriesRange.end;

    final hasPrepTimeFilter =
        prepTimeRange.start != defaultPrepTimeRange.start ||
            prepTimeRange.end != defaultPrepTimeRange.end;

    final hasSpicinessFilter = minSpiciness != 0 || maxSpiciness != 5;

    return hasBudgetFilter ||
        hasCaloriesFilter ||
        hasPrepTimeFilter ||
        hasSpicinessFilter ||
        hashtags.isNotEmpty;
  }

  VideoFilter copyWith({
    RangeValues? budgetRange,
    RangeValues? caloriesRange,
    RangeValues? prepTimeRange,
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

  Map<String, dynamic> toFirestoreQuery() {
    final conditions = <String, dynamic>{};

    // Only add non-default filters
    if (budgetRange != defaultBudgetRange) {
      conditions['budget'] = {
        'start': budgetRange.start,
        'end': budgetRange.end,
      };
    }

    if (caloriesRange != defaultCaloriesRange) {
      conditions['calories'] = {
        'start': caloriesRange.start.toInt(),
        'end': caloriesRange.end.toInt(),
      };
    }

    if (prepTimeRange != defaultPrepTimeRange) {
      conditions['prepTimeMinutes'] = {
        'start': prepTimeRange.start.toInt(),
        'end': prepTimeRange.end.toInt(),
      };
    }

    if (minSpiciness != 0 || maxSpiciness != 5) {
      conditions['spiciness'] = {
        'min': minSpiciness,
        'max': maxSpiciness,
      };
    }

    if (hashtags.isNotEmpty) {
      print('VideoFilter: Adding hashtags to query: $hashtags');
      conditions['hashtags'] = hashtags.toList();
    }

    return conditions;
  }

  bool matchesVideo(Video video) {
    // Only apply non-default filters
    if (budgetRange != defaultBudgetRange) {
      final videoBudget = video.budget;
      if (videoBudget < budgetRange.start || videoBudget > budgetRange.end) {
        return false;
      }
    }

    if (caloriesRange != defaultCaloriesRange) {
      final videoCalories = video.calories;
      if (videoCalories < caloriesRange.start ||
          videoCalories > caloriesRange.end) {
        return false;
      }
    }

    if (prepTimeRange != defaultPrepTimeRange) {
      final videoPrepTime = video.prepTimeMinutes;
      if (videoPrepTime < prepTimeRange.start ||
          videoPrepTime > prepTimeRange.end) {
        return false;
      }
    }

    if (minSpiciness != 0 || maxSpiciness != 5) {
      final videoSpiciness = video.spiciness;
      if (videoSpiciness < minSpiciness || videoSpiciness > maxSpiciness) {
        return false;
      }
    }

    if (hashtags.isNotEmpty) {
      final description = video.description?.toLowerCase() ?? '';
      final RegExp hashtagRegex = RegExp(r'#(\w+)');
      final Set<String> videoHashtags = {};

      for (final match in hashtagRegex.allMatches(description)) {
        if (match.groupCount >= 1) {
          final tag = match.group(1)!.toLowerCase();
          videoHashtags.add(tag);
        }
      }

      bool hasMatchingHashtag = false;
      for (final tag in hashtags) {
        if (videoHashtags.contains(_normalizeHashtag(tag))) {
          hasMatchingHashtag = true;
          break;
        }
      }

      if (!hasMatchingHashtag) {
        return false;
      }
    }

    return true;
  }

  String _normalizeHashtag(String tag) {
    // Remove leading # if present, trim whitespace, and convert to lowercase
    final normalized = tag.replaceAll(RegExp(r'^#'), '').trim().toLowerCase();
    print('VideoFilter: Normalizing hashtag: $tag -> $normalized');
    return normalized;
  }

  VideoFilter addHashtag(String tag) {
    final normalizedTag = _normalizeHashtag(tag);
    if (normalizedTag.isEmpty) {
      print('VideoFilter: Skipping empty hashtag');
      return this;
    }

    print('VideoFilter: Adding hashtag: $tag (normalized: $normalizedTag)');
    final newHashtags = Set<String>.from(hashtags)..add(normalizedTag);
    print('VideoFilter: Updated hashtags: $newHashtags');
    return copyWith(hashtags: newHashtags);
  }

  VideoFilter removeHashtag(String tag) {
    final normalizedTag = _normalizeHashtag(tag);
    print('VideoFilter: Removing hashtag: $tag (normalized: $normalizedTag)');
    final newHashtags = Set<String>.from(hashtags)..remove(normalizedTag);
    print('VideoFilter: Updated hashtags: $newHashtags');
    return copyWith(hashtags: newHashtags);
  }

  @override
  List<Object?> get props => [
        budgetRange,
        caloriesRange,
        prepTimeRange,
        minSpiciness,
        maxSpiciness,
        hashtags,
      ];
}
