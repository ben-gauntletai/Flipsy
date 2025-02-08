import { Pinecone } from "@pinecone-database/pinecone";
import * as functions from "firebase-functions";
import { getFirestore } from "firebase-admin/firestore";

// Get Firestore instance
const getDb = () => {
  return getFirestore();
};

export interface VideoVector {
  id: string; // This is the Firestore video document ID
  values: number[];
  metadata: {
    userId: string;
    status: string; // video status ('active', 'deleted', etc)
    privacy: string;
    tags: string[];
    aiDescription?: string; // Include AI description in metadata for potential filtering
    version: number; // Embedding model version
    contentLength: number; // Length of content used for embedding
    hasDescription?: string; // Content quality metrics as flat string values
    hasAiDescription?: string;
    hasTags?: string;
  };
}

// Status and error tracking interfaces
interface ProcessingMetrics {
  retryCount: number;
}

interface ContentQualityMetrics {
  contentLength: number;
  hasDescription: boolean;
  hasAiDescription: boolean;
  hasTags: boolean;
}

interface ProcessingError {
  message: string;
  code: string;
  timestamp: Date;
  stack?: string;
}

interface SearchResult {
  id: string;
  score: number;
  metadata: VideoVector["metadata"];
  type: "semantic" | "exact";
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
  topK?: number;
  includeMetadata?: boolean;
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

interface VideoMetadata {
  userId: string;
  status: string;
  privacy: string;
  tags: string[];
  aiDescription?: string;
  version: number;
  contentLength: number;
  hasDescription?: string;
  hasAiDescription?: string;
  hasTags?: string;
  description?: string;
  hashtags?: string[];
  aiEnhancements?: string; // Store as stringified JSON
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

/**
 * Service class for interacting with Pinecone vector database
 */
export class PineconeService {
  private index;
  private db;
  private readonly maxRetries = 3;
  private readonly cooldownPeriodMs = 60000; // 1 minute cooldown
  private readonly embeddingVersion = 1;
  private readonly minContentLength = 50; // Minimum content length for meaningful embeddings

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
   * Validates content quality metrics.
   * @param {string} content The content string to validate
   * @param {VideoVector["metadata"]} metadata The metadata object containing tags and AI description
   * @return {ContentQualityMetrics} The calculated content quality metrics
   * @throws {Error} When content length is below minimum required
   * @private
   */
  private validateContent(
    content: string,
    metadata: VideoVector["metadata"],
  ): ContentQualityMetrics {
    const metrics: ContentQualityMetrics = {
      contentLength: content.length,
      hasDescription: content.length > 0,
      hasAiDescription: !!metadata.aiDescription,
      hasTags: metadata.tags.length > 0,
    };

    if (content.length < this.minContentLength) {
      throw new Error(
        `Content length (${content.length}) below minimum required (${this.minContentLength})`,
      );
    }

    return metrics;
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
    };

    if (metrics) {
      update.retryCount = metrics.retryCount;
    }

    if (error) {
      update.error = {
        message: error.message,
        code: error.code,
        timestamp: error.timestamp,
      };
      update.lastErrorAt = error.timestamp;
    }

    await this.db.collection("videos").doc(videoId).update({
      vectorEmbedding: update,
    });
  }

  /**
   * Upserts a vector to the Pinecone index
   * @param {VideoVector} vector - The vector to upsert, containing ID, values, and metadata
   * @return {Promise<void>}
   */
  async upsertVector(vector: VideoVector): Promise<void> {
    const metrics: ProcessingMetrics = {
      retryCount: 0,
    };

    try {
      functions.logger.info("Starting vector upsert", {
        videoId: vector.id,
        version: this.embeddingVersion,
      });

      // Validate vector data
      this.validateVector(vector);

      // Validate content quality
      const contentQualityMetrics = this.validateContent(
        [vector.metadata.aiDescription || "", ...vector.metadata.tags].join(" "),
        vector.metadata,
      );

      functions.logger.info("Content validation passed", {
        videoId: vector.id,
        qualityMetrics: contentQualityMetrics,
      });

      // Update status to pending
      await this.updateVectorStatus(vector.id, "pending", metrics);

      // Add version and timestamp to metadata
      const enrichedVector = {
        ...vector,
        metadata: {
          ...vector.metadata,
          version: this.embeddingVersion,
          contentLength: contentQualityMetrics.contentLength,
          updatedAt: new Date().toISOString(),
          hasDescription: String(contentQualityMetrics.hasDescription),
          hasAiDescription: String(contentQualityMetrics.hasAiDescription),
          hasTags: String(contentQualityMetrics.hasTags),
        },
      };

      // Attempt upsert with retry logic
      await this.retryOperation(async () => {
        await this.index.upsert([
          {
            id: enrichedVector.id,
            values: enrichedVector.values,
            metadata: enrichedVector.metadata,
          },
        ]);
      }, metrics);

      // Update status to completed
      await this.updateVectorStatus(vector.id, "completed", metrics);

      functions.logger.info("Vector upsert completed successfully", {
        videoId: vector.id,
        metrics,
        qualityMetrics: contentQualityMetrics,
      });
    } catch (error) {
      const errorDetails = this.formatError(error);
      functions.logger.error("Error upserting vector", {
        error: errorDetails,
        videoId: vector.id,
        metrics,
      });

      // Update status to failed
      await this.updateVectorStatus(vector.id, "failed", metrics, errorDetails);

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
      return queryResponse.matches.map((match) => ({
        id: match.id,
        score: match.score || 0,
        metadata: match.metadata as VideoVector["metadata"],
      }));
    } catch (error) {
      functions.logger.error("Error querying vectors", error);
      throw error;
    }
  }

