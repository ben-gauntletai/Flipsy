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
} from "firebase-functions/v2/firestore";
import * as admin from "firebase-admin";
import { OpenAI } from "openai";
import { PineconeService } from "./services/pinecone.service";
import { initializeApp } from "firebase-admin/app";
import { VideoVector } from "./types";

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

// Initialize Firebase Admin
initializeApp();

// Initialize OpenAI
// const openai = new OpenAI({
//   apiKey: process.env.OPENAI_API_KEY,
// });

// Initialize Pinecone
// const pineconeService = new PineconeService(process.env.PINECONE_API_KEY || "");

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
      .where("displayNameLower", "==", data.displayName.toLowerCase())
      .get();

    if (!displayNameQuery.empty) {
      throw new functions.https.HttpsError("already-exists", "This display name is already taken.");
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
      displayNameLower: data.displayName.toLowerCase(), // Add lowercase version for searching
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
      throw new functions.https.HttpsError("invalid-argument", "The email address is not valid.");
    }

    if (firebaseError.code === "auth/weak-password") {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "The password must be at least 6 characters long.",
      );
    }

    throw new functions.https.HttpsError("internal", "An error occurred while creating the user.");
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
  },
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
  },
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
      const commentRef = db.collection("videos").doc(videoId).collection("comments").doc(commentId);

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
  },
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
export const onFollowChange = onDocumentUpdated("follows/{followId}", async (event) => {
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
});

// Function to handle video like count changes and update user total likes
export const onVideoLikeCountChange = onDocumentUpdated("videos/{videoId}", async (event) => {
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
});

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
      db.collection("videos").where("userId", "==", userId).get(),
      db.collection("videos").where("uploaderId", "==", userId).get(),
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
    const results: Record<
      string,
      {
        success: boolean;
        oldCount?: number;
        newCount?: number;
        unchanged?: boolean;
        error?: string;
      }
    > = {};

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
          totalLikes += doc.data().likesCount || 0;
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

/**
 * Calculate the budget bucket for a given budget amount.
 * @param {number} budget The budget amount in currency units
 * @return {string} The budget range bucket identifier
 */
function calculateBudgetBucket(budget: number): string {
  if (budget <= 10) return "0-10";
  if (budget <= 25) return "10-25";
  if (budget <= 50) return "25-50";
  if (budget <= 100) return "50-100";
  return "100+";
}

/**
 * Calculate the calories bucket for a given calorie count.
 * @param {number} calories The number of calories
 * @return {string} The calorie range bucket identifier
 */
function calculateCaloriesBucket(calories: number): string {
  if (calories <= 300) return "0-300";
  if (calories <= 600) return "300-600";
  if (calories <= 1000) return "600-1000";
  if (calories <= 1500) return "1000-1500";
  return "1500+";
}

/**
 * Calculate the preparation time bucket for given minutes.
 * @param {number} prepTimeMinutes The preparation time in minutes
 * @return {string} The time range bucket identifier
 */
function calculatePrepTimeBucket(prepTimeMinutes: number): string {
  if (prepTimeMinutes <= 15) return "0-15";
  if (prepTimeMinutes <= 30) return "15-30";
  if (prepTimeMinutes <= 60) return "30-60";
  if (prepTimeMinutes <= 120) return "60-120";
  return "120+";
}

