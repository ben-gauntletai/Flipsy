import { Pinecone } from "@pinecone-database/pinecone";
import * as functions from "firebase-functions/v2";
import { VideoMetadata, SearchResultData, VideoVector, SearchResult } from "../types";

export class PineconeService {
  private pinecone: Pinecone;
  private readonly SIMILARITY_THRESHOLD = 0.3;
  private readonly INDEX_NAME = "flipsy-videos";
  private readonly WEIGHTS = {
    summary: 1.2,  // Give slightly higher weight to summary matches
    transcription: 1.0
  };

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
    // Initial validation of vectors
    functions.logger.info("Validating vectors before Pinecone upsert:", {
      vectorCount: vectors.length,
      vectors: vectors.map(v => ({
        id: v.id,
        hasValues: !!v.values,
        valuesLength: v.values?.length,
        embeddingStats: v.values ? {
          isArray: Array.isArray(v.values),
          hasNulls: v.values.some(val => val === null),
          firstFewValues: v.values.slice(0, 5),
          valueStats: {
            min: Math.min(...v.values),
            max: Math.max(...v.values),
            hasInfinity: v.values.some(val => !Number.isFinite(val))
          }
        } : null,
        metadata: {
          type: v.metadata.type,
          fields: Object.keys(v.metadata),
          contentFields: {
            summary: v.metadata.type === 'summary' ? {
              exists: Object.keys(v.metadata).includes('summary'),
              length: (v.metadata as any).summary?.length,
              content: (v.metadata as any).summary?.substring(0, 100) + "..."
            } : undefined,
            transcription: v.metadata.type === 'transcription' ? {
              exists: Object.keys(v.metadata).includes('transcription'),
              length: (v.metadata as any).transcription?.length,
              content: (v.metadata as any).transcription?.substring(0, 100) + "..."
            } : undefined,
            searchableText: {
              exists: Object.keys(v.metadata).includes('searchableText'),
              length: (v.metadata as any).searchableText?.length
            }
          }
        }
      }))
    });