  /**
   * Perform a hybrid search combining semantic and exact matches
   * @param {HybridSearchOptions} options Search options containing query and filters
   * @return {Promise<SearchResult[]>} Array of search results
   */
  async hybridSearch(options: HybridSearchOptions): Promise<SearchResult[]> {
    const { query, queryVector, filter = {}, limit = 20 } = options;

    try {
      functions.logger.info("Starting hybrid search", {
        query,
        hasVector: !!queryVector,
        filter,
      });

      // Always include active status and public privacy in filter
      const baseFilter = {
        status: "active",
        privacy: "everyone",
        ...filter,
      };

      let results: SearchResult[] = [];

      // If we have a query vector, perform semantic search
      if (queryVector) {
        const semanticResults = await this.index.query({
          vector: queryVector,
          filter: baseFilter,
          includeMetadata: true,
          topK: limit,
        });

        results = semanticResults.matches.map((match) => ({
          id: match.id,
          score: match.score || 0,
          metadata: match.metadata as VideoVector["metadata"],
          type: "semantic" as const,
        }));

        functions.logger.info("Semantic search completed", {
          resultsCount: results.length,
          topScore: results[0]?.score,
        });
      }

      // Perform metadata filtering for exact matches
      if (query) {
        // Convert query to lowercase for case-insensitive matching
        const lowercaseQuery = query.toLowerCase();

        // Add metadata filters for exact matches
        const exactResults = await this.index.query({
          vector: Array(1536).fill(0), // Required by Pinecone, using zero vector
          filter: {
            ...baseFilter,
            $or: [
              { tags: { $in: [lowercaseQuery] } },
              { aiDescription: { $contains: lowercaseQuery } },
            ],
          },
          includeMetadata: true,
          topK: limit,
        });

        // Add exact matches to results
        const exactMatches = exactResults.matches.map((match) => ({
          id: match.id,
          score: 1.0, // Give exact matches a high score
          metadata: match.metadata as VideoVector["metadata"],
          type: "exact" as const,
        }));

        // Combine and deduplicate results
        results = this.deduplicateResults([...exactMatches, ...results], limit);

        functions.logger.info("Hybrid search completed", {
          totalResults: results.length,
          exactMatches: exactMatches.length,
          semanticMatches: results.filter((r) => r.type === "semantic").length,
        });
      }

      return results;
    } catch (error) {
      const errorDetails = this.formatError(error);
      functions.logger.error("Error in hybrid search", errorDetails);
      throw error;
    }
  }

  /**
   * Process and deduplicate search results.
   * Filters out duplicates based on ID and sorts by score.
   * @param {Array<SearchResult>} results The search results to process
   * @param {number} limit The maximum number of results to return
   * @return {Array<SearchResult>} The deduplicated and sorted results
   * @private
   */
  private deduplicateResults(results: SearchResult[], limit: number): SearchResult[] {
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
        metadata: {
          ...afterData,
          hasTags: String(!!(afterData.tags && afterData.tags.length > 0)),
          aiEnhancements: afterData.aiEnhancements ? String(afterData.aiEnhancements) : undefined,
        },
      });

      functions.logger.info("Vector metadata updated successfully", { videoId, updateResponse });
    } catch (error) {
      functions.logger.error("Error updating vector metadata", error);
      throw error;
    }
  }
}
