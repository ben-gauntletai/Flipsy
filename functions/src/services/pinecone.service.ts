import { Pinecone } from "@pinecone-database/pinecone";
import * as functions from "firebase-functions";
import { getFirestore } from "firebase-admin/firestore";
import { VideoMetadata, SearchResultData, VideoVector } from "../types";

// Get Firestore instance
const getDb = () => {
  return getFirestore();
};

// Status and error tracking interfaces
interface ProcessingMetrics {
  retryCount: number;
}

interface ProcessingError {
  message: string;
  code: string;
  timestamp: Date;
  stack?: string;
}

interface HybridSearchOptions {
  query: string;
  queryVector?: number[];
  filter?: {
    status?: string;
    privacy?: string;
    userId?: string;
    tags?: string[];
  };
  limit?: number;
}

interface QueryOptions {
  vector: number[];
  topK: number;
  includeMetadata: boolean;
  filter?: {
    status?: string;
    privacy?: string;
    userId?: string;
    tags?: string[];
  };
}

interface QueryResponse {
  id: string;
  score: number;
  metadata: VideoVector["metadata"];
}

interface VectorEmbeddingUpdate {
  status: "pending" | "completed" | "failed";
  updatedAt: Date;
  retryCount?: number;
  error?: {
    message: string;
    code: string;
    timestamp: Date;
  };
  lastErrorAt?: Date;
}

interface SearchResponse {
  query: string;
  results: SearchResultData[];
}

type PineconeMetadata = {
  [key: string]: string | number | boolean | string[];
} & {
  userId: string;
  status: string;
  privacy: string;
  tags: string[];
  aiDescription: string;
  version: number;
  contentLength: number;
  hasDescription: string;
  hasAiDescription: string;
  hasTags: string;
  updatedAt?: string;
}

/**
 * Service class for interacting with Pinecone vector database
 */
export class PineconeService {
  private index;
  private db;
  private readonly maxRetries = 3;
  private readonly cooldownPeriodMs = 60000; // 1 minute cooldown

  /**
   * Initialize Pinecone service with API credentials.
   * @param {string} apiKey Pinecone API key
   * @return {void}
   */
  constructor(apiKey: string) {
    try {
      const pinecone = new Pinecone({
        apiKey,
      });
      this.index = pinecone.index("flipsy-videos");
      this.db = getDb();
      functions.logger.info("Pinecone service initialized successfully");
    } catch (error) {
      const errorDetails = this.formatError(error);
      functions.logger.error("Failed to initialize Pinecone service", errorDetails);
      throw error;
    }
  }

  /**
   * Format error details into a standardized structure.
   * @param {unknown} error The error to format
   * @return {ProcessingError} Formatted error object
   * @private
   */
  private formatError(error: unknown): ProcessingError {
    return {
      message: error instanceof Error ? error.message : String(error),
      code: error instanceof Error ? error.name : "UnknownError",
      timestamp: new Date(),
      stack: error instanceof Error ? error.stack : undefined,
    };
  }

  /**
   * Retries a Pinecone operation with exponential backoff.
   * @template T
   * @param {function(): Promise<T>} operation Operation to retry
   * @param {ProcessingMetrics} metrics Optional metrics for tracking retry attempts
   * @param {number} maxRetries Optional maximum number of retry attempts
   * @return {Promise<T>} Operation result
   */
  private async retryOperation<T>(
    operation: () => Promise<T>,
    metrics: ProcessingMetrics = { retryCount: 0 },
    maxRetries = this.maxRetries
  ): Promise<T> {
    try {
      return await operation();
    } catch (error) {
      metrics.retryCount++;

      if (metrics.retryCount >= maxRetries) {
        const errorDetails = this.formatError(error);
        functions.logger.error("Max retries reached", {
          ...errorDetails,
          metrics,
        });
        throw error;
      }

      const delay = Math.min(Math.pow(2, metrics.retryCount) * 1000, this.cooldownPeriodMs);

      functions.logger.info("Retrying operation", {
        attempt: metrics.retryCount + 1,
        maxRetries,
        delayMs: delay,
        metrics,
      });

      await new Promise((resolve) => setTimeout(resolve, delay));
      return this.retryOperation(operation, metrics, maxRetries);
    }
  }

