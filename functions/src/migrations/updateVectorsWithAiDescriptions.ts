import { onRequest } from "firebase-functions/v2/https";
import { getFirestore } from "firebase-admin/firestore";
import { PineconeService } from "../services/pinecone.service";
import { OpenAIService } from "../services/openai.service";
import { Request, Response } from "express";

const db = getFirestore();

export const updateVectorsWithAiDescriptions = onRequest(
  {
    timeoutSeconds: 540, // 9 minutes
    memory: "1GiB",
  },
  async (req: Request, res: Response) => {
    try {
      console.info("Starting vector update migration for AI descriptions");

      // Initialize services
      const pineconeService = new PineconeService(process.env.PINECONE_API_KEY || "");
      const openaiService = new OpenAIService();

      // Get all active videos that have vector embeddings and AI descriptions
      const videosSnapshot = await db
        .collection("videos")
        .where("status", "==", "active")
        .where("vectorEmbedding.status", "==", "completed")
        .where("aiEnhancements.description", "!=", null)
        .get();

      console.info(`Found ${videosSnapshot.size} videos to update`);

      let successCount = 0;
      let errorCount = 0;

      // Process each video
      for (const doc of videosSnapshot.docs) {
        const videoData = doc.data();
        const videoId = doc.id;

        try {
          console.info(`Processing video ${videoId}`);

          // Generate content string including AI description
          const content = [
            videoData.description || "",
            videoData.hashtags?.join(" ") || "",
            videoData.tags?.join(" ") || "",
            videoData.aiEnhancements?.description || "",
          ].join(" ");

          // Generate new embedding
          const embedding = await openaiService.generateEmbedding(content);

          // Update vector in Pinecone
          await pineconeService.upsertVector({
            id: videoId,
            values: embedding,
            metadata: {
              userId: videoData.userId,
              status: videoData.status,
              privacy: videoData.privacy,
              tags: videoData.tags || [],
              aiDescription: videoData.aiEnhancements?.description,
              version: 1,
              contentLength: content.length,
              hasDescription: String(!!videoData.description),
              hasAiDescription: String(!!videoData.aiEnhancements?.description),
              hasTags: String(videoData.tags?.length > 0),
            },
          });

          // Update Firestore to mark AI description as included
          await doc.ref.update({
            "vectorEmbedding.aiDescriptionIncluded": true,
            "vectorEmbedding.updatedAt": new Date(),
          });

          successCount++;
          console.info(`Successfully updated vector for video ${videoId}`);
        } catch (error) {
          errorCount++;
          console.error(`Error updating vector for video ${videoId}:`, error);
        }
      }

      const summary = {
        totalProcessed: videosSnapshot.size,
        successCount,
        errorCount,
      };

      console.info("Migration completed", summary);
      res.json(summary);
    } catch (error) {
      console.error("Migration failed:", error);
      res.status(500).json({ error: "Migration failed" });
    }
  },
);
