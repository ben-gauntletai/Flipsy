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
    this.bookmarkCount = 0,
    required this.duration,
    required this.width,
    required this.height,
    required this.status,
    this.aiEnhancements,
    this.allowComments = true,
    this.privacy = 'everyone',
    this.spiciness = 0,
    this.budget = 0.0,
    this.calories = 0,
    this.prepTimeMinutes = 0,
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
      budget: (data['budget'] as num?)?.toDouble() ?? 0.0,
      calories: (data['calories'] as num?)?.toInt() ?? 0,
      prepTimeMinutes: (data['prepTimeMinutes'] as num?)?.toInt() ?? 0,
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
    };
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
    );
  }
}
