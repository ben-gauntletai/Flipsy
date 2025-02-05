# Flipsy Database Schema

## Collections

### videos
Collection of all videos in the application.

- **id**: string (auto-generated)
- **userId**: string (reference to users collection)
- **videoURL**: string
- **thumbnailURL**: string
- **description**: string
- **createdAt**: timestamp
- **updatedAt**: timestamp
- **status**: string (active, deleted, reported)
- **likesCount**: number
- **commentsCount**: number
- **shareCount**: number
- **views**: number
- **allowComments**: boolean (default: true)

### users
Collection of all users in the application.

- **id**: string (auth uid)
- **email**: string
- **displayName**: string
- **avatarURL**: string
- **bio**: string
- **createdAt**: timestamp
- **updatedAt**: timestamp
- **totalVideos**: number
- **totalLikes**: number
- **followersCount**: number
- **followingCount**: number

#### Sub-collections

##### likedVideos
Collection of videos liked by the user.

- **videoId**: string (reference to videos collection)
- **likedAt**: timestamp

### likes
Subcollection of videos to track user likes.

**Path:** `videos/{videoId}/likes/{userId}`
```typescript
{
  userId: string;         // Reference to users/{userId}
  createdAt: timestamp;
}
```

### comments
Subcollection of videos to store user comments.

**Path:** `videos/{videoId}/comments/{commentId}`
```typescript
{
  userId: string;         // Reference to users/{userId}
  text: string;          // Comment text content
  createdAt: timestamp;  // When the comment was created
  updatedAt: timestamp;  // When the comment was last updated
  likesCount: number;    // Number of likes on this comment
  replyToId: string;     // ID of parent comment if this is a reply (optional)
  replyCount: number;    // Number of replies to this comment
  mentions: string[];    // Array of mentioned user IDs
  depth: number;         // Nesting level (0 for top-level comments)
}
```

### commentLikes
Subcollection of comments to track user likes on comments.

**Path:** `videos/{videoId}/comments/{commentId}/likes/{userId}`
```typescript
{
  userId: string;         // Reference to users/{userId}
  createdAt: timestamp;  // When the like was created
}
```

### follows
Tracks user follow relationships.

**Document ID:** `{followerId}_{followingId}`
```typescript
{
  followerId: string;     // User who is following
  followingId: string;    // User being followed
  createdAt: timestamp;
}
```

### notifications
Stores user notifications.

**Document ID:** Auto-generated
```typescript
{
  userId: string;         // Recipient user
  type: 'like' | 'comment' | 'follow' | 'video_post' | 'comment_reply';  // Type of notification
  sourceUserId: string;   // User who triggered the notification
  videoId?: string;      // Referenced video if applicable
  commentId?: string;    // Referenced comment if applicable
  commentText?: string;  // Preview of the comment text (for comment notifications)
  createdAt: timestamp;
  read: boolean;
  videoThumbnailURL?: string;  // Thumbnail URL for video post notifications
  videoDescription?: string;   // Description for video post notifications
}
```

## Indexes

### Required Indexes

1. videos collection:
   - status, createdAt DESC
   - userId, createdAt DESC
   - status, likesCount DESC

2. users/likedVideos collection:
   - likedAt DESC

3. notifications collection:
   - userId, type, createdAt DESC

## Security Rules

```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    // User document rules
    match /users/{userId} {
      allow read: if true;
      allow write: if request.auth != null && request.auth.uid == userId;
      
      // Liked videos subcollection
      match /likedVideos/{videoId} {
        allow read: if true;
        allow write: if request.auth != null && request.auth.uid == userId;
      }
    }

    // Video document rules
    match /videos/{videoId} {
      allow read: if true;
      allow create: if request.auth != null;
      allow update: if request.auth != null && (
        resource.data.userId == request.auth.uid ||
        request.resource.data.diff(resource.data).affectedKeys()
          .hasOnly(['likesCount', 'commentsCount', 'shareCount', 'views'])
      );
      allow delete: if request.auth != null && resource.data.userId == request.auth.uid;
    }

    // Follow relationship rules
    match /follows/{followId} {
      allow read: if true;
      allow create: if request.auth != null && 
        followId == request.auth.uid + '_' + request.resource.data.followingId;
      allow delete: if request.auth != null && 
        followId == request.auth.uid + '_' + resource.data.followingId;
    }
  }
}
```

## Notes

- All timestamp fields use Firestore's native timestamp type
- Counters (likesCount, followersCount, etc.) use atomic operations
- Soft deletion is implemented using the status field where applicable
- AI enhancements are stored as nested objects for flexibility



