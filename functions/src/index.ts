/**
 * Import function triggers from their respective submodules:
 *
 * import {onCall} from "firebase-functions/v2/https";
 * import {onDocumentWritten} from "firebase-functions/v2/firestore";
 *
 * See a full list of supported triggers at https://firebase.google.com/docs/functions
 */

import * as functions from "firebase-functions";
import * as admin from "firebase-admin";
import {
  onDocumentCreated,
  onDocumentDeleted,
  onDocumentUpdated,
} from "firebase-functions/v2/firestore";
import { CallableRequest, onCall } from "firebase-functions/v2/https";

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
      }

      // Get video data to find the video owner
      const videoDoc = await db.collection("videos").doc(videoId).get();
      const videoData = videoDoc.data();

      if (videoData && videoData.userId !== commentData.userId) {
        // Create notification for video owner
        const notificationRef = db.collection("notifications").doc();
        batch.set(notificationRef, {
          userId: videoData.userId,
          type: "comment",
          sourceUserId: commentData.userId,
          videoId,
          commentId: event.params.commentId,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
          read: false,
        });
      }

      // If this is a reply and the parent comment is from a different user,
      // create notification for parent comment owner
      if (commentData.replyToId) {
        const parentCommentDoc = await db
          .collection("videos")
          .doc(videoId)
          .collection("comments")
          .doc(commentData.replyToId)
          .get();
        const parentCommentData = parentCommentDoc.data();

        if (
          parentCommentData &&
          parentCommentData.userId !== commentData.userId
        ) {
          const notificationRef = db.collection("notifications").doc();
          batch.set(notificationRef, {
            userId: parentCommentData.userId,
            type: "reply",
            sourceUserId: commentData.userId,
            videoId,
            commentId: event.params.commentId,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
            read: false,
          });
        }
      }

      // Create notifications for mentioned users
      if (commentData.mentions && commentData.mentions.length > 0) {
        for (const mentionedUserId of commentData.mentions) {
          if (mentionedUserId !== commentData.userId) {
            const notificationRef = db.collection("notifications").doc();
            batch.set(notificationRef, {
              userId: mentionedUserId,
              type: "mention",
              sourceUserId: commentData.userId,
              videoId,
              commentId: event.params.commentId,
              createdAt: admin.firestore.FieldValue.serverTimestamp(),
              read: false,
            });
          }
        }
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
      // Use uploaderId from either field
      const uploaderId = afterData?.userId || afterData?.uploaderId;

      if (!uploaderId) {
        console.error("No uploaderId found for video", event.params.videoId);
        return;
      }

      // Calculate the difference in likes
      const likeDiff = (afterData?.likesCount || 0) - (beforeData?.likesCount || 0);
      console.log(`Updating user ${uploaderId} totalLikes by ${likeDiff}`);

      // Update user's totalLikes using a transaction for consistency
      const userRef = db.collection("users").doc(uploaderId);
      await db.runTransaction(async (transaction) => {
        const userDoc = await transaction.get(userRef);
        if (!userDoc.exists) {
          console.error(`User document ${uploaderId} not found`);
          return;
        }

        const currentTotalLikes = userDoc.data()?.totalLikes || 0;
        const newTotalLikes = Math.max(0, currentTotalLikes + likeDiff);

        transaction.update(userRef, { totalLikes: newTotalLikes });
        console.log(`Successfully updated user ${uploaderId} totalLikes to ${newTotalLikes}`);
      });
    } catch (error) {
      console.error("Error in onVideoLikeCountChange:", error);
    }
  },
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
