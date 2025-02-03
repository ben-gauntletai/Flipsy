import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:equatable/equatable.dart';

class UserModel extends Equatable {
  final String id;
  final String email;
  final String displayName;
  final String? avatarURL;
  final String? bio;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int followersCount;
  final int followingCount;
  final int totalLikes;
  final int totalVideos;

  const UserModel({
    required this.id,
    required this.email,
    required this.displayName,
    this.avatarURL,
    this.bio,
    required this.createdAt,
    required this.updatedAt,
    this.followersCount = 0,
    this.followingCount = 0,
    this.totalLikes = 0,
    this.totalVideos = 0,
  });

  factory UserModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return UserModel(
      id: doc.id,
      email: data['email'] as String,
      displayName: data['displayName'] as String,
      avatarURL: data['avatarURL'] as String?,
      bio: data['bio'] as String?,
      createdAt: (data['createdAt'] as Timestamp).toDate(),
      updatedAt: (data['updatedAt'] as Timestamp).toDate(),
      followersCount: data['followersCount'] as int? ?? 0,
      followingCount: data['followingCount'] as int? ?? 0,
      totalLikes: data['totalLikes'] as int? ?? 0,
      totalVideos: data['totalVideos'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'email': email,
      'displayName': displayName,
      'avatarURL': avatarURL,
      'bio': bio,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
      'followersCount': followersCount,
      'followingCount': followingCount,
      'totalLikes': totalLikes,
      'totalVideos': totalVideos,
    };
  }

  UserModel copyWith({
    String? id,
    String? email,
    String? displayName,
    String? avatarURL,
    String? bio,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? followersCount,
    int? followingCount,
    int? totalLikes,
    int? totalVideos,
  }) {
    return UserModel(
      id: id ?? this.id,
      email: email ?? this.email,
      displayName: displayName ?? this.displayName,
      avatarURL: avatarURL ?? this.avatarURL,
      bio: bio ?? this.bio,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      followersCount: followersCount ?? this.followersCount,
      followingCount: followingCount ?? this.followingCount,
      totalLikes: totalLikes ?? this.totalLikes,
      totalVideos: totalVideos ?? this.totalVideos,
    );
  }

  @override
  List<Object?> get props => [
        id,
        email,
        displayName,
        avatarURL,
        bio,
        createdAt,
        updatedAt,
        followersCount,
        followingCount,
        totalLikes,
        totalVideos,
      ];
} 