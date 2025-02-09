import * as functions from "firebase-functions/v2";
import * as ffmpeg from "fluent-ffmpeg";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { Storage } from "@google-cloud/storage";
import OpenAI from "openai";
import { ChatCompletionContentPartImage, ChatCompletionContentPartText } from "openai/resources/chat/completions";
import { PineconeService } from "../services/pinecone.service";
import * as admin from "firebase-admin";
import { VideoMetadata } from "../types";

// Add type declaration for fluent-ffmpeg
declare module "fluent-ffmpeg" {
  interface FfmpegCommand {
    screenshots(options: {
      count: number;
      folder: string;
      filename: string;
      size: string;
    }): FfmpegCommand;
  }
}

interface FrameAnalysis {
  timestamp: number;
  description: string;
  detectedIngredients: string[];
  detectedTools: string[];
  detectedTechniques: string[];
}

interface VideoAnalysis {
  frames: FrameAnalysis[];
  transcription: string;
  summary: string;
  ingredients: string[];
  tools: string[];
  techniques: string[];
  steps: string[];
}

export class VideoProcessorService {
  private openai: OpenAI;
  private storage: Storage;
  private storageBucket: string;
  private readonly MAX_FILE_SIZE_MB = 100;
  private readonly PROCESSING_TIMEOUT_MS = 540000; // 9 minutes (Cloud Function timeout is 10 minutes)

  constructor() {
    const openaiKey = process.env.OPENAI_API_KEY;
    const storageBucket = process.env.STORAGE_BUCKET;
    
    if (!openaiKey) {
      throw new Error("OpenAI API key is required");
    }
    
    if (!storageBucket) {
      throw new Error("STORAGE_BUCKET environment variable is required");
    }
    
    this.openai = new OpenAI({
      apiKey: openaiKey,
    });
    
    this.storageBucket = storageBucket;
    
    try {
      this.storage = new Storage({
        projectId: process.env.GCLOUD_PROJECT,
      });
      functions.logger.info("VideoProcessorService initialized successfully with bucket:", this.storageBucket);
    } catch (error) {
      functions.logger.error("Failed to initialize Storage", error);
      throw new Error("Storage initialization failed");
    }
  }

  async processVideo(videoUrl: string, videoId: string): Promise<VideoAnalysis> {
    const startTime = Date.now();
    let tempFilePath: string | null = null;
    let framesDir: string | null = null;
    let audioPath: string | null = null;
    
    try {
      functions.logger.info(`Starting video processing for ${videoId}`);
      
      // Get video data from Firestore
      const db = admin.firestore();
      const videoDoc = await db.collection("videos").doc(videoId).get();
      const videoData = videoDoc.data();

      if (!videoData) {
        throw new Error("Video data not found");
      }
      
      // Create temp directories and paths
      framesDir = path.join(os.tmpdir(), videoId);
      tempFilePath = path.join(framesDir, `video.mp4`);
      audioPath = path.join(os.tmpdir(), `${videoId}_audio.mp3`);

      // Create temp directory
      await fs.promises.mkdir(framesDir, { recursive: true });

      // Extract file path from URL
      const filePathMatch = videoUrl.match(/\/o\/(.+?)\?/);
      if (!filePathMatch) {
        throw new Error("Invalid video URL format");
      }
      const filePath = decodeURIComponent(filePathMatch[1]);
      functions.logger.info("Parsed video location", { bucket: this.storageBucket, filePath });

      // Start video streaming and processing
      const videoStream = this.storage.bucket(this.storageBucket).file(filePath).createReadStream();
      const writeStream = fs.createWriteStream(tempFilePath);

      // Process video as it streams
      await new Promise<void>((resolve, reject) => {
        videoStream
          .on('error', (error) => {
            functions.logger.error("Error streaming video:", error);
            reject(error);
          })
          .pipe(writeStream)
          .on('finish', () => {
            functions.logger.info(`Video streamed successfully to ${tempFilePath}`);
            resolve();
          })
          .on('error', (error) => {
            functions.logger.error("Error writing video stream:", error);
            reject(error);
          });
      });

      functions.logger.info(`Video streaming completed`);

      // Check file size
      const stats = await fs.promises.stat(tempFilePath);
      const fileSizeMB = stats.size / (1024 * 1024);
      if (fileSizeMB > this.MAX_FILE_SIZE_MB) {
        throw new Error(
          `Video file size (${fileSizeMB.toFixed(2)}MB) exceeds maximum allowed size (${this.MAX_FILE_SIZE_MB}MB)`
        );
      }

      // Check remaining time
      const timeElapsed = Date.now() - startTime;
      if (timeElapsed > this.PROCESSING_TIMEOUT_MS) {
        throw new Error("Processing timeout exceeded");
      }

      // Start audio extraction and transcription immediately
      const transcriptionPromise = new Promise<string>(async (resolve, reject) => {
        try {
          // Extract audio
          await new Promise<void>((resolveExtraction, rejectExtraction) => {
            ffmpeg(tempFilePath)
              .toFormat("mp3")
              .audioChannels(1) // Mono audio
              .audioFrequency(16000) // 16kHz sample rate (standard for speech)
              .audioBitrate('32k') // Lower bitrate
              .outputOptions([
                '-preset ultrafast', // Fastest encoding
                '-movflags +faststart', // Optimize for fast start
                '-af aresample=async=1', // Handle async audio resampling
                '-ac 1', // Force mono
                '-ar 16000', // Force 16kHz
              ])
              .on("end", () => {
                functions.logger.info("Audio extraction completed");
                resolveExtraction();
              })
              .on("error", (err) => {
                functions.logger.error("Error extracting audio:", err);
                rejectExtraction(err);
              })
              .save(audioPath!);
          });

          // Start transcription immediately after extraction
          functions.logger.info("Starting transcription");
          const transcription = await this.transcribeAudio(audioPath!);
          resolve(transcription);
        } catch (error) {
          reject(error);
        }
      });

      // Extract frames in parallel with audio processing
      functions.logger.info("Starting frame extraction");
      const frameFiles = await this.extractFrames(tempFilePath, framesDir);
      
      // Double check we have exactly 12 frames
      if (frameFiles.length !== 12) {
        throw new Error(`Expected 12 frames but got ${frameFiles.length}`);
      }
      
      functions.logger.info("All 12 frames extracted successfully. Starting analysis...");

      // Process each frame individually
      const frameAnalysesPromises = frameFiles.map(async (framePath, frameIndex) => {
        functions.logger.info(`Analyzing frame ${frameIndex + 1} of ${frameFiles.length}`);
        
        const imageBase64 = await fs.promises.readFile(framePath, { encoding: "base64" });
        const frameContent = {
          type: "image_url" as const,
          image_url: {
            url: `data:image/jpeg;base64,${imageBase64}`,
          },
        } as ChatCompletionContentPartImage;

        const response = await this.openai.chat.completions.create({
          model: "gpt-4o-mini",
          messages: [
            {
              role: "user",
              content: [
                {
                  type: "text",
                  text: "Analyze this frame from a cooking video. " +
                        "Identify:\n" +
                        "1. Ingredients visible\n" +
                        "2. Cooking tools being used\n" +
                        "3. Cooking techniques being demonstrated\n" +
                        "4. A description of what's happening\n\n" +
                        "Format your response as a JSON object containing:\n" +
                        "- description: string\n" +
                        "- ingredients: string[]\n" +
                        "- tools: string[]\n" +
                        "- techniques: string[]\n\n" +
                        "Ensure the response is valid JSON. Do not include any trailing commas.",
                } as ChatCompletionContentPartText,
                frameContent,
              ],
            },
          ],
          max_tokens: 1000,
          temperature: 0.7,
        });

        const content = response.choices[0].message.content || "{}";
        let parsedAnalysis = JSON.parse(
          content
            .replace(/```json\n?/g, '')
            .replace(/```\n?/g, '')
            .replace(/,(\s*[}\]])/g, '$1')
            .trim()
        );

        return {
          timestamp: frameIndex * 5,
          description: parsedAnalysis.description || "No description available",
          detectedIngredients: Array.isArray(parsedAnalysis.ingredients) ? parsedAnalysis.ingredients : [],
          detectedTools: Array.isArray(parsedAnalysis.tools) ? parsedAnalysis.tools : [],
          detectedTechniques: Array.isArray(parsedAnalysis.techniques) ? parsedAnalysis.techniques : [],
        };
      });

