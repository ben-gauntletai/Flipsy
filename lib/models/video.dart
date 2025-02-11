import 'package:cloud_firestore/cloud_firestore.dart';

class Video {
  final String id;
  final String userId;
  final String videoURL;
  final String thumbnailURL;
  final String? description;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int likesCount;
  final int commentsCount;
  final int shareCount;
  final int bookmarkCount;
  final double duration;
  final int width;
  final int height;
  final String status;
  final Map<String, dynamic>? aiEnhancements;
  final bool allowComments;
  final String privacy; // 'everyone', 'followers', 'private'
  final int spiciness; // 0-5 rating for spiciness (0 = not spicy)
  final double budget; // Cost of the meal in local currency
  final int calories; // Calorie count of the meal
  final int prepTimeMinutes; // Preparation time in minutes
  final List<String> hashtags; // Added field for hashtags
  final List<String> tags; // Added field for combined tags
  final String processingStatus;
  final VideoAnalysis? analysis;

  // Static methods for bucket calculation
  static String calculateBudgetBucket(double budget) {
    if (budget <= 10) return '0-10';
    if (budget <= 25) return '10-25';
    if (budget <= 50) return '25-50';
    if (budget <= 100) return '50-100';
    return '100+';
  }

  static String calculateCaloriesBucket(int calories) {
    if (calories <= 300) return '0-300';
    if (calories <= 600) return '300-600';
    if (calories <= 1000) return '600-1000';
    if (calories <= 1500) return '1000-1500';
    return '1500+';
  }

  static String calculatePrepTimeBucket(int prepTimeMinutes) {
    if (prepTimeMinutes <= 15) return '0-15';
    if (prepTimeMinutes <= 30) return '15-30';
    if (prepTimeMinutes <= 60) return '30-60';
    if (prepTimeMinutes <= 120) return '60-120';
    return '120+';
  }

  // Helper method to generate tags
  static List<String> generateTags({
    required double budget,
    required int calories,
    required int prepTimeMinutes,
    required int spiciness,
    required List<String> hashtags,
  }) {
    final tags = <String>[];

    // Add bucket tags
    tags.add('budget_${calculateBudgetBucket(budget)}');
    tags.add('calories_${calculateCaloriesBucket(calories)}');
    tags.add('prep_${calculatePrepTimeBucket(prepTimeMinutes)}');

    // Add spiciness tag
    if (spiciness > 0) {
      tags.add('spicy_$spiciness');
    }

    // Add hashtags
    tags.addAll(hashtags.map((tag) => 'tag_$tag'));

    return tags;
  }

  Video({
    required this.id,
    required this.userId,
    required this.videoURL,
    required this.thumbnailURL,
    this.description,
    required this.createdAt,
    required this.updatedAt,
    required this.likesCount,
    required this.commentsCount,
    required this.shareCount,
    required this.bookmarkCount,
    required this.duration,
    required this.width,
    required this.height,
    required this.status,
    this.aiEnhancements,
    required this.allowComments,
    required this.privacy,
    required this.spiciness,
    required this.budget,
    required this.calories,
    required this.prepTimeMinutes,
    required this.hashtags,
    required this.tags,
    this.processingStatus = 'pending',
    this.analysis,
  });

  factory Video.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    print('Video.fromFirestore: Converting doc ${doc.id}');
    print('Video.fromFirestore: Raw createdAt: ${data['createdAt']}');
    print('Video.fromFirestore: Raw updatedAt: ${data['updatedAt']}');

    final createdAtTimestamp = data['createdAt'];
    final updatedAtTimestamp = data['updatedAt'];

    final DateTime createdAt;
    final DateTime updatedAt;

    if (createdAtTimestamp is Timestamp) {
      createdAt = createdAtTimestamp.toDate();
    } else {
      createdAt = DateTime.now();
      print('Video.fromFirestore: Using current time for createdAt');
    }

    if (updatedAtTimestamp is Timestamp) {
      updatedAt = updatedAtTimestamp.toDate();
    } else {
      updatedAt = DateTime.now();
      print('Video.fromFirestore: Using current time for updatedAt');
    }

    // Convert hashtags from dynamic to List<String>
    final List<String> hashtags = (data['hashtags'] as List<dynamic>?)
            ?.map((tag) => tag.toString())
            .toList() ??
        [];

    // Convert tags from dynamic to List<String>
    final List<String> tags = (data['tags'] as List<dynamic>?)
            ?.map((tag) => tag.toString())
            .toList() ??
        [];

