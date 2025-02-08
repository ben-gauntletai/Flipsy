# Flipsy Database Schema

## Collections

### videos
Main collection for storing video metadata.

**Path:** `videos/{videoId}`
```typescript
{
  userId: string;         // Reference to users/{userId}
  videoURL: string;      // URL to video file in Storage
  thumbnailURL: string;  // URL to thumbnail image in Storage
  description: string;   // Optional video description
  hashtags: string[];    // Array of hashtags extracted from description (stored in lowercase)
  tags: string[];        // Array of searchable tags (e.g., 'budget_0-10', 'calories_300-600', 'prep_15-30', 'spicy_3', 'tag_pasta')
  createdAt: timestamp;  // When the video was uploaded
  updatedAt: timestamp;  // When the video was last updated
  likesCount: number;    // Number of likes
  commentsCount: number; // Number of comments
  shareCount: number;    // Number of shares
  bookmarkCount: number; // Number of bookmarks
  duration: number;      // Video duration in seconds
  width: number;         // Video width in pixels
  height: number;        // Video height in pixels
  status: string;        // 'active' | 'deleted' | 'processing'
  allowComments: boolean; // Whether comments are enabled
  privacy: string;       // 'everyone' | 'followers' | 'private'
  spiciness: number;     // Rating from 0-5 indicating content spiciness (0 = not spicy)
  budget: number;        // Cost of the meal in local currency
  calories: number;      // Calorie count of the meal
  prepTimeMinutes: number; // Time taken to prepare the meal in minutes
  vectorEmbedding: {     // Vector embedding information for semantic search
    status: string;      // 'pending' | 'completed' | 'failed'
    updatedAt: timestamp; // When the embedding was last updated
    pineconeId: string;  // ID of the vector in Pinecone
    aiDescriptionIncluded: boolean; // Whether AI description is included in the vector
  };
  aiEnhancements: {
    description: string;  // AI-generated description of the video content
    generatedAt: timestamp; // When the AI description was generated
  };
}
```

### users
Collection of all users in the application.

- **id**: string (auth uid)
- **email**: string
- **displayName**: string
- **avatarURL**: string
- **bio**: string
- **instagramLink**: string (optional)
- **youtubeLink**: string (optional)
- **createdAt**: timestamp
- **updatedAt**: timestamp
- **totalVideos**: number
- **totalLikes**: number
- **followersCount**: number
- **followingCount**: number
- **bookmarkedCount**: number

#### Sub-collections

##### likedVideos
Collection of videos liked by the user.

- **videoId**: string (reference to videos collection)
- **likedAt**: timestamp

##### bookmarkedVideos
Collection of videos bookmarked by the user.

**Path:** `users/{userId}/bookmarkedVideos/{videoId}`
```typescript
{
  videoId: string;         // Reference to videos collection
  bookmarkedAt: timestamp; // When the video was bookmarked
}
```

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

### collections
Collection of user-created video collections.

**Path:** `collections/{collectionId}`
```typescript
{
  userId: string;         // Reference to users/{userId}
  name: string;          // Collection name
  description: string;   // Optional collection description
  thumbnailURL: string;  // URL to collection thumbnail (usually first video's thumbnail)
  createdAt: timestamp;  // When the collection was created
  updatedAt: timestamp;  // When the collection was last updated
  videoCount: number;    // Number of videos in the collection
  isPrivate: boolean;    // Whether the collection is private
}
```

#### Sub-collections

##### videos
Collection of videos in this collection.

**Path:** `collections/{collectionId}/videos/{videoId}`
```typescript
{
  // Same as video document in videos collection
  // This is a copy of the video data for quick access
}
```

## Firebase Storage Configuration

The application uses Firebase Storage for storing video and image content. The storage bucket configuration is managed through environment variables:

- **Storage Bucket:** `flipsy-gauntlet.firebasestorage.app`
- **Environment Variable:** `STORAGE_BUCKET`

### Storage Structure

```
/
├── videos/                 # Video content
│   ├── {videoId}/         # Individual video folders
│   │   ├── original.mp4   # Original uploaded video
│   │   └── thumbnail.jpg  # Video thumbnail
├── avatars/               # User avatar images
│   └── {userId}.jpg      # User avatar image
└── collections/           # Collection thumbnails
    └── {collectionId}.jpg # Collection thumbnail
```

All file paths in the database (videoURL, thumbnailURL, avatarURL) are stored as complete URLs to the storage bucket.