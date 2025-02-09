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
    let frameFiles: string[] = [];
    
    try {
      functions.logger.info(`Starting video processing for ${videoId}`);
      
      // Get video data from Firestore
      const db = admin.firestore();
      const videoDoc = await db.collection("videos").doc(videoId).get();
      const videoData = videoDoc.data();

      if (!videoData) {
        throw new Error("Video data not found");
      }
      
      // Create temp directory for this process
      framesDir = path.join(os.tmpdir(), videoId);
      await fs.promises.mkdir(framesDir, { recursive: true });
      functions.logger.info(`Created temporary directory: ${framesDir}`);
      
      // Download video to temp directory
      tempFilePath = path.join(framesDir, `video.mp4`);
      await this.downloadVideo(videoUrl, tempFilePath);

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

      // Extract frames - this will throw an error if any frame fails
      functions.logger.info("Starting frame extraction...");
      frameFiles = await this.extractFrames(tempFilePath, framesDir);
      
      // Double check we have exactly 12 frames
      if (frameFiles.length !== 12) {
        throw new Error(`Expected 12 frames but got ${frameFiles.length}`);
      }
      
      functions.logger.info("All 12 frames extracted successfully. Starting analysis...");
      
      // Now that we have all frames, proceed with analysis
      const [frameAnalyses, transcription] = await Promise.all([
        this.analyzeFrames(frameFiles),
        this.transcribeAudio(tempFilePath)
      ]);

      functions.logger.info("Frame analysis and transcription complete. Generating final analysis...");
      
      // Generate comprehensive analysis
      const analysis = await this.generateAnalysis(frameAnalyses, transcription);

      // Store vectors in Pinecone
      const pineconeService = new PineconeService(process.env.PINECONE_API_KEY || "");
      
      functions.logger.info("Preparing vectors for Pinecone storage:", {
        summary: {
          length: analysis.summary.length,
          content: analysis.summary.substring(0, 100) + "...",
          hasContent: analysis.summary.length > 0
        },
        transcription: {
          length: analysis.transcription.length,
          preview: analysis.transcription.substring(0, 100) + "...",
          hasContent: analysis.transcription.length > 0
        },
        ingredients: analysis.ingredients.length,
        tools: analysis.tools.length,
        techniques: analysis.techniques.length,
        steps: analysis.steps.length
      });
      
      console.log("Storing vectors in Pinecone", { videoId });
      
      await pineconeService.upsert([
        {
          id: `${videoId}_summary`,
          values: await this.openai.embeddings.create({
            model: "text-embedding-3-large",
            input: [
              analysis.summary,
              analysis.ingredients.join(" "),
              analysis.tools.join(" "),
              analysis.techniques.join(" "),
            ].join(" "),
          }).then(embedding => embedding.data[0].embedding),
          metadata: {
            videoId,
            type: "summary",
            summary: analysis.summary,
            ingredients: analysis.ingredients,
            tools: analysis.tools,
            techniques: analysis.techniques,
            steps: analysis.steps,
            userId: videoData.userId,
            status: videoData.status || "active",
            privacy: videoData.privacy || "everyone",
            tags: videoData.tags || [],
            version: 1,
            contentLength: analysis.summary.length,
            hasDescription: "true",
            hasAiDescription: "true",
            hasTags: String(videoData.tags?.length > 0),
          },
        },
        {
          id: `${videoId}_transcription`,
          values: await this.openai.embeddings.create({
            model: "text-embedding-3-large",
            input: analysis.transcription,
          }).then(embedding => embedding.data[0].embedding),
          metadata: {
            videoId,
            type: "transcription",
            transcription: analysis.transcription,
            userId: videoData.userId,
            status: videoData.status || "active",
            privacy: videoData.privacy || "everyone",
            tags: videoData.tags || [],
            version: 1,
            contentLength: analysis.transcription.length,
            hasDescription: "true",
            hasAiDescription: "true",
            hasTags: String(videoData.tags?.length > 0),
          },
        },
      ]);

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

        // Process each frame individually for better reliability
        let processedFrames = 0;
        const expectedFiles: string[] = [];

        const processNextFrame = (index: number) => {
          if (index >= totalFrames) {
            functions.logger.info("All frames processed, starting verification");
            verifyFrames();
            return;
          }

          const timestamp = timestamps[index];
          const outputPath = path.join(framesDir, `frame-${index + 1}.jpg`);
          expectedFiles.push(outputPath);

          functions.logger.info(`Processing frame ${index + 1} at timestamp ${timestamp}s`);

          ffmpeg(videoPath)
            .screenshots({
              timestamps: [timestamp],
              filename: `frame-${index + 1}.jpg`,
              folder: framesDir,
              size: "1280x720"
            })
            .on('end', () => {
              processedFrames++;
              functions.logger.info(`Frame ${index + 1} extracted successfully`);
              processNextFrame(index + 1);
            })
            .on('error', (err: Error) => {
              functions.logger.error(`Error extracting frame ${index + 1}:`, err);
              reject(err);
            });
        };

        const verifyFrames = async () => {
          try {
            functions.logger.info(`Starting frame verification. Expected ${totalFrames} frames.`);
            
            // Add a small delay to ensure filesystem has completed writing
            await new Promise(resolve => setTimeout(resolve, 1000));

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

        // Start processing frames
        processNextFrame(0);
      });
    });
  }

  private async analyzeFrames(frameFiles: string[]): Promise<FrameAnalysis[]> {
    try {
      // Verify we have exactly 12 frames before starting analysis
      if (frameFiles.length !== 12) {
        throw new Error(`Cannot analyze frames: Expected 12 frames but got ${frameFiles.length}`);
      }
      
      functions.logger.info("Starting batch frame analysis");
      
      // Verify all frames exist and are readable before starting analysis
      await Promise.all(
        frameFiles.map(async (framePath) => {
          try {
            const stats = await fs.promises.stat(framePath);
            if (stats.size === 0) {
              throw new Error(`Frame file is empty: ${framePath}`);
            }
          } catch (error) {
            functions.logger.error(`Frame verification failed for ${framePath}:`, error);
            throw new Error(`Frame verification failed: ${framePath}`);
          }
        })
      );
      
      functions.logger.info("All frames verified. Reading frame contents...");
      
      // Read all frames in parallel
      const frameContents = await Promise.all(
        frameFiles.map(async (framePath, index) => {
          const imageBase64 = await fs.promises.readFile(framePath, { encoding: "base64" });
          return {
            index,
            base64: imageBase64,
          };
        })
      );
      
      functions.logger.info(`Successfully loaded ${frameContents.length} frames for analysis`);

      // Create a single message with all frames
      const response = await this.openai.chat.completions.create({
        model: "gpt-4o-mini",
        messages: [
          {
            role: "user",
            content: [
              { 
                type: "text", 
                text: "Analyze these frames from a cooking video in sequence. " +
                      "For each frame, identify:\n" +
                      "1. Ingredients visible\n" +
                      "2. Cooking tools being used\n" +
                      "3. Cooking techniques being demonstrated\n" +
                      "4. A description of what's happening\n\n" +
                      "Format your response as a JSON array with each frame analysis containing:\n" +
                      "- description: string\n" +
                      "- ingredients: string[]\n" +
                      "- tools: string[]\n" +
                      "- techniques: string[]\n\n" +
                      "Ensure the response is valid JSON. Do not include any trailing commas in arrays or objects. " +
                      "Each frame analysis must be complete and properly formatted.",
              } as ChatCompletionContentPartText,
              ...frameContents.map(({ base64 }) => ({
                type: "image_url" as const,
                image_url: {
                  url: `data:image/jpeg;base64,${base64}`,
                },
              } as ChatCompletionContentPartImage)),
            ],
          },
        ],
        max_tokens: 4096,
        temperature: 0.7,
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

      const content = response.choices[0].message.content || "[]";
      
      // Log the raw response for debugging
      functions.logger.info("Raw GPT response:", content);
      
      let parsedAnalyses: Array<{
        description: string;
        ingredients: string[];
        tools: string[];
        techniques: string[];
      }>;

      try {
        // Clean up the response string
        const cleanedContent = content
          .replace(/```json\n?/g, '')     // Remove ```json
          .replace(/```\n?/g, '')         // Remove closing ```
          .replace(/,(\s*[}\]])/g, '$1')  // Remove trailing commas
          .trim();
        
        functions.logger.info("Cleaned content for parsing:", cleanedContent);
        
        // Try to parse the JSON
        parsedAnalyses = JSON.parse(cleanedContent);
        
        // Validate the response structure
        if (!Array.isArray(parsedAnalyses)) {
          throw new Error("Response is not an array");
        }

        functions.logger.info(`Received ${parsedAnalyses.length} frame analyses from OpenAI`);

        // Handle cases where we get more or fewer than 12 analyses
        if (parsedAnalyses.length > 12) {
          functions.logger.warn(`Got ${parsedAnalyses.length} analyses, trimming to 12`);
          parsedAnalyses = parsedAnalyses.slice(0, 12);
        } else if (parsedAnalyses.length < 12) {
          functions.logger.warn(`Got only ${parsedAnalyses.length} analyses, padding to 12`);
          const padding = Array(12 - parsedAnalyses.length).fill({
            description: "No analysis available",
            ingredients: [],
            tools: [],
            techniques: []
          });
          parsedAnalyses = [...parsedAnalyses, ...padding];
        }

        // Validate each analysis object and provide defaults if needed
        parsedAnalyses = parsedAnalyses.map((analysis, index) => {
          if (!analysis || typeof analysis !== 'object') {
            functions.logger.warn(`Analysis ${index} is not an object, creating default structure`);
            return {
              description: "Invalid analysis",
              ingredients: [],
              tools: [],
              techniques: []
            };
          }
          
          return {
            description: typeof analysis.description === 'string' ? analysis.description : "No description available",
            ingredients: Array.isArray(analysis.ingredients) ? analysis.ingredients : [],
            tools: Array.isArray(analysis.tools) ? analysis.tools : [],
            techniques: Array.isArray(analysis.techniques) ? analysis.techniques : []
          };
        });

      } catch (error) {
        functions.logger.error("JSON parsing error:", error);
        functions.logger.error("Failed content:", content);
        throw new Error(`Failed to parse frame analysis response: ${error.message}`);
      }

      // Map the parsed analyses to our FrameAnalysis type
      return parsedAnalyses.map((analysis, index) => ({
        timestamp: index * 5,
        description: analysis.description,
        detectedIngredients: analysis.ingredients,
        detectedTools: analysis.tools,
        detectedTechniques: analysis.techniques,
      }));

    } catch (error) {
      functions.logger.error("Error in batch frame analysis:", error);
      throw error;
    }
  }

  private async transcribeAudio(videoPath: string): Promise<string> {
    const audioPath = path.join(os.tmpdir(), "audio.mp3");
    
    functions.logger.info("Starting audio extraction for transcription");
    
    // Extract audio from video
    await new Promise((resolve, reject) => {
      ffmpeg(videoPath)
        .toFormat("mp3")
        .on("end", () => {
          functions.logger.info("Audio extraction completed successfully");
          resolve(null);
        })
        .on("error", (err) => {
          functions.logger.error("Error extracting audio:", err);
          reject(err);
        })
        .save(audioPath);
    });

    functions.logger.info("Reading audio file for transcription");
    // Create a File-like object for the audio file
    const audioFile = await fs.promises.readFile(audioPath);
    const audioBlob = new Blob([audioFile], { type: "audio/mp3" });
    const file = new File([audioBlob], "audio.mp3", { type: "audio/mp3" });

    functions.logger.info("Starting OpenAI transcription");
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

    await fs.promises.unlink(audioPath);
    functions.logger.info("Cleaned up temporary audio file");
    
    return transcription;
  }

  private async generateAnalysis(
    frameAnalyses: FrameAnalysis[],
    transcriptionText: string
  ): Promise<VideoAnalysis> {
    functions.logger.info("Starting generateAnalysis with:", {
      framesCount: frameAnalyses.length,
      transcriptionLength: transcriptionText.length,
      transcriptionPreview: transcriptionText.substring(0, 100) + "..."
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

    // Log the complete parsed analysis
    functions.logger.info("Complete parsed video analysis:", {
      summaryLength: finalAnalysis.summary.length,
      summaryContent: finalAnalysis.summary,
      transcriptionLength: finalAnalysis.transcription.length,
      transcriptionPreview: finalAnalysis.transcription.substring(0, 100) + "...",
      ingredientsCount: finalAnalysis.ingredients.length,
      toolsCount: finalAnalysis.tools.length,
      techniquesCount: finalAnalysis.techniques.length,
      stepsCount: finalAnalysis.steps.length
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
    
    const lines = stepsContent
      .split('\n')
      .map(line => line.trim())
      .filter(line => line && /^\d+\./.test(line));  // Only keep numbered lines

    functions.logger.info("Steps before processing:", {
      totalLines: lines.length,
      lines: lines
    });
    
    const processedLines = lines
      .map(line => {
        // Preserve the number but clean up the rest of the line
        const numberMatch = line.match(/^(\d+)\.\s*(.+)$/);
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
      steps: processedLines
    });
    
    return processedLines;
  }
} 