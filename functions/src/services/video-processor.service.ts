import * as functions from "firebase-functions/v2";
import * as ffmpeg from "fluent-ffmpeg";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { Storage } from "@google-cloud/storage";
import OpenAI from "openai";

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
    let frameFiles: string[] = [];
    
    try {
      functions.logger.info(`Starting video processing for ${videoId}`);
      
      // Download video to temp directory
      tempFilePath = path.join(os.tmpdir(), `video-${videoId}.mp4`);
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

      // Extract frames
      const checkTimeout = () => {
        const timeElapsed = Date.now() - startTime;
        if (timeElapsed > this.PROCESSING_TIMEOUT_MS) {
          throw new Error("Processing timeout exceeded");
        }
      };

      checkTimeout();
      functions.logger.info("Extracting frames...");
      frameFiles = await this.extractFrames(tempFilePath, videoId);
      
      // Analyze frames
      checkTimeout();
      functions.logger.info("Analyzing frames...");
      const frameAnalyses = await this.analyzeFrames(frameFiles);

      // Transcribe audio
      checkTimeout();
      functions.logger.info("Transcribing audio...");
      const transcription = await this.transcribeAudio(tempFilePath);

      // Generate comprehensive analysis
      checkTimeout();
      functions.logger.info("Generating comprehensive analysis...");
      const analysis = await this.generateAnalysis(frameAnalyses, transcription);

      // Clean up temporary files
      await this.cleanup([...(tempFilePath ? [tempFilePath] : []), ...frameFiles]);

      return analysis;
    } catch (error) {
      // Ensure cleanup happens even on error
      if (tempFilePath || frameFiles.length > 0) {
        try {
          await this.cleanup([...(tempFilePath ? [tempFilePath] : []), ...frameFiles]);
        } catch (cleanupError) {
          functions.logger.warn("Error during cleanup:", cleanupError);
        }
      }
      
      functions.logger.error("Error processing video:", error);
      throw error;
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

  private async extractFrames(videoPath: string, videoId: string): Promise<string[]> {
    const frameFiles: string[] = [];
    const framesDir = path.join(os.tmpdir(), videoId);
    await fs.promises.mkdir(framesDir, { recursive: true });

    return new Promise((resolve, reject) => {
      ffmpeg(videoPath)
        .on("end", () => resolve(frameFiles))
        .on("error", (err: Error) => reject(err))
        .on("progress", (progress: { frames?: number }) => {
          if (progress.frames) {
            const frameFile = path.join(framesDir, `frame-${progress.frames}.jpg`);
            frameFiles.push(frameFile);
          }
        })
        .screenshots({
          count: 12,
          folder: framesDir,
          filename: "frame-%i.jpg",
          size: "1280x720",
        });
    });
  }

  private async analyzeFrames(frameFiles: string[]): Promise<FrameAnalysis[]> {
    const analyses: FrameAnalysis[] = [];

    for (const [index, framePath] of frameFiles.entries()) {
      const imageBase64 = await fs.promises.readFile(framePath, { encoding: "base64" });
      
      const response = await this.openai.chat.completions.create({
        model: "gpt-4-vision-preview",
        messages: [
          {
            role: "user",
            content: [
              { 
                type: "text", 
                text: "Analyze this frame from a cooking video. " + 
                      "Identify ingredients, cooking tools, and techniques visible in the frame. " + 
                      "Provide a detailed description of what's happening.",
              },
              { 
                type: "image_url", 
                image_url: { 
                  url: `data:image/jpeg;base64,${imageBase64}`,
                },
              },
            ],
          },
        ],
        max_tokens: 500,
      });

      const analysis = this.parseVisionResponse(response.choices[0].message.content || "", index);
      analyses.push(analysis);
    }

    return analyses;
  }

  private async transcribeAudio(videoPath: string): Promise<string> {
    const audioPath = path.join(os.tmpdir(), "audio.mp3");
    
    // Extract audio from video
    await new Promise((resolve, reject) => {
      ffmpeg(videoPath)
        .toFormat("mp3")
        .on("end", resolve)
        .on("error", reject)
        .save(audioPath);
    });

    // Create a File-like object for the audio file
    const audioFile = await fs.promises.readFile(audioPath);
    const audioBlob = new Blob([audioFile], { type: "audio/mp3" });
    const file = new File([audioBlob], "audio.mp3", { type: "audio/mp3" });

    // Transcribe audio
    const response = await this.openai.audio.transcriptions.create({
      file,
      model: "whisper-1",
      language: "en",
    });

    await fs.promises.unlink(audioPath);
    return response.text;
  }

  private async generateAnalysis(
    frameAnalyses: FrameAnalysis[],
    transcription: string
  ): Promise<VideoAnalysis> {
    const prompt = `
      Analyze this cooking video content and create a comprehensive summary.
      Frame analyses: ${JSON.stringify(frameAnalyses)}
      Audio transcription: ${transcription}
      
      Generate a structured analysis including:
      1. Overall summary of the recipe
      2. Complete list of ingredients spotted
      3. All cooking tools used
      4. All cooking techniques demonstrated
      5. Step-by-step instructions based on the video content
    `;

    const response = await this.openai.chat.completions.create({
      model: "gpt-4-turbo-preview",
      messages: [{ role: "user", content: prompt }],
      temperature: 0.7,
      max_tokens: 1000,
    });

    return this.parseAnalysisResponse(response.choices[0].message.content || "");
  }

  private parseVisionResponse(content: string, frameIndex: number): FrameAnalysis {
    // Extract information using regex or other parsing methods
    const ingredients = content.match(/ingredients?:.*?([\w\s,]+)/i)?.[1]?.split(",").map((i) => i.trim()) || [];
    const tools = content.match(/tools?:.*?([\w\s,]+)/i)?.[1]?.split(",").map((t) => t.trim()) || [];
    const techniques = content.match(/techniques?:.*?([\w\s,]+)/i)?.[1]?.split(",").map((t) => t.trim()) || [];
    
    return {
        timestamp: frameIndex * 5,
        description: content,
        detectedIngredients: ingredients,
        detectedTools: tools,
        detectedTechniques: techniques,
    };
  }

  private parseAnalysisResponse(content: string): VideoAnalysis {
    const sections = content.split(/\n\d+\./);
    
    return {
        frames: [],
        transcription: "",
        summary: sections[1]?.trim() || "",
        ingredients: sections[2]?.split(",").map((i) => i.trim()) || [],
        tools: sections[3]?.split(",").map((t) => t.trim()) || [],
        techniques: sections[4]?.split(",").map((t) => t.trim()) || [],
        steps: sections[5]?.split("\n").map((s) => s.trim()).filter(Boolean) || [],
    };
  }

  private async cleanup(files: string[]): Promise<void> {
    await Promise.all(files.map((file) => fs.promises.unlink(file)));
  }
} 