  /**
   * Validate vector data before upserting.
   * @param {VideoVector} vector The vector to validate
   * @return {void}
   * @throws {Error} If validation fails
   * @private
   */
  private validateVector(vector: VideoVector): void {
    if (!vector.id) throw new Error("Vector ID is required");
    if (!vector.values || !vector.values.length) throw new Error("Vector values are required");
    if (!vector.metadata) throw new Error("Vector metadata is required");
    if (!vector.metadata.userId) throw new Error("User ID is required in metadata");
    if (!vector.metadata.status) throw new Error("Status is required in metadata");
    if (!vector.metadata.privacy) throw new Error("Privacy setting is required in metadata");
  }

  /**
   * Update vector status in Firestore.
   * @param {string} videoId The ID of the video to update
   * @param {"pending" | "completed" | "failed"} status The new status
   * @param {ProcessingMetrics} [metrics] Optional processing metrics
   * @param {ProcessingError} [error] Optional error details
   * @return {Promise<void>}
   * @private
   */
  private async updateVectorStatus(
    videoId: string,
    status: "pending" | "completed" | "failed",
    metrics?: ProcessingMetrics,
    error?: ProcessingError,
  ): Promise<void> {
    const update: VectorEmbeddingUpdate = {
      status,
      updatedAt: new Date(),
      retryCount: metrics?.retryCount,
    };

    if (error) {
      update.error = {
        message: error.message,
        code: error.code,
        timestamp: error.timestamp,
      };
      update.lastErrorAt = error.timestamp;
    }

    try {
      await this.db.collection("videos").doc(videoId).update({
        vectorEmbedding: update,
      });
    } catch (err) {
      functions.logger.error("Error updating vector status", {
        videoId,
        status,
        error: err,
      });
    }
  }

  /**
   * Maps video metadata to Pinecone metadata format
   * Upsert a vector into Pinecone.
   * @param {VideoVector} vector The vector to upsert
   * @return {Promise<void>}
   */
  async upsertVector(vector: VideoVector): Promise<void> {
    try {
      this.validateVector(vector);

      const metrics: ProcessingMetrics = { retryCount: 0 };
      await this.updateVectorStatus(vector.id, "pending", metrics);

      await this.retryOperation(
        async () => {
          await this.index.upsert([
            {
              id: vector.id,
              values: vector.values,
              metadata: this.mapToPineconeMetadata(vector.metadata),
            },
          ]);
        },
        metrics,
      );

      await this.updateVectorStatus(vector.id, "completed", metrics);
      functions.logger.info("Vector upserted successfully", { vectorId: vector.id });
    } catch (error) {
      const errorDetails = this.formatError(error);
      await this.updateVectorStatus(vector.id, "failed", undefined, errorDetails);
      throw error;
    }
  }

  /**
   * Delete a vector from Pinecone.
   * @param {string} vectorId The ID of the vector to delete
   * @return {Promise<void>}
   */
  async deleteVector(vectorId: string): Promise<void> {
    try {
      await this.retryOperation(async () => {
        await this.index.deleteOne(vectorId);
      });
      functions.logger.info("Vector deleted successfully", { vectorId });
    } catch (error) {
      functions.logger.error("Error deleting vector", {
        vectorId,
        error: this.formatError(error),
      });
      throw error;
    }
  }

