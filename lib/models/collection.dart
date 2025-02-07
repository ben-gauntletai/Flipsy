import 'package:cloud_firestore/cloud_firestore.dart';

class Collection {
  final String id;
  final String userId;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int videoCount;
  final bool isPrivate;
  final String? thumbnailUrl;

  Collection({
    required this.id,
    required this.userId,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    required this.videoCount,
    required this.isPrivate,
    this.thumbnailUrl,
  });

  factory Collection.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final createdAtTimestamp = data['createdAt'] as Timestamp?;
    final updatedAtTimestamp = data['updatedAt'] as Timestamp?;

    return Collection(
      id: doc.id,
      userId: data['userId'] as String,
      name: data['name'] as String,
      createdAt: createdAtTimestamp?.toDate() ?? DateTime.now(),
      updatedAt: updatedAtTimestamp?.toDate() ?? DateTime.now(),
      videoCount: data['videoCount'] as int? ?? 0,
      isPrivate: data['isPrivate'] as bool? ?? false,
      thumbnailUrl: data['thumbnailUrl'] as String?,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'name': name,
      'userId': userId,
      'isPrivate': isPrivate,
      'videoCount': videoCount,
      'thumbnailUrl': thumbnailUrl,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
    };
  }

  Collection copyWith({
    String? id,
    String? userId,
    String? name,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? videoCount,
    bool? isPrivate,
    String? thumbnailUrl,
  }) {
    return Collection(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      name: name ?? this.name,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      videoCount: videoCount ?? this.videoCount,
      isPrivate: isPrivate ?? this.isPrivate,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
    );
  }
}