/**
 * Generate tags for a video based on its properties.
 * @param {number} budget The video's budget amount
 * @param {number} calories The calorie count for the recipe
 * @param {number} prepTimeMinutes The preparation time in minutes
 * @param {number} spiciness The spiciness level
 * @param {string[]} hashtags Additional hashtags to include
 * @return {string[]} Array of generated tags
 */
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
          video.hashtags || [],
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
    const message = [
      "Migration completed.",
      `Updated: ${updatedCount},`,
      `Skipped: ${skippedCount},`,
      `Errors: ${errorCount}`,
    ].join(" ");
    console.log(message);
    res.status(200).json({
      success: true,
      updatedCount,
      skippedCount,
      errorCount,
      message:
        `Successfully migrated ${updatedCount} videos. ` +
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
  async (event) => {
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

      // Initialize OpenAI client
      const openai = new OpenAI({
        apiKey: process.env.OPENAI_API_KEY,
      });

      const systemPrompt =
        "You are a cooking video analyzer. Describe what is happening in this " +
        "thumbnail from a cooking video. Focus on the cooking techniques, " +
        "ingredients, and overall dish being prepared. Be concise but descriptive, " +
        "and highlight any unique or interesting aspects of the preparation method " +
        "or presentation.";

      console.log("Preparing messages for OpenAI...");
      const messages = [
        {
          role: "system" as const,
          content: systemPrompt,
        },
        {
          role: "user" as const,
          content: [
            {
              type: "text" as const,
              text: "Please analyze this cooking video thumbnail:",
            },
            {
              type: "image_url" as const,
              image_url: {
                url: videoData.thumbnailURL,
              },
            },
          ],
        },
      ];

      console.log("Calling OpenAI API...");
      const response = await openai.chat.completions.create({
        model: "gpt-4o-mini",
        messages,
        max_tokens: 300,
      });

      console.log("OpenAI API response received", {
        hasChoices: !!response.choices.length,
        firstChoice: !!response.choices[0]?.message?.content,
      });

      // Store the AI-generated description and update status
      await snapshot.ref.update({
        aiEnhancements: {
          description: response.choices[0].message.content || "",
          generatedAt: admin.firestore.FieldValue.serverTimestamp(),
          status: "completed",
        },
        vectorEmbedding: {
          status: "pending", // Signal that embedding can now be generated
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
      });

      console.log("Successfully analyzed video and stored description", {
        videoId: event.params.videoId,
        descriptionLength: response.choices[0].message.content?.length || 0,
      });
    } catch (error) {
      console.error("Error in analyzeVideo:", error);

      // Update status to failed
      if (event.data) {
        await event.data.ref.update({
          aiEnhancements: {
            status: "failed",
            error: error instanceof Error ? error.message : "Unknown error",
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
        });
      }

      throw error;
    }
  },
);

export const analyzeExistingVideos = onCall(
  {
    secrets: ["OPENAI_API_KEY", "PINECONE_API_KEY", "PINECONE_ENVIRONMENT"],
  },
  async (request) => {
    try {
      console.log("analyzeExistingVideos function started");
      const forceRegenerate = request.data?.forceRegenerate || false;

      // Get all active videos
      const db = admin.firestore();
      const videosSnapshot = await db.collection("videos").where("status", "==", "active").get();

      console.log(`Found ${videosSnapshot.docs.length} active videos to process`, {
        forceRegenerate,
      });

      let processedCount = 0;
      let skippedCount = 0;
      let errorCount = 0;
      let embeddingsCount = 0;

      // Initialize services
      const openai = new OpenAI({
        apiKey: process.env.OPENAI_API_KEY,
      });

      const pineconeService = new PineconeService(process.env.PINECONE_API_KEY || "");

      for (const doc of videosSnapshot.docs) {
        try {
          const videoData = doc.data();
          const videoId = doc.id;
          let needsEmbeddingUpdate = false;
          let aiDescription = videoData.aiEnhancements?.description;

          // Skip if no thumbnail
          if (!videoData.thumbnailURL) {
            console.log(`Skipping video ${videoId} - no thumbnail URL`);
            skippedCount++;
            continue;
          }

          // Generate AI description if needed
          if (!aiDescription || forceRegenerate) {
            console.log(`Processing AI description for video ${videoId}`);

            const systemPrompt =
              "You are a cooking video analyzer. Describe what is happening in this " +
              "thumbnail from a cooking video. Focus on the cooking techniques, " +
              "ingredients, and overall dish being prepared. Be concise but descriptive, " +
              "and highlight any unique or interesting aspects of the preparation method " +
              "or presentation.";

            const messages = [
              {
                role: "system" as const,
                content: systemPrompt,
              },
              {
                role: "user" as const,
                content: [
                  {
                    type: "text" as const,
                    text: "Please analyze this cooking video thumbnail:",
                  },
                  {
                    type: "image_url" as const,
                    image_url: {
                      url: videoData.thumbnailURL,
                    },
                  },
                ],
              },
            ];

            const response = await openai.chat.completions.create({
              model: "gpt-4o-mini",
              messages,
              max_tokens: 300,
            });

            aiDescription = response.choices[0].message.content || "";
            needsEmbeddingUpdate = true;

            // Store the AI-generated description
            await doc.ref.update({
              aiEnhancements: {
                description: aiDescription,
                generatedAt: admin.firestore.FieldValue.serverTimestamp(),
                status: "completed",
              },
            });

            processedCount++;
          } else {
            console.log(`Skipping AI description for video ${videoId} - already exists`);
            skippedCount++;
          }

          // Generate or update embedding if needed
          if (
            needsEmbeddingUpdate ||
            !videoData.vectorEmbedding?.status ||
            videoData.vectorEmbedding.status === "failed"
          ) {
            console.log(`Generating embedding for video ${videoId}`);

            // Update video with pending status
            await doc.ref.update({
              vectorEmbedding: {
                status: "pending",
                updatedAt: new Date(),
              },
            });

            // Generate embedding using all available content
            const content = [
              videoData.description || "",
              videoData.hashtags?.join(" ") || "",
              videoData.tags?.join(" ") || "",
              aiDescription || "",
            ].join(" ");

            const embeddingResponse = await openai.embeddings.create({
              model: "text-embedding-3-large",
              input: content,
            });

            const embedding = embeddingResponse.data[0].embedding;

            // Create vector record with complete metadata
            const vector: VideoVector = {
              id: videoId,
              values: embedding,
              metadata: {
                userId: String(videoData.userId),
                status: String(videoData.status),
                privacy: String(videoData.privacy),
                tags: Array.isArray(videoData.tags) ? videoData.tags.map(String) : [],
                aiDescription: String(videoData.aiEnhancements?.description || ""),
                version: 1,
                contentLength: content.length,
                hasDescription: String(!!videoData.description),
                hasAiDescription: String(!!videoData.aiEnhancements?.description),
                hasTags: String(!!(videoData.tags?.length > 0)),
              },
            };

            // Upsert to Pinecone
            await pineconeService.upsertVector(vector);
            embeddingsCount++;

            // Update Firestore with complete vector embedding metadata
            await doc.ref.update({
              vectorEmbedding: {
                id: videoId,
                status: "completed",
                updatedAt: new Date(),
                model: "text-embedding-3-large",
                dimensions: embedding.length,
                version: 1,
                contentLength: content.length,
                retryCount: (videoData.vectorEmbedding?.retryCount || 0) + 1,
                hasDescription: !!videoData.description,
                hasAiDescription: !!videoData.aiEnhancements?.description,
                hasTags: (videoData.tags?.length || 0) > 0,
              },
            });

            console.log(`Successfully generated embedding for video ${videoId}`);
          }
        } catch (error) {
          console.error(`Error processing video ${doc.id}:`, error);
          errorCount++;
        }
      }

      return {
        success: true,
        totalVideos: videosSnapshot.docs.length,
        processedCount: processedCount,
        skippedCount: skippedCount,
        generatedEmbeddings: embeddingsCount,
        errorCount,
      };
    } catch (error: unknown) {
      console.error("Error in analyzeExistingVideos:", error);
      if (error instanceof functions.https.HttpsError) {
        throw error;
      }
      if (error instanceof Error) {
        console.error("Error details:", {
          name: error.name,
          message: error.message,
          stack: error.stack,
        });
      }
      throw new functions.https.HttpsError("internal", "Failed to process videos");
    }
  },
);

/**
 * Generate vector embedding for video content
 * This function now triggers on document updates to ensure AI description is ready
 */
export const generateVideoEmbedding = onDocumentUpdated(
  {
    document: "videos/{videoId}",
    secrets: ["OPENAI_API_KEY", "PINECONE_API_KEY", "PINECONE_ENVIRONMENT"],
    region: "us-central1",
  },
  async (event) => {
    const afterData = event.data?.after.data();
    const prevData = event.data?.before.data();
    const videoId = event.params.videoId;

    if (!afterData || !prevData || !event.data) {
      console.error("Missing data in update event");
      return;
    }

    // Check if relevant fields were updated
    const shouldUpdateEmbedding =
      prevData.description !== afterData.description ||
      JSON.stringify(prevData.hashtags) !== JSON.stringify(afterData.hashtags) ||
      JSON.stringify(prevData.tags) !== JSON.stringify(afterData.tags);

    if (!shouldUpdateEmbedding) {
      functions.logger.info("No relevant changes for vector embedding", { videoId });
      return;
    }

    functions.logger.info("Updating vector embedding for video", { videoId });

    try {
      // Initialize services with secrets
      const openai = new OpenAI({
        apiKey: process.env.OPENAI_API_KEY,
      });

      const pineconeService = new PineconeService(process.env.PINECONE_API_KEY || "");

      // Update video with pending status
      await event.data.after.ref.update({
        vectorEmbedding: {
          status: "pending",
          updatedAt: new Date(),
        },
      });

      // Generate new embedding
      const content = [
        afterData.description || "",
        afterData.hashtags?.join(" ") || "",
        afterData.tags?.join(" ") || "",
      ].join(" ");

      const embeddingResponse = await openai.embeddings.create({
        model: "text-embedding-3-large",
        input: content,
      });

      const embedding = embeddingResponse.data[0].embedding;

      // Create vector record
      const vector: VideoVector = {
        id: videoId,
        values: embedding,
        metadata: {
          userId: String(afterData.userId),
          status: String(afterData.status),
          privacy: String(afterData.privacy),
          tags: Array.isArray(afterData.tags) ? afterData.tags.map(String) : [],
          aiDescription: String(afterData.aiEnhancements?.description || ""),
          version: 1,
          contentLength: content.length,
          hasDescription: String(!!afterData.description),
          hasAiDescription: String(!!afterData.aiEnhancements?.description),
          hasTags: String(!!(afterData.tags?.length > 0)),
        },
      };

      // Upsert to Pinecone
      await pineconeService.upsertVector(vector);

      // Update video with completed status and embedding metadata
      await event.data.after.ref.update({
        vectorEmbedding: {
          id: videoId,
          status: "completed",
          updatedAt: new Date(),
          model: "text-embedding-3-large",
          dimensions: embedding.length,
          version: 1,
          contentLength: content.length,
          retryCount: (afterData.vectorEmbedding?.retryCount || 0) + 1,
          hasDescription: !!afterData.description,
          hasAiDescription: !!afterData.aiEnhancements?.description,
          hasTags: (afterData.tags?.length || 0) > 0,
        },
      });

      functions.logger.info("Successfully updated vector embedding", {
        videoId,
        dimensions: embedding.length,
        model: "text-embedding-3-large",
        contentLength: content.length,
      });
    } catch (error) {
      functions.logger.error("Error updating vector embedding", { error, videoId });

      // Update video with failed status and detailed error information
      await event.data.after.ref.update({
        vectorEmbedding: {
          id: videoId,
          status: "failed",
          updatedAt: new Date(),
          error: error instanceof Error ? error.message : "Unknown error",
          errorDetails:
            error instanceof Error
              ? {
                  name: error.name,
                  message: error.message,
                  stack: error.stack,
                }
              : undefined,
          retryCount: (afterData.vectorEmbedding?.retryCount || 0) + 1,
          lastAttemptedModel: "text-embedding-3-large",
        },
      });
    }
  },
);

/**
 * Delete vector embedding when video is deleted
 */
export const deleteVideoEmbedding = onDocumentDeleted(
  {
    document: "videos/{videoId}",
    secrets: ["PINECONE_API_KEY", "PINECONE_ENVIRONMENT"],
    region: "us-central1",
  },
  async (event) => {
    const videoId = event.params.videoId;

    functions.logger.info("Deleting vector embedding for video", { videoId });

    try {
      const pineconeService = new PineconeService(process.env.PINECONE_API_KEY || "");

      await pineconeService.deleteVector(videoId);
      functions.logger.info("Successfully deleted vector embedding", { videoId });
    } catch (error) {
      functions.logger.error("Error deleting vector embedding", { error, videoId });
    }
  },
);

export const getVideoSummary = onCall(async (request: CallableRequest) => {
  const { videoId } = request.data;
  if (!videoId) {
    throw new functions.https.HttpsError("invalid-argument", "Video ID is required");
  }

  const summary = "Video summary placeholder";
  const keywords = ["keyword1", "keyword2"];

  return {
    summary,
    keywords,
  };
});

export const generateVideoSummary = onCall(
  {
    secrets: ["OPENAI_API_KEY"],
  },
  async (request) => {
    const { videoId } = request.data;
    if (!videoId) {
      throw new functions.https.HttpsError("invalid-argument", "Video ID is required");
    }

    try {
      const db = admin.firestore();
      const videoDoc = await db.collection("videos").doc(videoId).get();
      const videoData = videoDoc.data();

      if (!videoData) {
        throw new functions.https.HttpsError("not-found", "Video not found");
      }

      const openai = new OpenAI({
        apiKey: process.env.OPENAI_API_KEY,
      });

      const content = [
        videoData.description || "",
        videoData.hashtags?.join(" ") || "",
        videoData.aiEnhancements?.description || "",
      ].join("\n\n");

      const systemPrompt =
        "You are a cooking video summarizer. Create a concise summary of the video content " +
        "and extract relevant keywords.";

      const response = await openai.chat.completions.create({
        model: "gpt-4o-mini",
        messages: [
          {
            role: "system",
            content: systemPrompt,
          },
          {
            role: "user",
            content: [
              "Please summarize this cooking video content",
              "and extract keywords:",
              "",
              content,
            ].join("\n"),
          },
        ],
        max_tokens: 300,
      });

      const summary = response.choices[0].message.content || "";
      const keywords =
        summary
          .split("\n")
          .find((line) => line.toLowerCase().startsWith("keywords:"))
          ?.replace(/^keywords:/i, "")
          .split(",")
          .map((k) => k.trim())
          .filter(Boolean) || [];

      return {
        summary,
        keywords,
      };
    } catch (error) {
      console.error("Error generating video summary:", error);
      throw new functions.https.HttpsError("internal", "Failed to generate video summary");
    }
  },
);

interface SearchOptions {
  query: string;
  limit?: number;
}

export const searchContent = onCall(
  {
    secrets: ["OPENAI_API_KEY", "PINECONE_API_KEY"],
  },
  async (request: CallableRequest<SearchOptions>) => {
    try {
      const { query, limit = 20 } = request.data;
      console.log(`Searching content with query: "${query}"`);

      const openai = new OpenAI({
        apiKey: process.env.OPENAI_API_KEY,
      });

      const pineconeService = new PineconeService(process.env.PINECONE_API_KEY || "");

      const embedding = await openai.embeddings.create({
        model: "text-embedding-3-large",
        input: query,
      });

      const queryVector = embedding.data[0].embedding;

      const searchResponse = await pineconeService.hybridSearch({
        query,
        queryVector,
        limit,
      });

      console.log(`Found ${searchResponse.results.length} results`);

      return searchResponse;
    } catch (error) {
      console.error("Error in searchContent:", error);
      throw new functions.https.HttpsError("internal", `Failed to search content: ${error}`);
    }
  },
);

// Migration function to add lowercase display names
export const migrateUsersDisplayNames = onCall(async () => {
  try {
    const db = admin.firestore();
    const usersSnapshot = await db.collection("users").get();

    console.log(`Starting migration for ${usersSnapshot.docs.length} users`);
    const results: Record<
      string,
      {
        success: boolean;
        error?: string;
      }
    > = {};

    for (const userDoc of usersSnapshot.docs) {
      try {
        const userData = userDoc.data();
        if (!userData.displayNameLower && userData.displayName) {
          await userDoc.ref.update({
            displayNameLower: userData.displayName.toLowerCase(),
          });
          results[userDoc.id] = { success: true };
          console.log(`Updated user ${userDoc.id} with lowercase display name`);
        } else {
          results[userDoc.id] = { success: true };
          console.log(`User ${userDoc.id} already has lowercase display name`);
        }
      } catch (error) {
        console.error(`Error updating user ${userDoc.id}:`, error);
        results[userDoc.id] = {
          success: false,
          error: error instanceof Error ? error.message : String(error),
        };
      }
    }

    return { success: true, results };
  } catch (error) {
    console.error("Error in migrateUsersDisplayNames:", error);
    throw new functions.https.HttpsError("internal", "Failed to migrate user display names");
  }
});

// Migration function to convert hashtags to lowercase
export const migrateHashtagsToLowercase = onCall(async () => {
  try {
    const db = admin.firestore();
    const videosSnapshot = await db.collection("videos").get();

    console.log(`Starting hashtag migration for ${videosSnapshot.docs.length} videos`);
    const results: Record<
      string,
      {
        success: boolean;
        error?: string;
        hashtagsChanged?: boolean;
      }
    > = {};

    for (const videoDoc of videosSnapshot.docs) {
      try {
        const videoData = videoDoc.data();
        if (videoData.hashtags && Array.isArray(videoData.hashtags)) {
          const originalHashtags = videoData.hashtags;
          const lowercaseHashtags = originalHashtags.map((tag) => tag.toLowerCase());

          // Check if any hashtags would actually change
          const needsUpdate = originalHashtags.some(
            (tag, index) => tag !== lowercaseHashtags[index],
          );

          if (needsUpdate) {
            await videoDoc.ref.update({
              hashtags: lowercaseHashtags,
            });
            results[videoDoc.id] = {
              success: true,
              hashtagsChanged: true,
            };
            console.log(`Updated video ${videoDoc.id} with lowercase hashtags`);
          } else {
            results[videoDoc.id] = {
              success: true,
              hashtagsChanged: false,
            };
            console.log(`Video ${videoDoc.id} hashtags already lowercase`);
          }
        } else {
          results[videoDoc.id] = {
            success: true,
            hashtagsChanged: false,
          };
        }
      } catch (error) {
        console.error(`Error updating video ${videoDoc.id}:`, error);
        results[videoDoc.id] = {
          success: false,
          error: error instanceof Error ? error.message : String(error),
        };
      }
    }

    return {
      success: true,
      results,
      totalProcessed: videosSnapshot.docs.length,
      totalUpdated: Object.values(results).filter((r) => r.hashtagsChanged).length,
      totalErrors: Object.values(results).filter((r) => !r.success).length,
    };
  } catch (error) {
    console.error("Error in migrateHashtagsToLowercase:", error);
    throw new functions.https.HttpsError("internal", "Failed to migrate hashtags to lowercase");
  }
});

export { migrateDisplayNamesToLowercase } from "./migrations/migrateDisplayNamesToLowercase";