  /**
   * Queries the Pinecone index for similar vectors
   * @param {QueryOptions} options - Query options including vector, filters, and limits
   * @param {number[]} options.vector - The vector to query against
   * @param {number} [options.topK] - Maximum number of results to return
   * @param {boolean} [options.includeMetadata] - Whether to include metadata in results
   * @param {object} [options.filter] - Filter criteria for the query
   * @return {Promise<QueryResponse[]>} Query results containing matches and their scores
   */
  async query(options: QueryOptions): Promise<QueryResponse[]> {
    try {
      functions.logger.info("Querying similar vectors", { filter: options.filter });
      const queryResponse = await this.index.query({
        vector: options.vector,
        topK: options.topK || 10,
        includeMetadata: options.includeMetadata ?? true,
        filter: options.filter,
      });

      functions.logger.info("Query response:", {
        totalMatches: queryResponse.matches.length,
        scores: queryResponse.matches.map((m) => m.score),
      });

      // Filter matches by score threshold
      const SIMILARITY_THRESHOLD = 0.3;
      const filteredMatches = queryResponse.matches.filter((match) => (match.score || 0) >= SIMILARITY_THRESHOLD);

      functions.logger.info("After threshold filtering:", {
        originalCount: queryResponse.matches.length,
        filteredCount: filteredMatches.length,
        threshold: SIMILARITY_THRESHOLD,
      });

      return filteredMatches.map((match) => ({
        id: match.id,
        score: match.score || 0,
        metadata: this.mapFromPineconeMetadata(match.metadata || {}),
      }));
    } catch (error) {
      functions.logger.error("Error querying vectors", error);
      throw error;
    }
  }

  /**
   * Maps raw metadata from Pinecone to our strongly typed structure
   * @param {any} raw Raw metadata from Pinecone
   * @return {VideoMetadata} Properly typed metadata
   * @private
   */
  private mapFromPineconeMetadata(raw: Record<string, unknown>): VideoMetadata {
    return {
      userId: String(raw?.userId ?? ""),
      status: String(raw?.status ?? ""),
      privacy: String(raw?.privacy ?? ""),
      tags: Array.isArray(raw?.tags) ? raw.tags.map(String) : [],
      aiDescription: String(raw?.aiDescription ?? ""),
      version: Number(raw?.version ?? 1),
      contentLength: Number(raw?.contentLength ?? 0),
      hasDescription: String(raw?.hasDescription ?? "false"),
      hasAiDescription: String(raw?.hasAiDescription ?? "false"),
      hasTags: String(raw?.hasTags ?? "false"),
      updatedAt: raw?.updatedAt ? String(raw.updatedAt) : undefined,
    };
  }

  /**
   * Creates a search result from a Pinecone match
   * @param {any} match Pinecone match result
   * @param {"semantic" | "exact"} type Type of match
   * @param {number} [score] Optional override score
   * @return {SearchResultData} Formatted search result
   * @private
   */
  private createSearchResult(
    match: {
      id: string;
      score?: number;
      metadata?: Record<string, unknown>;
    },
    type: "semantic" | "exact",
    score?: number,
  ): SearchResultData {
    const metadata = this.mapFromPineconeMetadata(match.metadata || {});
    return {
      id: String(match.id),
      score: score ?? (typeof match.score === "number" ? match.score : 0),
      data: {
        ...metadata,
        id: String(match.id),
      },
      type,
    };
  }

