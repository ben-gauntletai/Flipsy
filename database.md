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

## Indexes

### Required Indexes

1. videos collection:
   - status ASC, createdAt DESC
   - status ASC, tags ARRAY_CONTAINS, createdAt DESC

Note: We now use a tag-based filtering system where all filterable attributes are stored in a tags array. This approach allows for efficient querying using array-contains-any operations, which only requires a single index. The tags array includes bucket information (e.g., 'budget_0-10'), spiciness levels ('spicy_3'), and hashtags ('tag_pasta'). This significantly reduces the number of required indexes while still maintaining good query performance.

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

      // Bookmarked videos subcollection
      match /bookmarkedVideos/{videoId} {
        allow read: if true;
        allow write: if request.auth != null && request.auth.uid == userId;
      }
    }

    // Video document rules
    match /videos/{videoId} {
      allow read: if 
        // Public videos are readable by anyone
        resource.data.privacy == 'everyone' ||
        // Private videos are only readable by the owner
        (resource.data.privacy == 'private' && request.auth != null && request.auth.uid == resource.data.userId) ||
        // Followers-only videos are readable by followers and the owner
        (resource.data.privacy == 'followers' && (
          request.auth != null && (
            request.auth.uid == resource.data.userId ||
            exists(/databases/$(database)/documents/follows/$(request.auth.uid + '_' + resource.data.userId))
          )
        ));
      
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

# Database Schema

## Videos Collection
- Collection: `videos`
- Document ID: Auto-generated
- Fields:
  - `id`: String - Unique identifier for the video
  - `userId`: String - Reference to the user who created the video
  - `title`: String - Title of the video
  - `description`: String - Description of the video
  - `videoURL`: String - URL to the video file in storage
  - `thumbnailURL`: String - URL to the thumbnail image in storage
  - `createdAt`: Timestamp - When the video was created
  - `updatedAt`: Timestamp - When the video was last updated
  - `status`: String - Status of the video (active, deleted)
  - `privacy`: String - Privacy setting (everyone, followers, private)
  - `budget`: Number - Estimated cost of the recipe
  - `calories`: Number - Estimated calories per serving
  - `prepTimeMinutes`: Number - Estimated preparation time in minutes
  - `spiciness`: Number - Spiciness level (0-5)
  - `hashtags`: Array<String> - List of hashtags extracted from description
  - `tags`: Array<String> - List of searchable tags for filtering
    - Format: `[category]_[value]`
    - Categories:
      - `budget`: Budget range (e.g., 'budget_0-10', 'budget_10-20', etc.)
      - `calories`: Calorie range (e.g., 'calories_0-300', 'calories_300-600', etc.)
      - `preptime`: Prep time range (e.g., 'preptime_0-15', 'preptime_15-30', etc.)
      - `spiciness`: Spiciness level (e.g., 'spiciness_0', 'spiciness_1', etc.)
  - `likeCount`: Number - Number of likes
  - `commentCount`: Number - Number of comments
  - `bookmarkCount`: Number - Number of bookmarks
  - `viewCount`: Number - Number of views
  - `metadata`: Map
    - `duration`: Number - Duration in seconds
    - `width`: Number - Video width in pixels
    - `height`: Number - Video height in pixels
    - `size`: Number - File size in bytes

### Indexes
1. Compound index on `status` ASC, `createdAt` DESC
2. Compound index on `userId` ASC, `status` ASC, `createdAt` DESC
3. Compound index on `status` ASC, `tags` ARRAY, `createdAt` DESC
4. Compound index on `hashtags` ARRAY, `status` ASC, `createdAt` DESC

### Notes
- The `tags` field is used for efficient filtering of videos based on various criteria
- Each tag follows the format `category_value` where:
  - Budget ranges: 0-10, 10-20, 20-30, 30-40, 40-50, 50-75, 75-100, 100+
  - Calories ranges: 0-300, 300-600, 600-900, 900-1200, 1200-1500, 1500+
  - Prep time ranges: 0-15, 15-30, 30-45, 45-60, 60-90, 90-120, 120+
  - Spiciness levels: 0, 1, 2, 3, 4, 5
- Tags are generated automatically when a video is created or updated
- The `arrayContainsAny` query is used to filter videos based on tags
- Maximum of 10 tags per category to maintain query performance



