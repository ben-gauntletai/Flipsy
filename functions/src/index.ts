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