      // Wait for both transcription and frame analyses to complete
      const [transcription, ...frameAnalyses] = await Promise.all([
        transcriptionPromise,
        ...frameAnalysesPromises
      ]);

      functions.logger.info("Frame analysis and transcription complete. Generating final analysis...");
      
      // Generate comprehensive analysis
      const analysis = await this.generateAnalysis(frameAnalyses, transcription);

      // Store vectors in Pinecone
      const pineconeService = new PineconeService(process.env.PINECONE_API_KEY || "");
      
      // Constants for Pinecone limits
      const PINECONE_METADATA_SIZE_LIMIT = 40 * 1024; // 40KB per record
      const PINECONE_METADATA_FIELD_LIMIT = 32 * 1024; // 32KB per field

      // Validate and truncate metadata if needed
      const validateMetadata = (text: string, maxLength: number = PINECONE_METADATA_FIELD_LIMIT): string => {
        if (!text) return "";
        return text.length > maxLength ? text.substring(0, maxLength) : text;
      };

      // Prepare metadata with strict validation
      const summaryMetadata: VideoMetadata = {
            videoId,
            type: "summary",
            summary: analysis.summary,
            ingredients: analysis.ingredients.slice(0, 100),
            tools: analysis.tools.slice(0, 50),
            techniques: analysis.techniques.slice(0, 50),
            steps: analysis.steps.slice(0, 100),
            userId: videoData.userId,
            status: videoData.status || "active",
            privacy: videoData.privacy || "everyone",
            tags: (videoData.tags || []).slice(0, 50),
            version: 1,
            contentLength: analysis.summary.length,
            hasDescription: "true",
            hasAiDescription: "true",
            hasTags: String(videoData.tags?.length > 0),
            searchableText: [
              analysis.summary,
              analysis.ingredients.join(" "),
              analysis.tools.join(" "),
              analysis.techniques.join(" ")
            ].join(" ").toLowerCase()
      };

      const transcriptionMetadata: VideoMetadata = {
            videoId,
            type: "transcription",
            transcription: analysis.transcription,
            userId: videoData.userId,
            status: videoData.status || "active",
            privacy: videoData.privacy || "everyone",
            tags: (videoData.tags || []).slice(0, 50),
            version: 1,
            contentLength: analysis.transcription.length,
            hasDescription: "true",
            hasAiDescription: "true",
            hasTags: String(videoData.tags?.length > 0),
            searchableText: analysis.transcription.toLowerCase()
      };