    try {
      const index = this.pinecone.index(this.INDEX_NAME);

      // Create a deep copy of vectors to ensure we don't lose data
      const pineconeVectors = vectors.map(vector => {
        // Log the exact state of the original vector
        functions.logger.info(`Original vector state for ${vector.id}:`, {
          metadata: {
            type: vector.metadata.type,
            fields: Object.keys(vector.metadata),
            propertyDescriptors: Object.getOwnPropertyDescriptor(vector.metadata, 'summary'),
            fieldTypes: {
              summary: typeof (vector.metadata as any).summary,
              searchableText: typeof (vector.metadata as any).searchableText
            },
            fieldValues: {
              summary: (vector.metadata as any).summary?.substring(0, 100),
              searchableText: (vector.metadata as any).searchableText?.substring(0, 100)
            },
            fieldLengths: {
              summary: (vector.metadata as any).summary?.length,
              searchableText: (vector.metadata as any).searchableText?.length
            }
          }
        });

        // Create a structured copy to ensure we don't lose data
        const vectorCopy = {
          id: vector.id,
          values: [...vector.values],
          metadata: {
            ...vector.metadata,
            // Explicitly copy required fields for summary type
            ...(vector.metadata.type === 'summary' && {
              summary: (vector.metadata as any).summary,
              searchableText: (vector.metadata as any).searchableText
            }),
            // Explicitly copy required fields for transcription type
            ...(vector.metadata.type === 'transcription' && {
              transcription: (vector.metadata as any).transcription,
              searchableText: (vector.metadata as any).searchableText
            })
          }
        };

        // Log the state after copy
        functions.logger.info(`Copied vector state for ${vector.id}:`, {
          metadata: {
            type: vectorCopy.metadata.type,
            fields: Object.keys(vectorCopy.metadata),
            propertyDescriptors: Object.getOwnPropertyDescriptor(vectorCopy.metadata, 'summary'),
            fieldTypes: {
              summary: typeof (vectorCopy.metadata as any).summary,
              searchableText: typeof (vectorCopy.metadata as any).searchableText
            },
            fieldValues: {
              summary: (vectorCopy.metadata as any).summary?.substring(0, 100),
              searchableText: (vectorCopy.metadata as any).searchableText?.substring(0, 100)
            },
            fieldLengths: {
              summary: (vectorCopy.metadata as any).summary?.length,
              searchableText: (vectorCopy.metadata as any).searchableText?.length
            }
          }
        });

        // Validate the copy
        if (vectorCopy.metadata.type === 'summary') {
          const originalSummary = (vector.metadata as any).summary;
          const copiedSummary = (vectorCopy.metadata as any).summary;
          const originalSearchableText = (vector.metadata as any).searchableText;
          const copiedSearchableText = (vectorCopy.metadata as any).searchableText;

          functions.logger.info(`Validation comparison for ${vector.id}:`, {
            summary: {
              original: {
                exists: 'summary' in vector.metadata,
                type: typeof originalSummary,
                length: originalSummary?.length,
                value: originalSummary?.substring(0, 100)
              },
              copied: {
                exists: 'summary' in vectorCopy.metadata,
                type: typeof copiedSummary,
                length: copiedSummary?.length,
                value: copiedSummary?.substring(0, 100)
              },
              matches: originalSummary === copiedSummary
            },
            searchableText: {
              original: {
                exists: 'searchableText' in vector.metadata,
                type: typeof originalSearchableText,
                length: originalSearchableText?.length,
                value: originalSearchableText?.substring(0, 100)
              },
              copied: {
                exists: 'searchableText' in vectorCopy.metadata,
                type: typeof copiedSearchableText,
                length: copiedSearchableText?.length,
                value: copiedSearchableText?.substring(0, 100)
              },
              matches: originalSearchableText === copiedSearchableText
            }
          });

          if (!('summary' in vectorCopy.metadata) || !('searchableText' in vectorCopy.metadata)) {
            throw new Error(`Fields missing after copy in ${vector.id}. Summary: ${'summary' in vectorCopy.metadata}, SearchableText: ${'searchableText' in vectorCopy.metadata}`);
          }

          if (typeof vectorCopy.metadata.summary !== 'string' || typeof vectorCopy.metadata.searchableText !== 'string') {
            throw new Error(`Invalid field types after copy in ${vector.id}. Summary: ${typeof vectorCopy.metadata.summary}, SearchableText: ${typeof vectorCopy.metadata.searchableText}`);
          }

          if (originalSummary !== copiedSummary || originalSearchableText !== copiedSearchableText) {
            throw new Error(`Content changed during copy for ${vector.id}`);
          }
        }
        
        return vectorCopy;
      });

      // Final validation before upsert
      functions.logger.info("Final vector state before Pinecone upsert:", {
        count: pineconeVectors.length,
        vectors: pineconeVectors.map(v => ({
          id: v.id,
          valuesLength: v.values.length,
          metadata: {
            type: v.metadata.type,
            allFields: Object.keys(v.metadata),
            contentSizes: {
              total: JSON.stringify(v.metadata).length,
              summary: v.metadata.type === 'summary' ? (v.metadata as any).summary?.length : undefined,
              transcription: v.metadata.type === 'transcription' ? (v.metadata as any).transcription?.length : undefined,
              searchableText: (v.metadata as any).searchableText?.length
            },
            contentPreviews: {
              summary: v.metadata.type === 'summary' ? (v.metadata as any).summary?.substring(0, 100) + "..." : undefined,
              transcription: v.metadata.type === 'transcription' ? (v.metadata as any).transcription?.substring(0, 100) + "..." : undefined,
              searchableText: (v.metadata as any).searchableText?.substring(0, 100) + "..."
            }
          }
        }))
      });

      // Use the copied and validated vectors
      functions.logger.info("Attempting Pinecone upsert with vectors:", {
        vectorCount: pineconeVectors.length,
        vectors: pineconeVectors.map(v => ({
          id: v.id,
          valuesType: typeof v.values,
          isValuesArray: Array.isArray(v.values),
          valuesLength: v.values?.length,
          firstFewValues: Array.isArray(v.values) ? v.values.slice(0, 5) : null,
          metadata: {
            type: v.metadata.type,
            fields: Object.keys(v.metadata),
            contentSizes: {
              total: JSON.stringify(v.metadata).length,
              summary: v.metadata.type === 'summary' ? (v.metadata as any).summary?.length : undefined,
              transcription: v.metadata.type === 'transcription' ? (v.metadata as any).transcription?.length : undefined,
              searchableText: (v.metadata as any).searchableText?.length
            }
          }
        }))
      });

      try {
        await index.upsert(pineconeVectors);
        functions.logger.info("Pinecone upsert API call completed successfully");
      } catch (error) {
        const errorDetails = this.formatError(error);
        functions.logger.error("Pinecone upsert API call failed:", {
          error: errorDetails,
          request: {
            vectorCount: pineconeVectors.length,
            vectorIds: pineconeVectors.map(v => v.id),
            vectorSizes: pineconeVectors.map(v => ({
              id: v.id,
              valuesLength: v.values?.length,
              metadataSize: JSON.stringify(v.metadata).length
            }))
          }
        });
        throw error;
      }
      
      functions.logger.info("Successfully upserted vectors to Pinecone", {
        vectorCount: pineconeVectors.length,
        vectorIds: pineconeVectors.map(v => v.id),
        finalMetadataState: pineconeVectors.map(v => ({
          id: v.id,
          type: v.metadata.type,
          contentLengths: {
            summary: v.metadata.type === 'summary' ? (v.metadata as any).summary?.length : undefined,
            transcription: v.metadata.type === 'transcription' ? (v.metadata as any).transcription?.length : undefined,
            searchableText: (v.metadata as any).searchableText?.length
          }
        }))
      });
    } catch (error) {
      const errorDetails = this.formatError(error);
      functions.logger.error("Error upserting vectors:", {
        error: errorDetails,
        vectorIds: vectors.map(v => v.id),
        vectorCount: vectors.length,
        lastKnownState: vectors.map(v => ({
          id: v.id,
          type: v.metadata.type,
          hadContent: v.metadata.type === 'summary' ? 
            !!((v.metadata as any).summary?.length) : 
            !!((v.metadata as any).transcription?.length)
        }))
      });
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
      functions.logger.info("Starting hybrid search with parameters:", {
        vectorLength: queryVector.length,
        limit
      });

      const index = this.pinecone.index(this.INDEX_NAME);
      
      // Search in both vector spaces
      const [summaryResponse, transcriptionResponse] = await Promise.all([
        index.query({
          vector: queryVector,
          topK: limit,
          includeMetadata: true,
          filter: { type: "summary" }
        }),
        index.query({
          vector: queryVector,
          topK: limit,
          includeMetadata: true,
          filter: { type: "transcription" }
        })
      ]);

      functions.logger.info("Received search responses:", {
        summaryMatches: summaryResponse.matches.length,
        transcriptionMatches: transcriptionResponse.matches.length
      });

      // Combine and deduplicate results
      const allMatches = [...summaryResponse.matches, ...transcriptionResponse.matches];
      const videoIdSet = new Set<string>();
      const dedupedResults: SearchResult[] = [];

      // Sort by weighted score and deduplicate by videoId
      allMatches
        .sort((a, b) => {
          const aMetadata = a.metadata as VideoMetadata;
          const bMetadata = b.metadata as VideoMetadata;
          const aScore = (a.score || 0) * this.WEIGHTS[aMetadata.type as keyof typeof this.WEIGHTS];
          const bScore = (b.score || 0) * this.WEIGHTS[bMetadata.type as keyof typeof this.WEIGHTS];
          return bScore - aScore;
        })
        .forEach(match => {
          const metadata = match.metadata as VideoMetadata;
          const weightedScore = (match.score || 0) * this.WEIGHTS[metadata.type as keyof typeof this.WEIGHTS];
          
          if (!videoIdSet.has(metadata.videoId) && weightedScore >= this.SIMILARITY_THRESHOLD) {
            videoIdSet.add(metadata.videoId);
            dedupedResults.push({
              id: match.id,
              score: weightedScore,
              metadata: metadata,
              type: "semantic"
            });
          }
        });

      functions.logger.info("Search results processed:", {
        totalMatches: allMatches.length,
        dedupedResults: dedupedResults.length,
        finalResults: Math.min(dedupedResults.length, limit)
      });

      // Limit final results
      return { results: dedupedResults.slice(0, limit) };
    } catch (error) {
      const errorDetails = this.formatError(error);
      functions.logger.error("Error performing hybrid search:", errorDetails);
      throw error;
    }
  }
}
