import { Pinecone } from "@pinecone-database/pinecone";
import * as functions from "firebase-functions/v2";
import { VideoMetadata, SearchResultData, VideoVector, SearchResult } from "../types";

export class PineconeService {
  private pinecone: Pinecone;
  private readonly SIMILARITY_THRESHOLD = 0.3;
  private readonly INDEX_NAME = "flipsy-videos";

  constructor(apiKey: string) {
    try {
      if (!apiKey) {
        throw new Error("Pinecone API key is required");
      }
      
      this.pinecone = new Pinecone({
        apiKey,
      });
      
      functions.logger.info("Pinecone service initialized successfully");
    } catch (error) {
      functions.logger.error("Failed to initialize Pinecone service", error);
      throw error;
    }
  }

  private formatError(error: unknown): Record<string, unknown> {
    if (error instanceof Error) {
      return {
        name: error.name,
        message: error.message,
        stack: error.stack,
      };
    }
    return { error: String(error) };
  }

  async upsertVector(vector: VideoVector): Promise<void> {
    try {
      const index = this.pinecone.index(this.INDEX_NAME);
      await index.upsert([
        {
          id: vector.id,
          values: vector.values,
          metadata: vector.metadata,
        },
      ]);
      functions.logger.info(`Successfully upserted vector ${vector.id}`);
    } catch (error) {
      const errorDetails = this.formatError(error);
      functions.logger.error("Error upserting vector:", errorDetails);
      throw error;
    }
  }

  async upsert(vectors: VideoVector[]): Promise<void> {
    try {
      const index = this.pinecone.index(this.INDEX_NAME);
      await index.upsert(vectors.map((vector) => ({
        id: vector.id,
        values: vector.values,
        metadata: vector.metadata,
      })));
      functions.logger.info(`Successfully upserted ${vectors.length} vectors`);
    } catch (error) {
      const errorDetails = this.formatError(error);
      functions.logger.error("Error upserting vectors:", errorDetails);
      throw error;
    }
  }

  async deleteVector(videoId: string): Promise<void> {
    try {
      const index = this.pinecone.index(this.INDEX_NAME);
      await index.deleteOne(videoId);
      functions.logger.info(`Successfully deleted vector ${videoId}`);
    } catch (error) {
      const errorDetails = this.formatError(error);
      functions.logger.error("Error deleting vector:", errorDetails);
      throw error;
    }
  }

  async hybridSearch({
    queryVector,
    limit = 20,
  }: {
    query?: string;
    queryVector: number[];
    limit?: number;
  }): Promise<SearchResultData> {
    try {
      const index = this.pinecone.index(this.INDEX_NAME);
      const queryResponse = await index.query({
        vector: queryVector,
        topK: limit,
        includeMetadata: true,
      });

      const filteredMatches = queryResponse.matches.filter(
        (match) => (match.score || 0) >= this.SIMILARITY_THRESHOLD,
      );

      const results: SearchResult[] = filteredMatches.map((match) => ({
        id: match.id,
        score: match.score || 0,
        metadata: match.metadata as VideoMetadata,
        type: "semantic",
      }));

      return { results };
    } catch (error) {
      const errorDetails = this.formatError(error);
      functions.logger.error("Error performing hybrid search:", errorDetails);
      throw error;
    }
  }
}