      // Add initial state validation
      functions.logger.info("Initial summary metadata state:", {
        rawAnalysis: {
          summaryLength: analysis.summary.length,
          summaryContent: analysis.summary.substring(0, 100),
          hasContent: !!analysis.summary
        },
        validatedFields: {
          summary: {
            value: validateMetadata(analysis.summary),
            length: validateMetadata(analysis.summary).length,
            isString: typeof validateMetadata(analysis.summary) === 'string'
          },
          searchableText: {
            value: validateMetadata([
              analysis.summary,
              analysis.ingredients.join(" "),
              analysis.tools.join(" "),
              analysis.techniques.join(" ")
            ].join(" ").toLowerCase()).substring(0, 100),
            length: validateMetadata([
              analysis.summary,
              analysis.ingredients.join(" "),
              analysis.tools.join(" "),
              analysis.techniques.join(" ")
            ].join(" ").toLowerCase()).length,
            isString: typeof validateMetadata([
              analysis.summary,
              analysis.ingredients.join(" "),
              analysis.tools.join(" "),
              analysis.techniques.join(" ")
            ].join(" ").toLowerCase()) === 'string'
          }
        },
          metadata: {
          hasFields: {
            summary: 'summary' in summaryMetadata,
            searchableText: 'searchableText' in summaryMetadata
          },
          fieldTypes: {
            summary: typeof summaryMetadata.summary,
            searchableText: typeof summaryMetadata.searchableText
          },
          lengths: {
            summary: summaryMetadata.summary?.length,
            searchableText: summaryMetadata.searchableText?.length
          }
        }
      });

      // Add detailed validation logging for transcription metadata
      functions.logger.info("Transcription metadata validation:", {
        original: {
          transcriptionLength: analysis.transcription.length,
          transcriptionContent: analysis.transcription.substring(0, 100),
          searchableTextLength: analysis.transcription.toLowerCase().length
        },
        metadata: {
          transcriptionLength: transcriptionMetadata.transcription?.length,
          transcriptionContent: transcriptionMetadata.transcription?.substring(0, 100),
          searchableTextLength: transcriptionMetadata.searchableText?.length,
          allFields: Object.keys(transcriptionMetadata),
          validation: {
            hasTranscription: !!transcriptionMetadata.transcription,
            hasSearchableText: !!transcriptionMetadata.searchableText,
            transcriptionMatches: transcriptionMetadata.transcription === validateMetadata(analysis.transcription),
            contentPreserved: transcriptionMetadata.transcription?.length > 0 && transcriptionMetadata.searchableText?.length > 0
          }
        }
      });

      // Validate total metadata size
      const validateTotalMetadataSize = (metadata: VideoMetadata): VideoMetadata => {
        const size = JSON.stringify(metadata).length;
        
        // Log initial state
        functions.logger.info("Starting metadata size validation:", {
          beforeValidation: {
            totalSize: size,
            type: metadata.type,
            fields: Object.keys(metadata),
            contentLengths: {
              summary: metadata.type === 'summary' ? metadata.summary?.length : undefined,
              transcription: metadata.type === 'transcription' ? metadata.transcription?.length : undefined,
              searchableText: metadata.searchableText?.length
            },
            contentExists: {
              summary: metadata.type === 'summary' ? 'summary' in metadata : undefined,
              transcription: metadata.type === 'transcription' ? 'transcription' in metadata : undefined,
              searchableText: 'searchableText' in metadata
            }
          }
        });

        // Always create a validated copy to ensure consistent handling
        const validatedMetadata = JSON.parse(JSON.stringify(metadata)) as VideoMetadata;
        
        // Validate required fields exist
        if (validatedMetadata.type === 'summary') {
          if (!('summary' in validatedMetadata)) {
            throw new Error('Summary field missing in metadata');
          }
          if (typeof validatedMetadata.summary !== 'string') {
            throw new Error('Summary field is not a string');
          }
        } else {
          if (!('transcription' in validatedMetadata)) {
            throw new Error('Transcription field missing in metadata');
          }
          if (typeof validatedMetadata.transcription !== 'string') {
            throw new Error('Transcription field is not a string');
          }
        }
        
        if (!('searchableText' in validatedMetadata)) {
          throw new Error('SearchableText field missing in metadata');
        }
        if (typeof validatedMetadata.searchableText !== 'string') {
          throw new Error('SearchableText field is not a string');
        }

        // Only truncate if size exceeds limit
        if (size > PINECONE_METADATA_SIZE_LIMIT) {
          functions.logger.warn(`Metadata size (${size} bytes) exceeds limit (${PINECONE_METADATA_SIZE_LIMIT} bytes). Truncating fields.`);
          
          if (validatedMetadata.type === 'summary') {
            validatedMetadata.summary = validateMetadata(validatedMetadata.summary, PINECONE_METADATA_SIZE_LIMIT / 4);
          } else {
            validatedMetadata.transcription = validateMetadata(validatedMetadata.transcription, PINECONE_METADATA_SIZE_LIMIT / 2);
          }
          validatedMetadata.searchableText = validateMetadata(validatedMetadata.searchableText, PINECONE_METADATA_SIZE_LIMIT / 2);
        }

        // Verify content after validation
        const finalSize = JSON.stringify(validatedMetadata).length;
        functions.logger.info("After size validation:", {
          afterValidation: {
            totalSize: finalSize,
            type: validatedMetadata.type,
            fields: Object.keys(validatedMetadata),
            contentLengths: {
              summary: validatedMetadata.type === 'summary' ? validatedMetadata.summary.length : undefined,
              transcription: validatedMetadata.type === 'transcription' ? validatedMetadata.transcription.length : undefined,
              searchableText: validatedMetadata.searchableText.length
            },
            validation: {
              sizeReduced: finalSize < size,
              preservedFields: Object.keys(metadata).every(key => key in validatedMetadata),
              contentPreserved: validatedMetadata.type === 'summary' ? 
                validatedMetadata.summary.length > 0 : 
                validatedMetadata.transcription.length > 0,
              searchableTextPreserved: validatedMetadata.searchableText.length > 0
            }
          }
        });

        return validatedMetadata;
      };

      const validatedSummaryMetadata = validateTotalMetadataSize(summaryMetadata);
      const validatedTranscriptionMetadata = validateTotalMetadataSize(transcriptionMetadata);

