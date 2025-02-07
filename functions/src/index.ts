/**
 * Import function triggers from their respective submodules:
 *
 * import {onCall} from "firebase-functions/v2/https";
 * import {onDocumentWritten} from "firebase-functions/v2/firestore";
 *
 * See a full list of supported triggers at https://firebase.google.com/docs/functions
 */

import * as functions from "firebase-functions/v2";
import { CallableRequest, onCall } from "firebase-functions/v2/https";
import {
  onDocumentCreated,
  onDocumentDeleted,
  onDocumentUpdated,
  DocumentSnapshot,
} from "firebase-functions/v2/firestore";
import * as admin from "firebase-admin";
import OpenAI from "openai";
import type { ChatCompletionMessageParam } from "openai/resources/chat/completions";

// Custom type for vision messages
// type VisionContent = {
//   type: "image";
//   image_url: string;
// };

// Start writing functions
// https://firebase.google.com/docs/functions/typescript

// export const helloWorld = onRequest((request, response) => {
//   logger.info("Hello logs!", {structuredData: true});
//   response.send("Hello from Firebase!");
// });

admin.initializeApp();

interface SignUpData {
  email: string;
  password: string;
  displayName: string;
}

export const createUser = functions.https.onCall(async (request) => {
  try {
    const data = request.data as SignUpData;

    // Validate input data
    if (!data.email || !data.password || !data.displayName) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "Email, password, and display name are required.",
      );
    }

    // Check if display name is already taken
    const displayNameQuery = await admin
      .firestore()
      .collection("users")
      .where("displayName", "==", data.displayName)
      .get();

    if (!displayNameQuery.empty) {
      throw new functions.https.HttpsError(
        "already-exists",
        "This display name is already taken.",
      );
    }

    // Create user with Firebase Auth
    const userRecord = await admin.auth().createUser({
      email: data.email,
      password: data.password,
      displayName: data.displayName,
    });

    // Create user profile in Firestore
    await admin.firestore().collection("users").doc(userRecord.uid).set({
      email: data.email,
      displayName: data.displayName,
      avatarURL: null,
      bio: null,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      followersCount: 0,
      followingCount: 0,
      totalLikes: 0,
      totalVideos: 0,
    });

    // Return success response
    return {
      success: true,
      uid: userRecord.uid,
      message: "User created successfully",
    };
  } catch (error: unknown) {
    console.error("Error creating user:", error);

    if (error instanceof functions.https.HttpsError) {
      throw error;
    }

    const firebaseError = error as { code?: string };

    if (firebaseError.code === "auth/email-already-exists") {
      throw new functions.https.HttpsError(
        "already-exists",
        "The email address is already in use.",
      );
    }

    if (firebaseError.code === "auth/invalid-email") {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "The email address is not valid.",
      );
    }

    if (firebaseError.code === "auth/weak-password") {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "The password must be at least 6 characters long.",
      );
    }

    throw new functions.https.HttpsError(
      "internal",
      "An error occurred while creating the user.",
    );
  }
});

