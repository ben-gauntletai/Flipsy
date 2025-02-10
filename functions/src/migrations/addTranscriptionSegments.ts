import * as admin from "firebase-admin";
import * as functions from "firebase-functions/v2";

export async function addTranscriptionSegments() {
  const db = admin.firestore();
  const videosRef = db.collection("videos");
  const batch = db.batch();
  let count = 0;

  try {
    // Get all videos that have analysis but no transcription segments
    const snapshot = await videosRef
      .where("analysis", "!=", null)
      .get();

    functions.logger.info(`Found ${snapshot.docs.length} videos to update`);

    for (const doc of snapshot.docs) {
      const videoData = doc.data();
      
      // Skip if video already has transcription segments
      if (videoData.analysis?.transcriptionSegments) {
        continue;
      }

      // Add empty transcription segments array if missing
      batch.update(doc.ref, {
        "analysis.transcriptionSegments": []
      });

      count++;

      // Commit batch when it reaches 500 operations
      if (count % 500 === 0) {
        await batch.commit();
        functions.logger.info(`Committed batch of ${count} updates`);
      }
    }

    // Commit any remaining updates
    if (count % 500 !== 0) {
      await batch.commit();
    }

    functions.logger.info(`Successfully updated ${count} videos`);
    return { success: true, updatedCount: count };
  } catch (error) {
    functions.logger.error("Error in addTranscriptionSegments migration:", error);
    throw error;
  }
} 