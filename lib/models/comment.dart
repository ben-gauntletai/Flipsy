import 'package:cloud_firestore/cloud_firestore.dart';

class Comment {
  final String id;
  final String userId;
  final String videoId;
  final String text;
  final DateTime createdAt;
  final int likesCount;
  final String? replyToId;
  final int depth;
  final int replyCount;

  Comment({
    required this.id,
    required this.userId,
    required this.videoId,
    required this.text,
    required this.createdAt,
    required this.likesCount,
    this.replyToId,
    this.depth = 0,
    this.replyCount = 0,
  });

  factory Comment.fromMap(String id, Map<String, dynamic> data) {
    return Comment(
      id: id,
      userId: data['userId'] as String,
      videoId: data['videoId'] as String,
      text: data['text'] as String,
      createdAt: (data['createdAt'] as Timestamp).toDate(),
      likesCount: data['likesCount'] as int? ?? 0,
      replyToId: data['replyToId'] as String?,
      depth: data['depth'] as int? ?? 0,
      replyCount: data['replyCount'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'userId': userId,
      'videoId': videoId,
      'text': text,
      'createdAt': Timestamp.fromDate(createdAt),
      'likesCount': likesCount,
      'replyToId': replyToId,
      'depth': depth,
      'replyCount': replyCount,
    };
  }

  Comment copyWith({
    String? id,
    String? userId,
    String? videoId,
    String? text,
    DateTime? createdAt,
    int? likesCount,
    String? replyToId,
    int? depth,
    int? replyCount,
  }) {
    return Comment(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      videoId: videoId ?? this.videoId,
      text: text ?? this.text,
      createdAt: createdAt ?? this.createdAt,
      likesCount: likesCount ?? this.likesCount,
      replyToId: replyToId ?? this.replyToId,
      depth: depth ?? this.depth,
      replyCount: replyCount ?? this.replyCount,
    );
  }
}