// Function to handle comment creation
export const onCommentCreated = onDocumentCreated(
  "videos/{videoId}/comments/{commentId}",
  async (event) => {
    const commentData = event.data?.data();
    const { videoId } = event.params;

    if (!commentData) {
      console.log("No comment data found for creation event");
      return;
    }

    try {
      const db = admin.firestore();
      const batch = db.batch();

      console.log(`Processing comment creation for video ${videoId}:`, {
        commentId: event.params.commentId,
        isReply: !!commentData.replyToId,
        depth: commentData.depth,
      });

      // Only increment the video's comment count for parent comments
      if (!commentData.replyToId && commentData.depth === 0) {
        console.log("Incrementing video comment count - parent comment detected");
        const videoRef = db.collection("videos").doc(videoId);
        batch.update(videoRef, {
          commentsCount: admin.firestore.FieldValue.increment(1),
        });
      } else {
        console.log("Skipping comment count increment - this is a reply");
      }

      // If this is a reply, increment the parent comment's reply count
      if (commentData.replyToId) {
        console.log(`Incrementing reply count for parent comment ${commentData.replyToId}`);
        const parentCommentRef = db
          .collection("videos")
          .doc(videoId)
          .collection("comments")
          .doc(commentData.replyToId);

        // Verify parent comment exists and is actually a parent
        const parentDoc = await parentCommentRef.get();
        if (!parentDoc.exists) {
          console.error("Parent comment not found");
          return;
        }

        const parentData = parentDoc.data();
        if (parentData?.depth !== 0) {
          console.error("Invalid reply - parent comment is not a top-level comment");
          return;
        }

        batch.update(parentCommentRef, {
          replyCount: admin.firestore.FieldValue.increment(1),
        });

        // Only notify the parent comment author if they made the original comment
        // and they're not replying to their own comment
        if (parentData.userId !== commentData.userId) {
          console.log("Creating notification for parent comment author");
          const notificationRef = db.collection("notifications").doc();
          batch.set(notificationRef, {
            userId: parentData.userId,
            type: "comment_reply",
            sourceUserId: commentData.userId,
            videoId,
            commentId: event.params.commentId,
            commentText: commentData.text.substring(0, 100), // Limit preview to 100 chars
            videoThumbnailURL: null, // Will be set later if video data exists
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
            read: false,
          });
        }
      }

      // Get video data to find the video owner
      const videoDoc = await db.collection("videos").doc(videoId).get();
      const videoData = videoDoc.data();

      if (!videoData) {
        console.error("Video data not found");
        return;
      }

      // Update video thumbnail URL for any notifications we're about to send
      const thumbnailURL = videoData.thumbnailURL;
      const notificationsToUpdate = await db
        .collection("notifications")
        .where("videoId", "==", videoId)
        .where("videoThumbnailURL", "==", null)
        .get();

      notificationsToUpdate.docs.forEach((doc) => {
        batch.update(doc.ref, { videoThumbnailURL: thumbnailURL });
      });

      // Only notify the video owner if:
      // 1. This is a new parent comment (not a reply)
      // 2. The commenter is not the video owner
      if (!commentData.replyToId && videoData.userId !== commentData.userId) {
        console.log("Creating notification for video owner");
        const notificationRef = db.collection("notifications").doc();
        batch.set(notificationRef, {
          userId: videoData.userId,
          type: "comment",
          sourceUserId: commentData.userId,
          videoId,
          commentId: event.params.commentId,
          commentText: commentData.text.substring(0, 100), // Limit preview to 100 chars
          videoThumbnailURL: videoData.thumbnailURL,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
          read: false,
        });
      }

      await batch.commit();
      console.log("Successfully processed comment creation");
    } catch (error) {
      console.error("Error in onCommentCreated:", error);
    }
  }
);

// Function to handle comment deletion
export const onCommentDeleted = onDocumentDeleted(
  "videos/{videoId}/comments/{commentId}",
  async (event) => {
    const commentData = event.data?.data();
    const { videoId } = event.params;

    if (!commentData) {
      console.log("No comment data found for deletion event");
      return;
    }

    try {
      console.log(`Processing comment deletion for video ${videoId}:`, {
        commentId: event.params.commentId,
        isReply: !!commentData.replyToId,
        depth: commentData.depth,
      });

      const db = admin.firestore();
      const batch = db.batch();

      // Only decrement the video's comment count for parent comments
      if (!commentData.replyToId && commentData.depth === 0) {
        console.log("Decrementing video comment count - parent comment detected");
        const videoRef = db.collection("videos").doc(videoId);
        batch.update(videoRef, {
          commentsCount: admin.firestore.FieldValue.increment(-1),
        });
      } else {
        console.log("Skipping comment count decrement - this is a reply");
      }

      // If this was a reply, decrement the parent comment's reply count
      if (commentData.replyToId) {
        console.log(`Decrementing reply count for parent comment ${commentData.replyToId}`);
        const parentCommentRef = db
          .collection("videos")
          .doc(videoId)
          .collection("comments")
          .doc(commentData.replyToId);

        // Check if parent comment exists before updating
        const parentCommentDoc = await parentCommentRef.get();
        if (parentCommentDoc.exists) {
          const parentData = parentCommentDoc.data();
          if (parentData?.depth === 0) {
            batch.update(parentCommentRef, {
              replyCount: admin.firestore.FieldValue.increment(-1),
            });
          } else {
            console.log("Parent comment is not a top-level comment, skipping reply count update");
          }
        } else {
          console.log(`Parent comment ${commentData.replyToId} not found`);
        }
      }

      // Delete all likes for this comment
      console.log("Deleting comment likes");
      const likesSnapshot = await db
        .collection("videos")
        .doc(videoId)
        .collection("comments")
        .doc(event.params.commentId)
        .collection("likes")
        .get();

      likesSnapshot.docs.forEach((doc) => {
        batch.delete(doc.ref);
      });

      // Delete all replies to this comment
      console.log("Deleting comment replies");
      const repliesSnapshot = await db
        .collection("videos")
        .doc(videoId)
        .collection("comments")
        .where("replyToId", "==", event.params.commentId)
        .get();

      repliesSnapshot.docs.forEach((doc) => {
        batch.delete(doc.ref);
      });

      // Delete related notifications
      console.log("Deleting related notifications");
      const notificationsSnapshot = await db
        .collection("notifications")
        .where("videoId", "==", videoId)
        .where("commentId", "==", event.params.commentId)
        .get();

      notificationsSnapshot.docs.forEach((doc) => {
        batch.delete(doc.ref);
      });

      await batch.commit();
      console.log("Successfully processed comment deletion");
    } catch (error) {
      console.error("Error in onCommentDeleted:", error);
    }
  }
);

