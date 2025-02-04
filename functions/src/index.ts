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
import { onDocumentCreated, onDocumentDeleted, onDocumentWritten } from "firebase-functions/v2/firestore";

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
export const onCommentCreated = onDocumentCreated("videos/{videoId}/comments/{commentId}", async (event) => {
  const commentData = event.data?.data();
  const { videoId } = event.params;

  if (!commentData) return;

  try {
    const db = admin.firestore();
    const batch = db.batch();

    // Increment the video's comment count
    const videoRef = db.collection("videos").doc(videoId);
    batch.update(videoRef, {
      commentsCount: admin.firestore.FieldValue.increment(1),
    });

    // If this is a reply, increment the parent comment's reply count
    if (commentData.replyToId) {
      const parentCommentRef = db
        .collection("videos")
        .doc(videoId)
        .collection("comments")
        .doc(commentData.replyToId);
      batch.update(parentCommentRef, {
        replyCount: admin.firestore.FieldValue.increment(1),
      });
    }

    // Get video data to find the video owner
    const videoDoc = await videoRef.get();
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
  } catch (error) {
    console.error("Error in onCommentCreated:", error);
  }
});

// Function to handle comment deletion
export const onCommentDeleted = onDocumentDeleted("videos/{videoId}/comments/{commentId}", async (event) => {
  const commentData = event.data?.data();
  const { videoId } = event.params;

  if (!commentData) {
    console.log("No comment data found for deletion event");
    return;
  }

  try {
    console.log(`Processing comment deletion for video ${videoId}, comment ${event.params.commentId}`);
    const db = admin.firestore();
    const batch = db.batch();

    // Decrement the video's comment count
    const videoRef = db.collection("videos").doc(videoId);
    batch.update(videoRef, {
      commentsCount: admin.firestore.FieldValue.increment(-1),
    });

    // If this was a reply, decrement the parent comment's reply count
    if (commentData.replyToId) {
      console.log(`Comment was a reply to ${commentData.replyToId}, updating parent comment`);
      const parentCommentRef = db
        .collection("videos")
        .doc(videoId)
        .collection("comments")
        .doc(commentData.replyToId);

      // Check if parent comment exists before updating
      const parentCommentDoc = await parentCommentRef.get();
      if (parentCommentDoc.exists) {
        batch.update(parentCommentRef, {
          replyCount: admin.firestore.FieldValue.increment(-1),
        });
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
});

// Function to handle comment like changes
export const onCommentLikeChange = onDocumentWritten(
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