  /**
   * Perform a hybrid search using both semantic and exact matching.
   * @param {HybridSearchOptions} options Search options
   * @return {Promise<SearchResponse>} Search results
   */
  async hybridSearch(options: HybridSearchOptions): Promise<SearchResponse> {
    try {
      const { query, queryVector, filter, limit = 20 } = options;
      const SIMILARITY_THRESHOLD = 0.3;

      // Prepare query options with required topK
      const queryOptions: QueryOptions = {
        vector: queryVector || [],
        topK: limit * 2, // Request more results since we'll filter some out
        includeMetadata: true,
        filter: {
          ...filter,
          status: filter?.status || "active",
        },
      };

      // Perform semantic search
      const semanticResults = await this.index.query(queryOptions);
      
      // Log raw scores for debugging
      functions.logger.info("Semantic search raw scores:", 
        semanticResults.matches.map((m) => m.score));

      // Filter by threshold before any processing
      let results: SearchResultData[] = semanticResults.matches
        .filter((match) => (match.score || 0) >= SIMILARITY_THRESHOLD)
        .map((match) => this.createSearchResult(match, "semantic"));

      // If exact matching is needed, perform exact match search
      if (query && query.trim()) {
        const exactResults = await this.index.query({
          ...queryOptions,
          filter: {
            ...queryOptions.filter,
            $or: [
              { description: { $eq: query } },
              { hashtags: { $in: [query] } },
              { tags: { $in: [query] } },
            ],
          },
        });

        // Add exact matches (they automatically pass threshold)
        const exactMatches = exactResults.matches.map((match) => 
          this.createSearchResult(match, "exact", 1.0)
        );

        results = this.deduplicateResults([...exactMatches, ...results], limit);
      }

      // Add detailed logging for debugging
      functions.logger.info("Search results:", {
        query,
        totalMatches: semanticResults.matches.length,
        matchesAboveThreshold: results.length,
        thresholdUsed: SIMILARITY_THRESHOLD,
        topScores: results.slice(0, 3).map((r) => ({
          id: r.id,
          score: r.score,
          type: r.type,
        })),
      });

      return {
        query: String(query),
        results,
      };
    } catch (error) {
      const errorDetails = this.formatError(error);
      functions.logger.error("Error in hybrid search", errorDetails);
      throw error;
    }
  }

  /**
   * Process and deduplicate search results.
   * @param {SearchResultData[]} results The search results to process
   * @param {number} limit The maximum number of results to return
   * @return {SearchResultData[]} The deduplicated and sorted results
   * @private
   */
  private deduplicateResults(results: SearchResultData[], limit: number): SearchResultData[] {
    const seen = new Set<string>();
    return results
      .filter((result) => {
        if (seen.has(result.id)) return false;
        seen.add(result.id);
        return true;
      })
      .sort((a, b) => b.score - a.score)
      .slice(0, limit);
  }

  /**
   * Updates vector metadata for a video.
   * @param {string} videoId ID of the video to update
   * @param {Partial<VideoMetadata>} afterData Updated video data
   * @return {Promise<void>}
   */
  async updateVectorMetadata(
    videoId: string,
    afterData: Partial<VideoMetadata>,
  ): Promise<void> {
    try {
      functions.logger.info("Updating vector metadata", { videoId, afterData });

      // Validate that we have at least some metadata to update
      if (!afterData || Object.keys(afterData).length === 0) {
        throw new Error("No metadata provided for update");
      }

      // Update the vector metadata
      const updateResponse = await this.index.update({
        id: videoId,
        metadata: this.mapToPineconeMetadata({
          ...afterData,
          userId: afterData.userId || "",
          status: afterData.status || "",
          privacy: afterData.privacy || "",
          tags: afterData.tags || [],
          version: 1,
          contentLength: 0,
          hasDescription: "false",
          hasAiDescription: "false",
          hasTags: "false",
        } as VideoMetadata),
      });

      functions.logger.info("Vector metadata updated successfully", { videoId, updateResponse });
    } catch (error) {
      functions.logger.error("Error updating vector metadata", error);
      throw error;
    }
  }

  private mapToPineconeMetadata(metadata: VideoMetadata): PineconeMetadata {
    const result: PineconeMetadata = {
      userId: metadata.userId,
      status: metadata.status,
      privacy: metadata.privacy,
      tags: metadata.tags,
      aiDescription: metadata.aiDescription,
      version: metadata.version,
      contentLength: metadata.contentLength,
      hasDescription: metadata.hasDescription,
      hasAiDescription: metadata.hasAiDescription,
      hasTags: metadata.hasTags,
    };

    if (metadata.updatedAt) {
      result.updatedAt = metadata.updatedAt;
    }

    return result;
  }
}
