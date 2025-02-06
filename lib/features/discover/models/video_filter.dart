import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart' show RangeValues;

class VideoFilter extends Equatable {
  final RangeValues? budgetRange;
  final RangeValues? caloriesRange;
  final RangeValues? prepTimeRange;
  final int? minSpiciness;
  final int? maxSpiciness;
  final Set<String> hashtags;

  const VideoFilter({
    this.budgetRange,
    this.caloriesRange,
    this.prepTimeRange,
    this.minSpiciness,
    this.maxSpiciness,
    this.hashtags = const {},
  });

  // Default ranges for the filters
  static const defaultBudgetRange = RangeValues(0, 100); // $0 - $100
  static const defaultCaloriesRange = RangeValues(0, 2000); // 0 - 2000 calories
  static const defaultPrepTimeRange = RangeValues(0, 180); // 0 - 180 minutes
  static const defaultSpicinessRange = RangeValues(0, 5); // 0 - 5 peppers

  bool get hasFilters =>
      budgetRange != null ||
      caloriesRange != null ||
      prepTimeRange != null ||
      minSpiciness != null ||
      maxSpiciness != null ||
      hashtags.isNotEmpty;

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

    if (budgetRange != null) {
      conditions['budget_range'] = {
        'min': budgetRange!.start,
        'max': budgetRange!.end,
      };
    }

    if (caloriesRange != null) {
      conditions['calories_range'] = {
        'min': caloriesRange!.start.toInt(),
        'max': caloriesRange!.end.toInt(),
      };
    }

    if (prepTimeRange != null) {
      conditions['prep_time_range'] = {
        'min': prepTimeRange!.start.toInt(),
        'max': prepTimeRange!.end.toInt(),
      };
    }

    if (minSpiciness != null) {
      conditions['min_spiciness'] = minSpiciness;
    }

    if (maxSpiciness != null) {
      conditions['max_spiciness'] = maxSpiciness;
    }

    if (hashtags.isNotEmpty) {
      conditions['hashtags'] = hashtags.toList();
    }

    return conditions;
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
