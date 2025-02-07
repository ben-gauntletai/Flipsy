import { Pinecone } from "@pinecone-database/pinecone";
import * as functions from "firebase-functions";
import { getFirestore } from "firebase-admin/firestore";

// Get Firestore instance
const getDb = () => {
  return getFirestore();
};

export interface VideoVector {
  id: string;
  values: number[];
  metadata: {
    userId: string;
    status: string;
    privacy: string;
    tags: string[];
  };
}

/**
 * Service class for interacting with Pinecone vector database
 */
export class PineconeService {
  private index;
  private db;

  /**
   * Initialize Pinecone service with API credentials
   * @param {string} apiKey - Pinecone API key
   */
  constructor(apiKey: string) {
    const pinecone = new Pinecone({
      apiKey,
    });
    this.index = pinecone.index("flipsy-videos");
    this.db = getDb();
  }

  /**
   * Upsert a video vector into Pinecone
   * @param {VideoVector} vector - Video vector data to upsert
   * @return {Promise<void>}
   */
  async upsertVector(vector: VideoVector): Promise<void> {
    try {
      functions.logger.info("Upserting vector to Pinecone", { videoId: vector.id });
      await this.index.upsert([{
        id: vector.id,
        values: vector.values,
        metadata: vector.metadata,
      }]);

      // Update Firestore with vector status
      await this.db.collection("videos").doc(vector.id).update({
        vectorEmbedding: {
          status: "completed",
          updatedAt: new Date(),
          pineconeId: vector.id,
        },
      });

      functions.logger.info("Successfully upserted vector", { videoId: vector.id });
    } catch (error) {
      functions.logger.error("Error upserting vector to Pinecone", { error, videoId: vector.id });
      // Update Firestore with failed status
      await this.db.collection("videos").doc(vector.id).update({
        vectorEmbedding: {
          status: "failed",
          updatedAt: new Date(),
          error: error instanceof Error ? error.message : "Unknown error",
        },
      });
      throw error;
    }
  }

  /**
   * Delete a video vector from Pinecone
   * @param {string} videoId - ID of the video to delete
   * @return {Promise<void>}
   */
  async deleteVector(videoId: string): Promise<void> {
    try {
      functions.logger.info("Deleting vector from Pinecone", { videoId });
      await this.index.deleteOne(videoId);
      functions.logger.info("Successfully deleted vector", { videoId });
    } catch (error) {
      functions.logger.error("Error deleting vector from Pinecone", { error, videoId });
      throw error;
    }
  }

  /**
   * Query similar videos
   * @param {number[]} queryVector - Vector to find similar videos for
   * @param {Object} [filter] - Optional filters to apply to the search
   * @param {string} [filter.status] - Filter by video status
   * @param {string} [filter.privacy] - Filter by video privacy setting
   * @param {string} [filter.userId] - Filter by user ID
   * @param {string[]} [filter.tags] - Filter by video tags
   * @param {number} [limit=10] - Maximum number of results to return
   * @return {Promise<{id: string; score: number; metadata: VideoVector["metadata"];}[]>}
   */
  async querySimilar(
    queryVector: number[],
    filter?: {
      status?: string;
      privacy?: string;
      userId?: string;
      tags?: string[];
    },
    limit = 10
  ): Promise<{ id: string; score: number; metadata: VideoVector["metadata"] }[]> {
    try {
      functions.logger.info("Querying similar vectors", { filter });
      const queryResponse = await this.index.query({
        vector: queryVector,
        filter: filter ? {
          status: filter.status,
          privacy: filter.privacy,
          userId: filter.userId,
          ...(filter.tags && { tags: { $in: filter.tags } }),
        } : undefined,
        includeMetadata: true,
        topK: limit,
      });

      return queryResponse.matches
        .map((match) => ({
          id: match.id,
          score: match.score || 0,
          metadata: match.metadata as VideoVector["metadata"],
        }))
        .filter((match): match is { id: string; score: number; metadata: VideoVector["metadata"] } =>
          match.metadata !== undefined
        );
    } catch (error) {
      functions.logger.error("Error querying similar vectors", { error });
      throw error;
    }
  }
}