    final double budget = (data['budget'] as num?)?.toDouble() ?? 0.0;
    final int calories = (data['calories'] as num?)?.toInt() ?? 0;
    final int prepTimeMinutes = (data['prepTimeMinutes'] as num?)?.toInt() ?? 0;

    return Video(
      id: doc.id,
      userId: data['userId'] as String? ?? '',
      videoURL: data['videoURL'] as String? ?? '',
      thumbnailURL: data['thumbnailURL'] as String? ?? '',
      description: data['description'] as String?,
      createdAt: createdAt,
      updatedAt: updatedAt,
      likesCount: (data['likesCount'] as num?)?.toInt() ?? 0,
      commentsCount: (data['commentsCount'] as num?)?.toInt() ?? 0,
      shareCount: (data['shareCount'] as num?)?.toInt() ?? 0,
      bookmarkCount: (data['bookmarkCount'] as num?)?.toInt() ?? 0,
      duration: (data['duration'] as num?)?.toDouble() ?? 0.0,
      width: (data['width'] as num?)?.toInt() ?? 0,
      height: (data['height'] as num?)?.toInt() ?? 0,
      status: data['status'] as String? ?? 'active',
      aiEnhancements: data['aiEnhancements'] as Map<String, dynamic>?,
      allowComments: data['allowComments'] as bool? ?? true,
      privacy: data['privacy'] as String? ?? 'everyone',
      spiciness: (data['spiciness'] as num?)?.toInt() ?? 0,
      budget: budget,
      calories: calories,
      prepTimeMinutes: prepTimeMinutes,
      hashtags: hashtags,
      tags: tags,
      processingStatus: data['processingStatus'] as String? ?? 'pending',
      analysis: data['analysis'] != null
          ? VideoAnalysis.fromMap(data['analysis'])
          : null,
    );
  }

  Map<String, dynamic> toFirestore() {
    print('Video.toFirestore: Converting video $id');
    print('Video.toFirestore: createdAt: $createdAt');
    print('Video.toFirestore: updatedAt: $updatedAt');

    return {
      'userId': userId,
      'videoURL': videoURL,
      'thumbnailURL': thumbnailURL,
      'description': description,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
      'likesCount': likesCount,
      'commentsCount': commentsCount,
      'shareCount': shareCount,
      'bookmarkCount': bookmarkCount,
      'duration': duration,
      'width': width,
      'height': height,
      'status': status,
      'aiEnhancements': aiEnhancements,
      'allowComments': allowComments,
      'privacy': privacy,
      'spiciness': spiciness,
      'budget': budget,
      'calories': calories,
      'prepTimeMinutes': prepTimeMinutes,
      'hashtags': hashtags,
      'tags': tags,
      'processingStatus': processingStatus,
      'analysis': analysis?.toMap(),
    };
  }

  // Helper method to extract hashtags from description
  static List<String> extractHashtags(String? description) {
    if (description == null || description.isEmpty) {
      return [];
    }

    final RegExp hashtagRegex = RegExp(r'#(\w+)');
    return hashtagRegex
        .allMatches(description.toLowerCase())
        .map((match) => match.group(1)!)
        .toSet()
        .toList();
  }

  Video copyWith({
    String? id,
    String? userId,
    String? videoURL,
    String? thumbnailURL,
    String? description,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? likesCount,
    int? commentsCount,
    int? shareCount,
    int? bookmarkCount,
    double? duration,
    int? width,
    int? height,
    String? status,
    Map<String, dynamic>? aiEnhancements,
    bool? allowComments,
    String? privacy,
    int? spiciness,
    double? budget,
    int? calories,
    int? prepTimeMinutes,
    List<String>? hashtags,
    List<String>? tags,
    String? processingStatus,
    VideoAnalysis? analysis,
  }) {
    return Video(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      videoURL: videoURL ?? this.videoURL,
      thumbnailURL: thumbnailURL ?? this.thumbnailURL,
      description: description ?? this.description,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      likesCount: likesCount ?? this.likesCount,
      commentsCount: commentsCount ?? this.commentsCount,
      shareCount: shareCount ?? this.shareCount,
      bookmarkCount: bookmarkCount ?? this.bookmarkCount,
      duration: duration ?? this.duration,
      width: width ?? this.width,
      height: height ?? this.height,
      status: status ?? this.status,
      aiEnhancements: aiEnhancements ?? this.aiEnhancements,
      allowComments: allowComments ?? this.allowComments,
      privacy: privacy ?? this.privacy,
      spiciness: spiciness ?? this.spiciness,
      budget: budget ?? this.budget,
      calories: calories ?? this.calories,
      prepTimeMinutes: prepTimeMinutes ?? this.prepTimeMinutes,
      hashtags: hashtags ?? this.hashtags,
      tags: tags ?? this.tags,
      processingStatus: processingStatus ?? this.processingStatus,
      analysis: analysis ?? this.analysis,
    );
  }

  factory Video.fromMap(Map<String, dynamic> map) {
    final List<String> hashtags = (map['hashtags'] as List<dynamic>?)
            ?.map((tag) => tag.toString())
            .toList() ??
        [];

    final List<String> tags = (map['tags'] as List<dynamic>?)
            ?.map((tag) => tag.toString())
            .toList() ??
        [];

    return Video(
      id: map['id'] as String,
      userId: map['userId'] as String,
      videoURL: map['videoURL'] as String,
      thumbnailURL: map['thumbnailURL'] as String,
      description: map['description'] as String?,
      budget: map['budget'] == null ? 0.0 : (map['budget'] as num).toDouble(),
      calories: (map['calories'] as num?)?.toInt() ?? 0,
      prepTimeMinutes: (map['prepTimeMinutes'] as num?)?.toInt() ?? 0,
      spiciness: (map['spiciness'] as num?)?.toInt() ?? 0,
      createdAt: (map['createdAt'] as Timestamp).toDate(),
      updatedAt: (map['updatedAt'] as Timestamp?)?.toDate() ??
          (map['createdAt'] as Timestamp).toDate(),
      status: map['status'] as String? ?? 'published',
      likesCount: (map['likesCount'] as num?)?.toInt() ?? 0,
      commentsCount: (map['commentsCount'] as num?)?.toInt() ?? 0,
      shareCount: (map['shareCount'] as num?)?.toInt() ?? 0,
      bookmarkCount: (map['bookmarkCount'] as num?)?.toInt() ?? 0,
      duration: (map['duration'] as num?)?.toDouble() ?? 0.0,
      width: (map['width'] as num?)?.toInt() ?? 0,
      height: (map['height'] as num?)?.toInt() ?? 0,
      hashtags: hashtags,
      tags: tags,
      processingStatus: map['processingStatus'] as String? ?? 'pending',
      analysis: map['analysis'] != null
          ? VideoAnalysis.fromMap(map['analysis'])
          : null,
      allowComments: map['allowComments'] as bool? ?? true,
      privacy: map['privacy'] as String? ?? 'everyone',
    );
  }
}