// Function to handle comment like changes
export const onCommentLikeChange = onDocumentUpdated(
  "videos/{videoId}/comments/{commentId}/likes/{userId}",
  async (event) => {
    const { videoId, commentId, userId } = event.params;
    const beforeData = event.data?.before.data();
    const afterData = event.data?.after.data();
    const increment = afterData && !beforeData ? 1 : -1;

    try {
      const db = admin.firestore();
      const batch = db.batch();

      // Update the comment's like count
      const commentRef = db
        .collection("videos")
        .doc(videoId)
        .collection("comments")
        .doc(commentId);

      batch.update(commentRef, {
        likesCount: admin.firestore.FieldValue.increment(increment),
      });

      // Create or delete notification
      const commentDoc = await commentRef.get();
      const commentData = commentDoc.data();

      if (commentData && commentData.userId !== userId) {
        if (afterData && !beforeData) {
          // Like added - create notification
          const notificationRef = db.collection("notifications").doc();
          batch.set(notificationRef, {
            userId: commentData.userId,
            type: "commentLike",
            sourceUserId: userId,
            videoId,
            commentId,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
            read: false,
          });
        } else {
          // Like removed - delete notification
          const notificationSnapshot = await db
            .collection("notifications")
            .where("type", "==", "commentLike")
            .where("videoId", "==", videoId)
            .where("commentId", "==", commentId)
            .where("sourceUserId", "==", userId)
            .get();

          notificationSnapshot.docs.forEach((doc) => {
            batch.delete(doc.ref);
          });
        }
      }

      await batch.commit();
    } catch (error) {
      console.error("Error in onCommentLikeChange:", error);
    }
  }
);

interface FollowData {
  followingId: string;
}

