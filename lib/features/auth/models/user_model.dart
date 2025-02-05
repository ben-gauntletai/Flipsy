import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:equatable/equatable.dart';

class UserModel extends Equatable {
  final String id;
  final String email;
  final String displayName; // User's chosen display name
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
    print('UserModel: Converting Firestore document to UserModel');
    final data = doc.data() as Map<String, dynamic>;
    print('UserModel: Raw data from Firestore: $data');

    // Handle timestamps
    final createdAtTimestamp = data['createdAt'];
    final updatedAtTimestamp = data['updatedAt'];

    final DateTime createdAt;
    final DateTime updatedAt;

    if (createdAtTimestamp is Timestamp) {
      createdAt = createdAtTimestamp.toDate();
    } else {
      createdAt = DateTime.now();
      print(
          'UserModel: Using current time for createdAt as timestamp was not found');
    }

    if (updatedAtTimestamp is Timestamp) {
      updatedAt = updatedAtTimestamp.toDate();
    } else {
      updatedAt = DateTime.now();
      print(
          'UserModel: Using current time for updatedAt as timestamp was not found');
    }

    try {
      final userModel = UserModel(
        id: doc.id,
        email: data['email'] as String,
        displayName: data['displayName'] as String,
        avatarURL: data['avatarURL'] as String?,
        bio: data['bio'] as String?,
        createdAt: createdAt,
        updatedAt: updatedAt,
        followersCount: (data['followersCount'] as num?)?.toInt() ?? 0,
        followingCount: (data['followingCount'] as num?)?.toInt() ?? 0,
        totalLikes: (data['totalLikes'] as num?)?.toInt() ?? 0,
        totalVideos: (data['totalVideos'] as num?)?.toInt() ?? 0,
      );

      print(
          'UserModel: Created UserModel with displayName: ${userModel.displayName}');
      return userModel;
    } catch (e) {
      print('UserModel: Error creating UserModel: $e');
      print('UserModel: Raw data that caused error: $data');
      rethrow;
    }
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