      functions.logger.info("Validated metadata sizes:", {
        summary: {
          original: analysis.summary.length,
          validated: validatedSummaryMetadata.summary?.length,
          totalSize: JSON.stringify(validatedSummaryMetadata).length,
          wasValidated: analysis.summary.length !== validatedSummaryMetadata.summary?.length
        },
        transcription: {
          original: analysis.transcription.length,
          validated: validatedTranscriptionMetadata.transcription?.length,
          totalSize: JSON.stringify(validatedTranscriptionMetadata).length,
          wasValidated: analysis.transcription.length !== validatedTranscriptionMetadata.transcription?.length
        }
      });

      // Add detailed logging before Pinecone storage
      functions.logger.info("Preparing data for Pinecone storage:", {
        analysisDetails: {
          summaryLength: analysis.summary.length,
          summaryContent: analysis.summary.substring(0, 100) + "...",
          transcriptionLength: analysis.transcription.length,
          transcriptionContent: analysis.transcription.substring(0, 100) + "...",
          hasValidSummary: analysis.summary.length > 0,
          hasValidTranscription: analysis.transcription.length > 0
        }
      });

      // Add logging for embedding creation
      const summaryEmbeddingInput = [
        analysis.summary,
        analysis.ingredients.join(" "),
        analysis.tools.join(" "),
        analysis.techniques.join(" "),
      ].join(" ");

      functions.logger.info("Creating embeddings:", {
        summaryEmbeddingLength: summaryEmbeddingInput.length,
        summaryEmbeddingPreview: summaryEmbeddingInput.substring(0, 100) + "...",
        transcriptionEmbeddingLength: analysis.transcription.length,
        transcriptionEmbeddingPreview: analysis.transcription.substring(0, 100) + "..."
      });

      // Create embeddings with detailed logging
      functions.logger.info("Starting parallel OpenAI embedding creation");
      const [summaryEmbedding, transcriptionEmbedding] = await Promise.all([
        this.openai.embeddings.create({
          model: "text-embedding-3-large",
          input: summaryEmbeddingInput,
        }),
        this.openai.embeddings.create({
          model: "text-embedding-3-large",
          input: analysis.transcription,
        })
      ]);
      
      functions.logger.info("Raw OpenAI embeddings response:", {
        summary: {
          hasData: !!summaryEmbedding.data,
          dataLength: summaryEmbedding.data?.length,
          firstEmbedding: summaryEmbedding.data?.[0] ? {
            hasEmbedding: !!summaryEmbedding.data[0].embedding,
            embeddingLength: summaryEmbedding.data[0].embedding?.length,
            embeddingType: typeof summaryEmbedding.data[0].embedding,
            isArray: Array.isArray(summaryEmbedding.data[0].embedding),
            firstFewValues: summaryEmbedding.data[0].embedding?.slice(0, 5),
            hasNullOrUndefined: summaryEmbedding.data[0].embedding?.some(v => v === null || v === undefined),
            hasNonFinite: summaryEmbedding.data[0].embedding?.some(v => !Number.isFinite(v))
          } : null,
          model: summaryEmbedding.model,
          object: summaryEmbedding.object
        },
        transcription: {
          hasData: !!transcriptionEmbedding.data,
          dataLength: transcriptionEmbedding.data?.length,
          firstEmbedding: transcriptionEmbedding.data?.[0] ? {
            hasEmbedding: !!transcriptionEmbedding.data[0].embedding,
            embeddingLength: transcriptionEmbedding.data[0].embedding?.length,
            embeddingType: typeof transcriptionEmbedding.data[0].embedding,
            isArray: Array.isArray(transcriptionEmbedding.data[0].embedding),
            firstFewValues: transcriptionEmbedding.data[0].embedding?.slice(0, 5),
            hasNullOrUndefined: transcriptionEmbedding.data[0].embedding?.some(v => v === null || v === undefined),
            hasNonFinite: transcriptionEmbedding.data[0].embedding?.some(v => !Number.isFinite(v))
          } : null,
          model: transcriptionEmbedding.model,
          object: transcriptionEmbedding.object
        }
      });

      // Validate embeddings
      if (!summaryEmbedding.data[0]?.embedding || 
          summaryEmbedding.data[0].embedding.some(val => val === null || !Number.isFinite(val))) {
        throw new Error("Invalid summary embedding values from OpenAI");
      }
      if (!transcriptionEmbedding.data[0]?.embedding || 
          transcriptionEmbedding.data[0].embedding.some(val => val === null || !Number.isFinite(val))) {
        throw new Error("Invalid transcription embedding values from OpenAI");
      }

      // Prepare vectors with validation
      const vectors = [
        {
          id: `${videoId}_summary`,
          values: summaryEmbedding.data[0].embedding,
          metadata: validatedSummaryMetadata,
        },
        {
          id: `${videoId}_transcription`,
          values: transcriptionEmbedding.data[0].embedding,
          metadata: validatedTranscriptionMetadata,
        },
      ];

      // Add pre-vector validation
      functions.logger.info("Pre-vector metadata validation:", {
        summary: {
          metadata: validatedSummaryMetadata,
          validation: {
            type: validatedSummaryMetadata.type,
            hasSummaryField: 'summary' in validatedSummaryMetadata,
            summaryExists: !!validatedSummaryMetadata.summary,
            summaryLength: validatedSummaryMetadata.summary?.length,
            hasSearchableText: 'searchableText' in validatedSummaryMetadata,
            searchableTextExists: !!validatedSummaryMetadata.searchableText,
            searchableTextLength: validatedSummaryMetadata.searchableText?.length,
            allFields: Object.keys(validatedSummaryMetadata),
            contentPreview: {
              summary: validatedSummaryMetadata.summary?.substring(0, 100),
              searchableText: validatedSummaryMetadata.searchableText?.substring(0, 100)
            }
          }
        },
        transcription: {
          metadata: validatedTranscriptionMetadata,
          validation: {
            type: validatedTranscriptionMetadata.type,
            hasTranscriptionField: 'transcription' in validatedTranscriptionMetadata,
            transcriptionExists: !!validatedTranscriptionMetadata.transcription,
            transcriptionLength: validatedTranscriptionMetadata.transcription?.length,
            hasSearchableText: 'searchableText' in validatedTranscriptionMetadata,
            searchableTextExists: !!validatedTranscriptionMetadata.searchableText,
            searchableTextLength: validatedTranscriptionMetadata.searchableText?.length,
            allFields: Object.keys(validatedTranscriptionMetadata),
            contentPreview: {
              transcription: validatedTranscriptionMetadata.transcription?.substring(0, 100),
              searchableText: validatedTranscriptionMetadata.searchableText?.substring(0, 100)
            }
          }
        }
      });

