import 'package:cloud_firestore/cloud_firestore.dart';

class Collection {
  final String id;
  final String name;
  final String userId;
  final bool isPrivate;
  final int videoCount;
  final String? thumbnailUrl;
  final DateTime createdAt;
  final DateTime updatedAt;

  Collection({
    required this.id,
    required this.name,
    required this.userId,
    required this.isPrivate,
    required this.videoCount,
    this.thumbnailUrl,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Collection.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return Collection(
      id: doc.id,
      name: data['name'] as String,
      userId: data['userId'] as String,
      isPrivate: data['isPrivate'] as bool,
      videoCount: data['videoCount'] as int,
      thumbnailUrl: data['thumbnailUrl'] as String?,
      createdAt: (data['createdAt'] as Timestamp).toDate(),
      updatedAt: (data['updatedAt'] as Timestamp).toDate(),
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
    String? name,
    String? userId,
    bool? isPrivate,
    int? videoCount,
    String? thumbnailUrl,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Collection(
      id: id ?? this.id,
      name: name ?? this.name,
      userId: userId ?? this.userId,
      isPrivate: isPrivate ?? this.isPrivate,
      videoCount: videoCount ?? this.videoCount,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
