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
  final double duration;
  final int width;
  final int height;
  final String status;
  final Map<String, dynamic>? aiEnhancements;
  final bool allowComments;
  final String privacy; // 'everyone', 'followers', 'private'

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
    required this.duration,
    required this.width,
    required this.height,
    required this.status,
    this.aiEnhancements,
    this.allowComments = true,
    this.privacy = 'everyone',
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
      duration: (data['duration'] as num?)?.toDouble() ?? 0.0,
      width: (data['width'] as num?)?.toInt() ?? 0,
      height: (data['height'] as num?)?.toInt() ?? 0,
      status: data['status'] as String? ?? 'active',
      aiEnhancements: data['aiEnhancements'] as Map<String, dynamic>?,
      allowComments: data['allowComments'] as bool? ?? true,
      privacy: data['privacy'] as String? ?? 'everyone',
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
      'duration': duration,
      'width': width,
      'height': height,
      'status': status,
      'aiEnhancements': aiEnhancements,
      'allowComments': allowComments,
      'privacy': privacy,
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
    double? duration,
    int? width,
    int? height,
    String? status,
    Map<String, dynamic>? aiEnhancements,
    bool? allowComments,
    String? privacy,
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
      duration: duration ?? this.duration,
      width: width ?? this.width,
      height: height ?? this.height,
      status: status ?? this.status,
      aiEnhancements: aiEnhancements ?? this.aiEnhancements,
      allowComments: allowComments ?? this.allowComments,
      privacy: privacy ?? this.privacy,
    );
  }
}