      // Validate metadata before creating vectors
      if (!validatedSummaryMetadata.summary || !validatedSummaryMetadata.searchableText) {
        throw new Error("Summary metadata is missing required fields before vector creation");
      }
      if (!validatedTranscriptionMetadata.transcription || !validatedTranscriptionMetadata.searchableText) {
        throw new Error("Transcription metadata is missing required fields before vector creation");
      }

      functions.logger.info("Prepared vectors for Pinecone:", {
        vectorCount: vectors.length,
        vectors: vectors.map(v => ({
          id: v.id,
          hasValues: !!v.values,
          valuesLength: v.values?.length,
          metadataKeys: Object.keys(v.metadata),
          metadataSize: JSON.stringify(v.metadata).length,
          metadataContentLengths: {
            summary: v.metadata.type === 'summary' ? (v.metadata as any).summary?.length : undefined,
            transcription: v.metadata.type === 'transcription' ? (v.metadata as any).transcription?.length : undefined,
            searchableText: (v.metadata as any).searchableText?.length
          }
        }))
      });

      // Add validation before upsert
      const validatedVectors = vectors.map(vector => {
        functions.logger.info(`Validating vector ${vector.id}:`, {
          hasValues: !!vector.values,
          valuesLength: vector.values?.length,
          metadata: {
            type: vector.metadata.type,
            contentLength: vector.metadata.contentLength,
            hasValidContent: vector.metadata.type === 'summary' 
              ? !!(vector.metadata as any).summary?.length 
              : !!(vector.metadata as any).transcription?.length
          }
        });
        return vector;
      });

      console.log("Storing vectors in Pinecone", { videoId });
      
      await pineconeService.upsert(validatedVectors);

      // After vector creation
      functions.logger.info("Vectors created:", {
        summary: {
          id: vectors[0].id,
          hasEmbedding: !!vectors[0].values,
          embeddingLength: vectors[0].values?.length,
          metadata: {
            type: vectors[0].metadata.type,
            fields: Object.keys(vectors[0].metadata),
            contentLengths: {
              summary: vectors[0].metadata.type === 'summary' ? (vectors[0].metadata as any).summary?.length : undefined,
              searchableText: (vectors[0].metadata as any).searchableText?.length
            },
            fullContent: vectors[0].metadata.type === 'summary' ? 
              (vectors[0].metadata as any).summary?.substring(0, 100) + "..." : undefined
          }
        },
        transcription: {
          id: vectors[1].id,
          hasEmbedding: !!vectors[1].values,
          embeddingLength: vectors[1].values?.length,
          metadata: {
            type: vectors[1].metadata.type,
            fields: Object.keys(vectors[1].metadata),
            contentLengths: {
              transcription: vectors[1].metadata.type === 'transcription' ? 
                (vectors[1].metadata as any).transcription?.length : undefined,
              searchableText: (vectors[1].metadata as any).searchableText?.length
            },
            fullContent: vectors[1].metadata.type === 'transcription' ? 
              (vectors[1].metadata as any).transcription?.substring(0, 100) + "..." : undefined
          }
        }
      });

