import * as admin from "firebase-admin";
import * as functions from "firebase-functions";

export const migrateDisplayNamesToLowercase = functions.https.onRequest(async (req, res) => {
  try {
    const db = admin.firestore();
    const usersSnapshot = await db.collection("users").get();

    console.log(`Starting migration for ${usersSnapshot.docs.length} users`);
    const results: Record<string, { success: boolean; error?: string }> = {};

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

    res.json({ success: true, results });
  } catch (error) {
    console.error("Error in migrateDisplayNamesToLowercase:", error);
    res.status(500).json({
      success: false,
      error: error instanceof Error ? error.message : String(error),
    });
  }
});