class VideoAnalysis {
  final String summary;
  final List<String> ingredients;
  final List<String> tools;
  final List<String> techniques;
  final List<String> steps;
  final DateTime processedAt;
  final List<TranscriptionSegment> transcriptionSegments;

  VideoAnalysis({
    required this.summary,
    required this.ingredients,
    required this.tools,
    required this.techniques,
    required this.steps,
    required this.processedAt,
    required this.transcriptionSegments,
  });

  factory VideoAnalysis.fromMap(Map<String, dynamic> map) {
    return VideoAnalysis(
      summary: map['summary'] ?? '',
      ingredients: List<String>.from(map['ingredients'] ?? []),
      tools: List<String>.from(map['tools'] ?? []),
      techniques: List<String>.from(map['techniques'] ?? []),
      steps: List<String>.from(map['steps'] ?? []),
      processedAt: (map['processedAt'] as Timestamp).toDate(),
      transcriptionSegments: (map['transcriptionSegments'] as List<dynamic>?)
              ?.map((segment) => TranscriptionSegment.fromMap(segment))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'summary': summary,
      'ingredients': ingredients,
      'tools': tools,
      'techniques': techniques,
      'steps': steps,
      'processedAt': processedAt,
      'transcriptionSegments':
          transcriptionSegments.map((s) => s.toMap()).toList(),
    };
  }
}

class TranscriptionSegment {
  final double start;
  final double end;
  final String text;

  TranscriptionSegment({
    required this.start,
    required this.end,
    required this.text,
  });

  factory TranscriptionSegment.fromMap(Map<String, dynamic> map) {
    return TranscriptionSegment(
      start: (map['start'] as num).toDouble(),
      end: (map['end'] as num).toDouble(),
      text: map['text'] as String,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'start': start,
      'end': end,
      'text': text,
    };
  }
}
