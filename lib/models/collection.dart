import 'package:cloud_firestore/cloud_firestore.dart';

class Collection {
  final String id;
  final String userId;
  final String name;
  final String? description;
  final String? thumbnailURL;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int videoCount;
  final bool isPrivate;

  Collection({
    required this.id,
    required this.userId,
    required this.name,
    this.description,
    this.thumbnailURL,
    required this.createdAt,
    required this.updatedAt,
    this.videoCount = 0,
    this.isPrivate = false,
  });

  factory Collection.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return Collection(
      id: doc.id,
      userId: data['userId'] as String,
      name: data['name'] as String,
      description: data['description'] as String?,
      thumbnailURL: data['thumbnailURL'] as String?,
      createdAt: (data['createdAt'] as Timestamp).toDate(),
      updatedAt: (data['updatedAt'] as Timestamp).toDate(),
      videoCount: (data['videoCount'] as num?)?.toInt() ?? 0,
      isPrivate: data['isPrivate'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'userId': userId,
      'name': name,
      'description': description,
      'thumbnailURL': thumbnailURL,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
      'videoCount': videoCount,
      'isPrivate': isPrivate,
    };
  }

  Collection copyWith({
    String? id,
    String? userId,
    String? name,
    String? description,
    String? thumbnailURL,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? videoCount,
    bool? isPrivate,
  }) {
    return Collection(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      name: name ?? this.name,
      description: description ?? this.description,
      thumbnailURL: thumbnailURL ?? this.thumbnailURL,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      videoCount: videoCount ?? this.videoCount,
      isPrivate: isPrivate ?? this.isPrivate,
    );
  }
}
