import * as functions from "firebase-functions/v2";
import * as ffmpeg from "fluent-ffmpeg";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { Storage } from "@google-cloud/storage";
import OpenAI from "openai";
import { ChatCompletionContentPartImage, ChatCompletionContentPartText } from "openai/resources/chat/completions";

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
      
      // Extract the file path from the URL
      const filePathMatch = url.match(/\/v0\/b\/[^/]+\/o\/(.+?)\?/);
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
    transcription: string
  ): Promise<VideoAnalysis> {
    functions.logger.info("Starting generateAnalysis with:", {
      framesCount: frameAnalyses.length,
      transcriptionLength: transcription.length,
      transcriptionPreview: transcription.substring(0, 100) + "..."
    });

    const prompt = `
      Analyze this cooking video content and create a structured analysis.
      You have frame-by-frame analyses and audio transcription.

      Frame Analyses: ${JSON.stringify(frameAnalyses, null, 2)}
      Audio Transcription: ${transcription}
      
      Provide your analysis in the following EXACT format, maintaining these exact headings:

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
      List the complete recipe steps in order, one per line:
      1. First step
      2. Second step
      etc.

      IMPORTANT:
      - Do not include labels like "Tools:" or "Ingredients:" within the lists themselves
      - Keep each item concise and avoid mixing categories
      - For tools, only include physical equipment (e.g., "bowl", "whisk")
      - For techniques, only include actions (e.g., "whisking", "blending")
      - For ingredients, only include food/drink items
      - Ensure steps are complete sentences
    `;

    functions.logger.info("Sending analysis prompt to OpenAI");

    const response = await this.openai.chat.completions.create({
      model: "gpt-4o-mini",
      messages: [{ role: "user", content: prompt }],
      temperature: 0.7,
      max_tokens: 2000,
    });

    const content = response.choices[0].message.content || "";
    
    // Log the complete raw response
    functions.logger.info("Complete raw analysis response from OpenAI:", {
      fullResponse: content,
      responseLength: content.length
    });
    
    const analysis = this.parseAnalysisResponse(content);

    // Log the complete parsed analysis
    functions.logger.info("Complete parsed video analysis:", {
      summary: analysis.summary,
      ingredients: analysis.ingredients,
      tools: analysis.tools,
      techniques: analysis.techniques,
      steps: analysis.steps,
      ingredientsCount: analysis.ingredients.length,
      toolsCount: analysis.tools.length,
      techniquesCount: analysis.techniques.length,
      stepsCount: analysis.steps.length
    });

    return analysis;
  }

  private parseAnalysisResponse(content: string): VideoAnalysis {
    functions.logger.info("Starting to parse analysis response");
    
    // Helper function to extract section content
    const extractSection = (section: string, text: string): string[] => {
      const regex = new RegExp(`${section}:\\s*\\n([\\s\\S]*?)(?=\\n\\s*[A-Z]+:|$)`);
      const match = text.match(regex);
      
      if (!match) {
        functions.logger.warn(`No match found for section: ${section}`);
        return [];
      }
      
      const lines = match[1]
        .split('\n')
        .map(line => line.trim())
        .filter(line => line)  // Remove empty lines
        .map(line => {
          // Remove bullet points and numbers at the start
          return line
            .replace(/^[0-9]+\.\s*/, '')  // Remove numbered lists (e.g., "1. ")
            .replace(/^[-•]\s*/, '');      // Remove bullet points
        })
        .filter(line => line); // Remove any lines that became empty
      
      functions.logger.info(`Extracted ${lines.length} items from ${section}:`, lines);
      return lines;
    };

    // Extract summary differently since it's a paragraph
    const summaryMatch = content.match(/SUMMARY:\s*\n([\s\S]*?)(?=\n\s*[A-Z]+:|$)/);
    const summary = summaryMatch ? summaryMatch[1].trim() : '';

    // Extract lists
    const ingredients = extractSection('INGREDIENTS', content);
    const tools = extractSection('TOOLS', content);
    const techniques = extractSection('TECHNIQUES', content);
    const steps = extractSection('STEPS', content);

    // Log detailed extraction results
    functions.logger.info("Detailed section extraction results:", {
      summary: {
        text: summary,
        length: summary.length
      },
      ingredients: {
        items: ingredients,
        count: ingredients.length
      },
      tools: {
        items: tools,
        count: tools.length
      },
      techniques: {
        items: techniques,
        count: techniques.length
      },
      steps: {
        items: steps,
        count: steps.length
      }
    });

    const analysis = {
      frames: [],  // This is handled elsewhere
      transcription: "", // This is handled elsewhere
      summary,
      ingredients,
      tools,
      techniques,
      steps,
    };

    functions.logger.info("Final parsed analysis object:", analysis);

    return analysis;
  }
} 