export const followUser = functions.https.onCall(async (data: CallableRequest<FollowData>) => {
  if (!data.auth) {
    throw new functions.https.HttpsError("unauthenticated", "Must be logged in to follow users");
  }

  const followerId = data.auth.uid;
  const followingId = data.data.followingId;

  console.log(`Follow request initiated: ${followerId} -> ${followingId}`);

  if (!followingId) {
    throw new functions.https.HttpsError("invalid-argument", "Must provide a user to follow");
  }

  if (followerId === followingId) {
    throw new functions.https.HttpsError("invalid-argument", "Cannot follow yourself");
  }

  const db = admin.firestore();
  const followDoc = db.collection("follows").doc(`${followerId}_${followingId}`);

  try {
    // Use transaction to ensure atomic updates
    await db.runTransaction(async (transaction) => {
      console.log("Starting follow transaction");
      const followerRef = db.collection("users").doc(followerId);
      const followingRef = db.collection("users").doc(followingId);

      // Check if users exist
      const [followerDoc, followingDoc] = await Promise.all([
        transaction.get(followerRef),
        transaction.get(followingRef),
      ]);

      console.log("Current follower data:", followerDoc.data());
      console.log("Current following data:", followingDoc.data());

      if (!followerDoc.exists || !followingDoc.exists) {
        throw new functions.https.HttpsError("not-found", "One or both users do not exist");
      }

      // Check if already following
      const followDocSnapshot = await transaction.get(followDoc);
      if (followDocSnapshot.exists) {
        throw new functions.https.HttpsError("already-exists", "Already following this user");
      }

      console.log("Creating follow document");
      // Create follow relationship
      transaction.set(followDoc, {
        followerId,
        followingId,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      console.log("Updating follower count");
      // Update follower/following counts
      transaction.update(followerRef, {
        followingCount: admin.firestore.FieldValue.increment(1),
      });

      console.log("Updating following count");
      transaction.update(followingRef, {
        followersCount: admin.firestore.FieldValue.increment(1),
      });

      // Create notification for the user being followed
      console.log("Creating follow notification");
      const notificationRef = db.collection("notifications").doc();
      transaction.set(notificationRef, {
        userId: followingId,
        type: "follow",
        sourceUserId: followerId,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        read: false,
      });

      console.log("Transaction completed successfully");
    });

    console.log("Follow operation successful");
    return { success: true };
  } catch (error) {
    console.error("Error following user:", error);
    if (error instanceof functions.https.HttpsError) {
      throw error;
    }
    throw new functions.https.HttpsError("internal", "Failed to follow user");
  }
});

export const unfollowUser = functions.https.onCall(async (data: CallableRequest<FollowData>) => {
  if (!data.auth) {
    throw new functions.https.HttpsError("unauthenticated", "Must be logged in to unfollow users");
  }

  const followerId = data.auth.uid;
  const followingId = data.data.followingId;

  if (!followingId) {
    throw new functions.https.HttpsError("invalid-argument", "Must provide a user to unfollow");
  }

  const db = admin.firestore();
  const followDoc = db.collection("follows").doc(`${followerId}_${followingId}`);

  try {
    // Use transaction to ensure atomic updates
    await db.runTransaction(async (transaction) => {
      const followDocSnapshot = await transaction.get(followDoc);

      if (!followDocSnapshot.exists) {
        throw new functions.https.HttpsError("not-found", "Follow relationship does not exist");
      }

      const followerRef = db.collection("users").doc(followerId);
      const followingRef = db.collection("users").doc(followingId);

      // Delete follow relationship
      transaction.delete(followDoc);

      // Update follower/following counts
      transaction.update(followerRef, {
        followingCount: admin.firestore.FieldValue.increment(-1),
      });
      transaction.update(followingRef, {
        followersCount: admin.firestore.FieldValue.increment(-1),
      });
    });

    return { success: true };
  } catch (error) {
    console.error("Error unfollowing user:", error);
    if (error instanceof functions.https.HttpsError) {
      throw error;
    }
    throw new functions.https.HttpsError("internal", "Failed to unfollow user");
  }
});

// Add trigger for follows collection changes
export const onFollowChange = onDocumentUpdated(
  "follows/{followId}",
  async (event) => {
    const beforeData = event.data?.before.data();
    const afterData = event.data?.after.data();
    const followId = event.params.followId;

    console.log(`Follow document change detected: ${followId}`);
    console.log("Before:", beforeData);
    console.log("After:", afterData);

    try {
      const db = admin.firestore();

      // Document was deleted
      if (beforeData && !afterData) {
        console.log("Follow relationship deleted");
        return;
      }

      // Document was created or updated
      if (afterData) {
        const { followerId, followingId, createdAt } = afterData;
        console.log(`Follow relationship: ${followerId} -> ${followingId}`);
        console.log("Created at:", createdAt);

        // Verify document ID matches the data
        const expectedId = `${followerId}_${followingId}`;
        if (followId !== expectedId) {
          console.error(`Invalid follow document ID. Expected: ${expectedId}, Got: ${followId}`);
          // Fix the document ID
          const followRef = event.data?.after.ref;
          if (followRef) {
            await db.runTransaction(async (transaction) => {
              transaction.delete(followRef);
              transaction.set(db.collection("follows").doc(expectedId), afterData);
            });
          }
        }
      }
    } catch (error) {
      console.error("Error in onFollowChange:", error);
    }
  }
);

// Function to handle video like count changes and update user total likes
export const onVideoLikeCountChange = onDocumentUpdated(
  "videos/{videoId}",
  async (event) => {
    const beforeData = event.data?.before.data();
    const afterData = event.data?.after.data();
    const videoRef = event.data?.after.ref;

    // Only proceed if likesCount has changed
    if (beforeData?.likesCount === afterData?.likesCount) {
      return;
    }

    console.log(`Video ${event.params.videoId} likes changed:`, {
      before: beforeData?.likesCount,
      after: afterData?.likesCount,
    });

    try {
      const db = admin.firestore();
      const uploaderId = afterData?.userId || afterData?.uploaderId;

      if (!uploaderId) {
        console.error("No uploaderId found for video", event.params.videoId);
        return;
      }

      // Calculate the difference in likes
      const likeDiff = (afterData?.likesCount || 0) - (beforeData?.likesCount || 0);
      console.log(`Updating user ${uploaderId} totalLikes by ${likeDiff}`);

      let retryCount = 0;
      const maxRetries = 3;

      while (retryCount < maxRetries) {
        try {
          // Update user's totalLikes using a transaction for consistency
          await db.runTransaction(async (transaction) => {
            const userRef = db.collection("users").doc(uploaderId);
            const userDoc = await transaction.get(userRef);

            if (!userDoc.exists) {
              console.error(`User document ${uploaderId} not found`);
              return;
            }

            const currentTotalLikes = userDoc.data()?.totalLikes || 0;
            const newTotalLikes = Math.max(0, currentTotalLikes + likeDiff);

            // Verify the video still exists and has the expected like count
            if (videoRef) {
              const videoDoc = await transaction.get(videoRef);
              if (!videoDoc.exists) {
                console.error("Video no longer exists");
                return;
              }

              const currentLikesCount = videoDoc.data()?.likesCount || 0;
              if (currentLikesCount !== afterData?.likesCount) {
                console.log("Like count changed during transaction, retrying");
                throw new Error("Retry needed - like count changed");
              }
            }

            transaction.update(userRef, { totalLikes: newTotalLikes });
            console.log(`Successfully updated user ${uploaderId} totalLikes to ${newTotalLikes}`);
          });

          // If successful, break the retry loop
          break;
        } catch (e) {
          retryCount++;
          console.log(`Retry attempt ${retryCount} of ${maxRetries}`);
          if (retryCount === maxRetries) throw e;
          // Wait before retrying (exponential backoff)
          await new Promise((resolve) => setTimeout(resolve, Math.pow(2, retryCount) * 1000));
        }
      }
    } catch (error) {
      console.error("Error in onVideoLikeCountChange:", error);

      // Add to reconciliation queue for retry
      try {
        const db = admin.firestore();
        await db.collection("reconciliation_queue").add({
          userId: afterData?.userId || afterData?.uploaderId,
          videoId: event.params.videoId,
          type: "like_count_change",
          expectedLikeCount: afterData?.likesCount,
          timestamp: admin.firestore.FieldValue.serverTimestamp(),
        });
        console.log("Added to reconciliation queue for retry");
      } catch (e) {
        console.error("Error adding to reconciliation queue:", e);
      }
    }
  }
);

// Utility function to recalculate user's total likes
export const recalculateUserTotalLikes = onCall(async (request: CallableRequest) => {
  const userId = request.data.userId;
  if (!userId) {
    throw new Error("userId is required");
  }
  console.log(`Recalculating total likes for user ${userId}`);
  try {
    const db = admin.firestore();
    // Query videos where either 'userId' or 'uploaderId' equals the given userId (no status filter)
    const [query1, query2] = await Promise.all([
      db.collection("videos")
        .where("userId", "==", userId)
        .get(),
      db.collection("videos")
        .where("uploaderId", "==", userId)
        .get(),
    ]);
    // Use a map to avoid duplicate documents if both fields exist
    const videosMap = new Map<string, number>();
    query1.forEach((doc) => {
      videosMap.set(doc.id, doc.data().likesCount || 0);
    });
    query2.forEach((doc) => {
      if (!videosMap.has(doc.id)) {
        videosMap.set(doc.id, doc.data().likesCount || 0);
      }
    });
    let totalLikes = 0;
    videosMap.forEach((val) => {
      totalLikes += val;
    });

    // Update user document
    await db.collection("users").doc(userId).update({
      totalLikes: totalLikes,
    });
    console.log(`Successfully recalculated total likes for user ${userId}: ${totalLikes}`);
    return { success: true, totalLikes };
  } catch (error) {
    console.error("Error in recalculateUserTotalLikes:", error);
    throw new Error("Failed to recalculate total likes");
  }
});

export const onVideoCreated = onDocumentCreated("videos/{videoId}", async (event) => {
  const snapshot = event.data;
  if (!snapshot) {
    console.log("No data associated with the event");
    return;
  }

  const videoData = snapshot.data();
  const videoId = event.params.videoId;
  const db = admin.firestore();
  const batch = db.batch();

  try {
    // Get all followers of the video creator
    const followersSnapshot = await db
      .collection("follows")
      .where("followingId", "==", videoData.userId)
      .get();

    // Create notifications for each follower
    followersSnapshot.docs.forEach((doc) => {
      const notificationRef = db.collection("notifications").doc();
      batch.set(notificationRef, {
        userId: doc.data().followerId,
        type: "video_post",
        sourceUserId: videoData.userId,
        videoId: videoId,
        videoThumbnailURL: videoData.thumbnailURL,
        videoDescription: videoData.description,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        read: false,
      });
    });

    // Update user's totalVideos count
    const userRef = db.collection("users").doc(videoData.userId);
    batch.update(userRef, {
      totalVideos: admin.firestore.FieldValue.increment(1),
    });

    await batch.commit();
    console.log("Successfully processed video creation and notifications");
  } catch (error) {
    console.error("Error in onVideoCreated:", error);
  }
});

// Function to handle video deletion and update total likes
export const onVideoDeleted = onDocumentDeleted("videos/{videoId}", async (event) => {
  const videoData = event.data?.data();
  if (!videoData) {
    console.log("No video data found for deletion event");
    return;
  }

  const db = admin.firestore();
  const userId = videoData.userId || videoData.uploaderId;

  if (!userId) {
    console.error("No user ID found for video", event.params.videoId);
    return;
  }

  try {
    // Use transaction to ensure atomic updates
    await db.runTransaction(async (transaction) => {
      // Get current user data
      const userRef = db.collection("users").doc(userId);
      const userDoc = await transaction.get(userRef);

      if (!userDoc.exists) {
        console.error(`User document ${userId} not found`);
        return;
      }

      // Calculate new total likes
      const currentTotalLikes = userDoc.data()?.totalLikes || 0;
      const videoLikes = videoData.likesCount || 0;
      const newTotalLikes = Math.max(0, currentTotalLikes - videoLikes);

      console.log(`Updating total likes for user ${userId}:`, {
        currentTotalLikes,
        videoLikes,
        newTotalLikes,
      });

      // Update user's total likes
      transaction.update(userRef, {
        totalLikes: newTotalLikes,
      });

      // Delete all likes for this video from users' likedVideos collections
      const likesSnapshot = await db
        .collectionGroup("likedVideos")
        .where("videoId", "==", event.params.videoId)
        .get();

      likesSnapshot.docs.forEach((doc) => {
        transaction.delete(doc.ref);
      });
    });

    console.log(`Successfully processed video deletion for ${event.params.videoId}`);
  } catch (error) {
    console.error("Error in onVideoDeleted:", error);

    // Add to reconciliation queue for retry
    try {
      await db.collection("reconciliation_queue").add({
        userId,
        videoId: event.params.videoId,
        type: "video_deletion",
        timestamp: admin.firestore.FieldValue.serverTimestamp(),
      });
      console.log("Added to reconciliation queue for retry");
    } catch (e) {
      console.error("Error adding to reconciliation queue:", e);
    }
  }
});

// Function to force reconciliation for all users
export const forceReconcileAllUsers = onCall(async () => {
  try {
    const db = admin.firestore();
    const usersSnapshot = await db.collection("users").get();

    console.log(`Starting reconciliation for ${usersSnapshot.docs.length} users`);
    const results: Record<string, {
      success: boolean;
      oldCount?: number;
      newCount?: number;
      unchanged?: boolean;
      error?: string;
    }> = {};

    for (const userDoc of usersSnapshot.docs) {
      const userId = userDoc.id;
      try {
        // Query all active videos by this user
        const videosSnapshot = await db
          .collection("videos")
          .where("userId", "==", userId)
          .where("status", "==", "active")
          .get();

        // Calculate total likes
        let totalLikes = 0;
        videosSnapshot.docs.forEach((doc) => {
          totalLikes += (doc.data().likesCount || 0);
        });

        // Get current user data
        const currentTotalLikes = userDoc.data().totalLikes || 0;

        // Update if different
        if (currentTotalLikes !== totalLikes) {
          await userDoc.ref.update({ totalLikes });
          results[userId] = {
            success: true,
            oldCount: currentTotalLikes,
            newCount: totalLikes,
          };
          console.log(`Updated user ${userId}: ${currentTotalLikes} -> ${totalLikes} likes`);
        } else {
          results[userId] = { success: true, unchanged: true };
          console.log(`No update needed for user ${userId}: ${totalLikes} likes`);
        }
      } catch (error: unknown) {
        console.error(`Error reconciling user ${userId}:`, error);
        results[userId] = {
          success: false,
          error: error instanceof Error ? error.message : String(error),
        };
      }
    }

    return { success: true, results };
  } catch (error: unknown) {
    console.error("Error in forceReconcileAllUsers:", error);
    throw new Error("Failed to reconcile users");
  }
});

// Helper functions for bucket calculation
function calculateBudgetBucket(budget: number): string {
  if (budget <= 10) return "0-10";
  if (budget <= 25) return "10-25";
  if (budget <= 50) return "25-50";
  if (budget <= 100) return "50-100";
  return "100+";
}

function calculateCaloriesBucket(calories: number): string {
  if (calories <= 300) return "0-300";
  if (calories <= 600) return "300-600";
  if (calories <= 1000) return "600-1000";
  if (calories <= 1500) return "1000-1500";
  return "1500+";
}

function calculatePrepTimeBucket(prepTimeMinutes: number): string {
  if (prepTimeMinutes <= 15) return "0-15";
  if (prepTimeMinutes <= 30) return "15-30";
  if (prepTimeMinutes <= 60) return "30-60";
  if (prepTimeMinutes <= 120) return "60-120";
  return "120+";
}

function generateTags(
  budget: number,
  calories: number,
  prepTimeMinutes: number,
  spiciness: number,
  hashtags: string[],
): string[] {
  const tags: string[] = [];

  // Add bucket tags
  tags.push(`budget_${calculateBudgetBucket(budget)}`);
  tags.push(`calories_${calculateCaloriesBucket(calories)}`);
  tags.push(`prep_${calculatePrepTimeBucket(prepTimeMinutes)}`);

  // Add spiciness tag
  if (spiciness > 0) {
    tags.push(`spicy_${spiciness}`);
  }

  // Add hashtags
  tags.push(...hashtags.map((tag) => `tag_${tag}`));

  return tags;
}

// Migration function to add tags to existing videos
export const migrateVideosToTags = functions.https.onRequest(async (req, res) => {
  try {
    console.log("Starting video migration...");
    const db = admin.firestore();
    const videosRef = db.collection("videos");
    // Get all videos
    const snapshot = await videosRef.get();
    let updatedCount = 0;
    const skippedCount = 0;
    let errorCount = 0;
    for (const doc of snapshot.docs) {
      try {
        const video = doc.data();
        // Generate tags for the video
        const tags = generateTags(
          video.budget || 0,
          video.calories || 0,
          video.prepTimeMinutes || 0,
          video.spiciness || 0,
          video.hashtags || []
        );
        // Update the video with tags
        await videosRef.doc(doc.id).update({
          tags: tags,
        });
        updatedCount++;
        console.log(`Updated video ${doc.id} with tags:`, tags);
      } catch (err) {
        errorCount++;
        console.error(`Error updating video ${doc.id}:`, err);
      }
    }
    const message =
      `Migration completed. Updated: ${updatedCount}, Skipped: ${skippedCount}, Errors: ${errorCount}`;
    console.log(message);
    res.status(200).json({
      success: true,
      updatedCount,
      skippedCount,
      errorCount,
      message: `Successfully migrated ${updatedCount} videos. ` +
        `Skipped ${skippedCount}. Encountered ${errorCount} errors.`,
    });
  } catch (error) {
    console.error("Error in migration:", error);
    res.status(500).json({ error: "An error occurred during migration" });
  }
});

// Cloud function to analyze video and store description
export const analyzeVideo = onDocumentCreated(
  {
    document: "videos/{videoId}",
    secrets: ["OPENAI_API_KEY"],
  },
  async (event: { data: DocumentSnapshot | undefined; params: { videoId: string } }) => {
    try {
      console.log("analyzeVideo function started", { videoId: event.params.videoId });

      const snapshot = event.data;
      if (!snapshot) {
        console.error("No data associated with the event");
        return;
      }

      const videoData = snapshot.data();
      console.log("Video data retrieved:", {
        hasData: !!videoData,
        hasThumbnail: !!videoData?.thumbnailURL,
        videoId: event.params.videoId,
      });

      if (!videoData || !videoData.thumbnailURL) {
        console.error("No video data or thumbnail URL found", {
          videoId: event.params.videoId,
          videoData: videoData ? "exists" : "null",
          thumbnailURL: videoData?.thumbnailURL ? "exists" : "null",
        });
        return;
      }

      console.log("Getting OpenAI API key from environment...");
      const apiKey = process.env.OPENAI_API_KEY;
      if (!apiKey) {
        console.error("OpenAI API key not found in environment variables");
        throw new Error("OpenAI API key not configured");
      }

      console.log("Initializing OpenAI client...");
      const openai = new OpenAI({
        apiKey: apiKey,
      });

      const systemPrompt =
        "You are a cooking video analyzer. Describe what is happening in this " +
        "thumbnail from a cooking video. Focus on the cooking techniques, " +
        "ingredients, and overall dish being prepared. Be concise but descriptive, " +
        "and highlight any unique or interesting aspects of the preparation method " +
        "or presentation.";

      console.log("Preparing messages for OpenAI...");
      const messages: ChatCompletionMessageParam[] = [
        {
          role: "system",
          content: systemPrompt,
        },
        {
          role: "user",
          content: [
            {
              type: "text",
              text: "Please analyze this cooking video thumbnail:",
            },
            {
              type: "image_url",
              image_url: {
                url: videoData.thumbnailURL,
              },
            },
          ],
        },
      ];

      console.log("Calling OpenAI API...", {
        thumbnailURL: videoData.thumbnailURL.substring(0, 50) + "...",
      });

      const response = await openai.chat.completions.create({
        model: "gpt-4o-mini",
        messages,
        max_tokens: 300,
      });

      console.log("OpenAI API response received", {
        hasChoices: !!response.choices.length,
        firstChoice: !!response.choices[0]?.message?.content,
      });

      // Store the AI-generated description
      console.log("Storing AI-generated description...");
      const db = admin.firestore();
      await db.collection("videos").doc(event.params.videoId).update({
        aiEnhancements: {
          description: response.choices[0].message.content || "",
          generatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
      });

      console.log("Successfully analyzed video and stored description", {
        videoId: event.params.videoId,
        descriptionLength: response.choices[0].message.content?.length || 0,
      });
    } catch (error: unknown) {
      console.error("Error in analyzeVideo:", error);
      if (error instanceof Error) {
        console.error("Error details:", {
          name: error.name,
          message: error.message,
          stack: error.stack,
          videoId: event.params.videoId,
        });
      } else {
        console.error("Unknown error type:", error);
      }
      throw error;
    }
  },
);
// export const analyzeExistingVideos = onCall(
//   {
//     secrets: ["OPENAI_API_KEY"],
//   },
//   async () => {
//     try {
//       console.log("analyzeExistingVideos function started");

//       // Get all active videos
//       const db = admin.firestore();
//       const videosSnapshot = await db.collection("videos")
//         .where("status", "==", "active")
//         .get();

//       console.log(`Found ${videosSnapshot.docs.length} active videos to analyze`);

//       let processedCount = 0;
//       let skippedCount = 0;
//       let errorCount = 0;

//       for (const doc of videosSnapshot.docs) {
//         try {
//           const videoData = doc.data();
//           if (!videoData.thumbnailURL) {
//             console.log(`Skipping video ${doc.id} - no thumbnail URL`);
//             skippedCount++;
//             continue;
//           }

//           // Skip if already has AI enhancements and no force flag
//           if (videoData.aiEnhancements?.description) {
//             console.log(`Skipping video ${doc.id} - already has AI description`);
//             skippedCount++;
//             continue;
//           }

//           console.log("Getting OpenAI API key from environment...");
//           const apiKey = process.env.OPENAI_API_KEY;
//           if (!apiKey) {
//             console.error("OpenAI API key not found in environment variables");
//             throw new functions.https.HttpsError(
//               "failed-precondition",
//               "OpenAI API key not configured",
//             );
//           }

//           console.log("Initializing OpenAI client...");
//           const openai = new OpenAI({
//             apiKey: apiKey,
//           });

//           const systemPrompt =
//             "You are a cooking video analyzer. Describe what is happening in this " +
//             "thumbnail from a cooking video. Focus on the cooking techniques, " +
//             "ingredients, and overall dish being prepared. Be concise but descriptive, " +
//             "and highlight any unique or interesting aspects of the preparation method " +
//             "or presentation.";

//           console.log("Preparing messages for OpenAI...");
//           const messages: ChatCompletionMessageParam[] = [
//             {
//               role: "system",
//               content: systemPrompt,
//             },
//             {
//               role: "user",
//               content: [
//                 {
//                   type: "text",
//                   text: "Please analyze this cooking video thumbnail:",
//                 },
//                 {
//                   type: "image_url",
//                   image_url: {
//                     url: videoData.thumbnailURL,
//                   },
//                 },
//               ],
//             },
//           ];

//           console.log("Calling OpenAI API...", {
//             thumbnailURL: videoData.thumbnailURL.substring(0, 50) + "...",
//           });

//           const response = await openai.chat.completions.create({
//             model: "gpt-4o-mini",
//             messages,
//             max_tokens: 300,
//           });

//           console.log("OpenAI API response received", {
//             hasChoices: !!response.choices.length,
//             firstChoice: !!response.choices[0]?.message?.content,
//           });

//           // Store the AI-generated description
//           console.log("Storing AI-generated description...");
//           await db.collection("videos").doc(doc.id).update({
//             aiEnhancements: {
//               description: response.choices[0].message.content || "",
//               generatedAt: admin.firestore.FieldValue.serverTimestamp(),
//             },
//           });

//           console.log("Successfully analyzed video and stored description", {
//             videoId: doc.id,
//             descriptionLength: response.choices[0].message.content?.length || 0,
//           });

//           processedCount++;
//         } catch (error) {
//           console.error(`Error processing video ${doc.id}:`, error);
//           errorCount++;
//         }
//       }

//       return {
//         success: true,
//         totalVideos: videosSnapshot.docs.length,
//         processedCount,
//         skippedCount,
//         errorCount,
//       };
//     } catch (error: unknown) {
//       console.error("Error in analyzeExistingVideos:", error);
//       if (error instanceof functions.https.HttpsError) {
//         throw error;
//       }
//       if (error instanceof Error) {
//         console.error("Error details:", {
//           name: error.name,
//           message: error.message,
//           stack: error.stack,
//         });
//       }
//       throw new functions.https.HttpsError("internal", "Failed to analyze videos");
//     }
//   }
// );