      return analysis;
    } catch (error) {
      functions.logger.error("Error in processVideo:", error);
      throw error;
    } finally {
      // Cleanup in finally block to ensure it runs
      try {
        if (framesDir) {
          functions.logger.info(`Cleaning up directory: ${framesDir}`);
          await fs.promises.rm(framesDir, { recursive: true, force: true });
        }
      } catch (cleanupError) {
        functions.logger.warn("Error during cleanup:", cleanupError);
      }
    }
  }

  private async downloadVideo(url: string, destPath: string): Promise<void> {
    try {
      if (!url || !destPath) {
        throw new Error("URL and destination path are required for video download");
      }
      
      functions.logger.info("Downloading video", { url, destPath });
      
      // Log the URL format for debugging
      functions.logger.info("URL format analysis:", {
        url: url.replace(/(?<=\/)[^\/]+(?=\?)/, "REDACTED"), // Redact sensitive parts
        hasV0: url.includes("/v0/"),
        hasBucket: url.includes("/b/"),
        hasObject: url.includes("/o/"),
        hasQueryParams: url.includes("?"),
        urlParts: url.split("/"),
      });
      
      // Extract the file path from the URL using a more flexible regex
      const filePathMatch = url.match(/\/o\/(.+?)\?/);
      if (!filePathMatch) {
        throw new Error("Invalid video URL format");
      }
      
      const filePath = decodeURIComponent(filePathMatch[1]);
      functions.logger.info("Parsed video location", { bucket: this.storageBucket, filePath });
      
      const bucket = this.storage.bucket(this.storageBucket);
      const file = bucket.file(filePath);
      
      await file.download({ destination: destPath });
      functions.logger.info(`Video downloaded successfully to ${destPath}`);
    } catch (error) {
      functions.logger.error("Error downloading video:", error);
      throw error;
    }
  }

  private async extractFrames(videoPath: string, framesDir: string): Promise<string[]> {
    functions.logger.info(`Extracting frames from ${videoPath} to ${framesDir}`);
    
    return new Promise((resolve, reject) => {
      const totalFrames = 12;
      
      // First, get video duration
      ffmpeg.ffprobe(videoPath, (err, metadata) => {
        if (err) {
          functions.logger.error("Error probing video:", err);
          reject(err);
          return;
        }

        const duration = metadata.format.duration || 0;
        if (!duration) {
          reject(new Error("Could not determine video duration"));
          return;
        }

        functions.logger.info(`Video duration: ${duration} seconds`);

        // Calculate timestamps for even spacing
        const interval = duration / (totalFrames + 1); // +1 to ensure last frame isn't at the very end
        const timestamps = Array.from({ length: totalFrames }, (_, i) => {
          const timestamp = interval * (i + 1); // This ensures we're not at 0 or duration
          return Number(timestamp.toFixed(3)); // Fix to 3 decimal places for consistency
        });

        functions.logger.info(`Frame timestamps: ${timestamps.join(", ")}`);
        
        // Create the frames directory if it doesn't exist
        if (!fs.existsSync(framesDir)) {
          fs.mkdirSync(framesDir, { recursive: true });
        }

        // Process all frames in parallel
        const expectedFiles: string[] = [];
        let completedFrames = 0;
        let hasError = false;

        functions.logger.info(`Processing all ${totalFrames} frames in parallel`);

        // Create promises for all frames
        const framePromises = timestamps.map((timestamp, frameIndex) => {
          const outputPath = path.join(framesDir, `frame-${frameIndex + 1}.jpg`);
          expectedFiles[frameIndex] = outputPath;

          functions.logger.info(`Processing frame ${frameIndex + 1} at timestamp ${timestamp}s`);

          return new Promise<void>((resolveFrame, rejectFrame) => {
            ffmpeg(videoPath)
              .screenshots({
                timestamps: [timestamp],
                filename: `frame-${frameIndex + 1}.jpg`,
                folder: framesDir,
                size: "1280x720"
              })
              .on('end', () => {
                completedFrames++;
                functions.logger.info(`Frame ${frameIndex + 1} extracted successfully (${completedFrames}/${totalFrames})`);
                resolveFrame();
              })
              .on('error', (err: Error) => {
                functions.logger.error(`Error extracting frame ${frameIndex + 1}:`, err);
                rejectFrame(err);
              });
          });
        });

        // Process all frames in parallel
        Promise.all(framePromises)
          .then(async () => {
            // Verify frames after all are complete
            await verifyFrames();
          })
          .catch((error) => {
            hasError = true;
            reject(error);
          });

        const verifyFrames = async () => {
          try {
            functions.logger.info(`Starting frame verification. Expected ${totalFrames} frames.`);
            
            // Verify each frame exists and has content
            const fileChecks = await Promise.all(
              expectedFiles.map(async (framePath, index) => {
                try {
                  const stats = await fs.promises.stat(framePath);
                  if (stats.size === 0) {
                    throw new Error(`Frame file is empty: ${framePath}`);
                  }
                  functions.logger.info(`Verified frame ${index + 1}: ${framePath} (${stats.size} bytes)`);
                  return true;
                } catch (error) {
                  functions.logger.error(`Frame ${index + 1} verification failed:`, error);
                  return false;
                }
              })
            );

            // Check if all frames were successfully verified
            if (fileChecks.every(Boolean)) {
              functions.logger.info(`Successfully verified all ${totalFrames} frames`);
              resolve(expectedFiles);
            } else {
              const missingFrames = fileChecks
                .map((check, index) => !check ? index + 1 : null)
                .filter((index): index is number => index !== null);
              reject(new Error(`Failed to verify frames: ${missingFrames.join(", ")}`));
            }
          } catch (error) {
            functions.logger.error("Error in frame verification:", error);
            reject(error);
          }
        };
      });
    });
  }

  private async transcribeAudio(audioPath: string): Promise<string> {
    functions.logger.info("Starting audio transcription");
    
    try {
      // Create a readable stream from the audio file
      const audioStream = fs.createReadStream(audioPath);
      
      functions.logger.info("Starting OpenAI transcription with streaming");
      
      // Create a File object from the stream
      const file = new File([await this.streamToBuffer(audioStream)], "audio.mp3", { type: "audio/mp3" });

      // Transcribe audio
      const response = await this.openai.audio.transcriptions.create({
        file,
        model: "whisper-1",
        language: "en",
      });

      const transcription = response.text;
      functions.logger.info("Transcription details:", {
        hasResponse: !!response,
        hasText: !!response.text,
        transcriptionLength: transcription.length,
        transcriptionPreview: transcription.substring(0, 100) + "...",
        isEmpty: transcription.length === 0,
        model: "whisper-1"
      });

      functions.logger.info("Transcription completed", {
        transcriptionLength: transcription.length,
        transcriptionPreview: transcription.substring(0, 100) + "..."
      });
      
      return transcription;
    } catch (error) {
      functions.logger.error("Error in transcribeAudio:", error);
      throw error;
    }
  }

  // Helper function to convert stream to buffer
  private async streamToBuffer(stream: NodeJS.ReadableStream): Promise<Buffer> {
    return new Promise((resolve, reject) => {
      const chunks: Buffer[] = [];
      stream.on('data', (chunk) => chunks.push(Buffer.from(chunk)));
      stream.on('end', () => resolve(Buffer.concat(chunks)));
      stream.on('error', reject);
    });
  }

  private async generateAnalysis(
    frameAnalyses: FrameAnalysis[],
    transcriptionText: string
  ): Promise<VideoAnalysis> {
    functions.logger.info("Starting generateAnalysis with:", {
      framesCount: frameAnalyses.length,
      transcriptionLength: transcriptionText.length,
      transcriptionPreview: transcriptionText.substring(0, 100) + "...",
      hasValidTranscription: transcriptionText.length > 0
    });

    const prompt = `
      Analyze this cooking video content and create a structured analysis.
      You have frame-by-frame analyses and audio transcription.

      Frame Analyses: ${JSON.stringify(frameAnalyses, null, 2)}
      Audio Transcription: ${transcriptionText}
      
      Provide your analysis in the following EXACT format, maintaining these exact headings and formatting:

      SUMMARY:
      Write a clear, concise summary of the recipe in a single paragraph.

      INGREDIENTS:
      List only the food/drink ingredients, one per line:
      - ingredient 1
      - ingredient 2
      etc.

      TOOLS:
      List only the physical tools and equipment used, one per line:
      - tool 1
      - tool 2
      etc.

      TECHNIQUES:
      List only the cooking techniques and methods used, one per line:
      - technique 1
      - technique 2
      etc.

      STEPS:
      List the complete recipe steps in order, one per line, numbered:
      1. First step
      2. Second step
      3. Third step
      etc.

      IMPORTANT:
      - Follow the EXACT formatting shown above for each section
      - Each section MUST start with the heading (e.g., "STEPS:")
      - Use bullet points (-) for ingredients, tools, and techniques
      - Use numbers (1., 2., etc.) for steps
      - Do not include labels like "Tools:" or "Ingredients:" within the lists themselves
      - Keep each item concise and avoid mixing categories
      - For tools, only include all physical cooking equipment (e.g., "bowl", "whisk", "knife", blender)
      - For techniques, only include actions (e.g., "whisking", "blending", "cutting", "stirring")
      - For ingredients, only include food/drink items
      - Ensure steps are complete sentences
      - Each step must be on its own line and start with a number
    `;

    functions.logger.info("Sending analysis request to OpenAI with prompt length:", prompt.length);

    const response = await this.openai.chat.completions.create({
      model: "gpt-4o-mini",
      messages: [{ role: "user", content: prompt }],
      temperature: 0.7,
      max_tokens: 2000,
    });

    functions.logger.info("OpenAI response details:", {
      hasChoices: response.choices.length > 0,
      firstChoice: response.choices[0] ? {
        finishReason: response.choices[0].finish_reason,
        hasContent: !!response.choices[0].message.content,
        contentLength: response.choices[0].message.content?.length || 0,
        contentPreview: response.choices[0].message.content?.substring(0, 100) || "NO CONTENT"
      } : "NO CHOICES"
    });

    const content = response.choices[0].message.content || "";
    
    // Log the complete raw response
    functions.logger.info("Complete raw analysis response from OpenAI:", {
      fullResponse: content,
      responseLength: content.length,
      hasSummarySection: content.includes("SUMMARY:"),
      summaryIndex: content.indexOf("SUMMARY:"),
      nextSectionIndex: content.indexOf("INGREDIENTS:"),
      summaryContent: content.substring(
        content.indexOf("SUMMARY:") + 8,
        content.indexOf("INGREDIENTS:")
      ).trim()
    });
    
    const analysis = this.parseAnalysisResponse(content);

    // Log the analysis object before creating final analysis
    functions.logger.info("Analysis after parsing:", {
      summaryLength: analysis.summary.length,
      summaryContent: analysis.summary,
      ingredientsCount: analysis.ingredients.length,
      toolsCount: analysis.tools.length,
      techniquesCount: analysis.techniques.length,
      stepsCount: analysis.steps.length
    });

    // Create the final analysis object with all components
    const finalAnalysis: VideoAnalysis = {
      frames: [],
      transcription: transcriptionText,
      summary: analysis.summary,
      ingredients: analysis.ingredients,
      tools: analysis.tools,
      techniques: analysis.techniques,
      steps: analysis.steps,
    };

    // Add validation logging
    functions.logger.info("Generated final analysis:", {
      transcriptionSource: {
        originalLength: transcriptionText.length,
        finalLength: finalAnalysis.transcription.length,
        isPreserved: transcriptionText === finalAnalysis.transcription
      },
      analysisComponents: {
      summaryLength: finalAnalysis.summary.length,
      ingredientsCount: finalAnalysis.ingredients.length,
      toolsCount: finalAnalysis.tools.length,
      techniquesCount: finalAnalysis.techniques.length,
      stepsCount: finalAnalysis.steps.length
      },
      validation: {
        hasTranscription: finalAnalysis.transcription.length > 0,
        hasSummary: finalAnalysis.summary.length > 0,
        transcriptionPreview: finalAnalysis.transcription.substring(0, 100) + "...",
        summaryPreview: finalAnalysis.summary.substring(0, 100) + "..."
      }
    });

    return finalAnalysis;
  }

  private parseAnalysisResponse(content: string): Omit<VideoAnalysis, 'frames' | 'transcription'> {
    functions.logger.info("Starting to parse analysis response");

    // Log the entire raw content first
    functions.logger.info("Raw content to parse:", {
      content: content,
      contentLength: content.length,
      sections: {
        summary: content.includes("SUMMARY:"),
        ingredients: content.includes("INGREDIENTS:"),
        tools: content.includes("TOOLS:"),
        techniques: content.includes("TECHNIQUES:"),
        steps: content.includes("STEPS:")
      }
    });

    // Extract summary with detailed logging
    const summaryMatch = content.match(/SUMMARY:\s*([\s\S]*?)(?=\n\s*(?:INGREDIENTS:|$))/);
    functions.logger.info("Summary extraction details:", {
      hasMatch: !!summaryMatch,
      matchGroups: summaryMatch ? summaryMatch.length : 0,
      rawMatch: summaryMatch ? summaryMatch[0] : null,
      extractedContent: summaryMatch ? summaryMatch[1] : null,
      trimmedContent: summaryMatch ? summaryMatch[1].trim() : null,
      contentIndexes: {
        summaryStart: content.indexOf("SUMMARY:"),
        ingredientsStart: content.indexOf("INGREDIENTS:"),
        toolsStart: content.indexOf("TOOLS:"),
        techniquesStart: content.indexOf("TECHNIQUES:"),
        stepsStart: content.indexOf("STEPS:")
      },
      contentSections: {
        hasSummaryHeader: content.includes("SUMMARY:"),
        hasIngredientsHeader: content.includes("INGREDIENTS:"),
        hasToolsHeader: content.includes("TOOLS:"),
        hasTechniquesHeader: content.includes("TECHNIQUES:"),
        hasStepsHeader: content.includes("STEPS:")
      },
      regexPattern: /SUMMARY:\s*([\s\S]*?)(?=\n\s*(?:INGREDIENTS:|$))/.toString()
    });

    const summary = (summaryMatch?.[1] || "").trim();

    functions.logger.info("Extracted summary:", {
      summary,
      length: summary.length,
      isEmpty: summary.length === 0,
      firstCharacters: summary.substring(0, 50)
    });

    // Log raw section matches before extraction
    const rawMatches = {
      summary: summaryMatch?.[0] || "no match",
      ingredients: content.match(/INGREDIENTS:[\s\S]*?(?=\n\s*(?:TOOLS:|$))/)?.[0] || "no match",
      tools: content.match(/TOOLS:[\s\S]*?(?=\n\s*(?:TECHNIQUES:|$))/)?.[0] || "no match",
      techniques: content.match(/TECHNIQUES:[\s\S]*?(?=\n\s*(?:STEPS:|$))/)?.[0] || "no match",
      steps: content.match(/STEPS:[\s\S]*$/)?.[0] || "no match"
    };

    functions.logger.info("Raw content section matches:", rawMatches);

    const ingredients = this.extractListSection("INGREDIENTS", content);
    const tools = this.extractListSection("TOOLS", content);
    const techniques = this.extractListSection("TECHNIQUES", content);
    const steps = this.extractSteps(content);

    // Log the final extracted data
    functions.logger.info("Final extracted data:", {
      summaryLength: summary.length,
      summaryContent: summary,
      ingredientsCount: ingredients.length,
      toolsCount: tools.length,
      techniquesCount: techniques.length,
      stepsCount: steps.length
    });

    return {
      summary,
      ingredients,
      tools,
      techniques,
      steps,
    };
  }

  private extractListSection(section: string, text: string): string[] {
    const regex = new RegExp(`${section}:\\s*([\\s\\S]*?)(?=\\n\\s*(?:[A-Z]+:|$))`, "i");
    const match = text.match(regex);
    
    // Log the regex match details
    functions.logger.info(`${section} extraction details:`, {
      hasMatch: !!match,
      matchGroups: match ? match.length : 0,
      rawMatch: match ? match[0] : null,
      extractedContent: match ? match[1] : null
    });
    
    if (!match) {
      functions.logger.warn(`No match found for section: ${section}`);
      return [];
    }
    
    const lines = match[1]
      .split("\n")
      .map(line => line.trim())
      .filter(line => line);  // Remove empty lines

    // Log the lines before processing
    functions.logger.info(`${section} lines before processing:`, lines);
    
    const processedLines = lines
      .map(line => line
        .replace(/^[-*•]\s*/, '')  // Remove bullet points
        .trim()
      )
      .filter(Boolean);  // Remove any lines that became empty

    // Log the final processed lines
    functions.logger.info(`${section} final processed lines:`, processedLines);
    
    return processedLines;
  }

  private extractSteps(text: string): string[] {
    functions.logger.info("Starting steps extraction with text length:", text.length);
    
    // First try to match everything between STEPS: and the next section
    const stepsRegex = /STEPS:\s*([\s\S]*?)(?=\n\s*[A-Z]+:|$)/i;
    // If that fails, match everything after STEPS: to the end
    const fallbackRegex = /STEPS:\s*([\s\S]*$)/i;
    
    let match = text.match(stepsRegex) || text.match(fallbackRegex);
    
    functions.logger.info("Steps extraction match details:", {
      hasMatch: !!match,
      matchGroups: match ? match.length : 0,
      rawMatch: match ? match[0] : null,
      extractedContent: match ? match[1] : null
    });
    
    if (!match || !match[1]) {
      functions.logger.warn("No steps section found or invalid match structure");
      return [];
    }
    
    const stepsContent = match[1].trim();
    if (!stepsContent) {
      functions.logger.warn("Steps section is empty");
      return [];
    }
    
    // Split by newline and process each line
    const lines = stepsContent
      .split('\n')
      .map(line => line.trim())
      .filter(line => line && /^\d+\./.test(line));  // Only keep numbered lines

    functions.logger.info("Steps before processing:", {
      totalLines: lines.length,
      lines: lines,
      rawContent: stepsContent
    });
    
    const processedLines = lines
      .map(line => {
        // Match numbered steps with better regex
        const numberMatch = line.match(/^(\d+)\.\s*(.+?)(?:\s*\([^)]*\))?\s*$/);
        if (!numberMatch) {
          functions.logger.warn("Line doesn't match expected format:", line);
          return null;
        }
        const [, number, content] = numberMatch;
        return content ? `${number}. ${content.trim()}` : null;
      })
      .filter((line): line is string => 
        line !== null && line.length > 5  // Ensure we have actual content
      );

    functions.logger.info("Final processed steps:", {
      totalSteps: processedLines.length,
      steps: processedLines,
      firstStep: processedLines[0],
      lastStep: processedLines[processedLines.length - 1]
    });
    
    return processedLines;
  }
} 