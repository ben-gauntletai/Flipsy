import * as functions from "firebase-functions";
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

  constructor() {
    this.openai = new OpenAI({
      apiKey: process.env.OPENAI_API_KEY,
    });
    this.storage = new Storage();
  }

  async processVideo(videoUrl: string, videoId: string): Promise<VideoAnalysis> {
    try {
      functions.logger.info(`Starting video processing for ${videoId}`);
      
      // Download video to temp directory
      const tempFilePath = path.join(os.tmpdir(), `${videoId}.mp4`);
      await this.downloadVideo(videoUrl, tempFilePath);

      // Extract frames
      functions.logger.info("Extracting frames...");
      const frameFiles = await this.extractFrames(tempFilePath, videoId);
      
      // Analyze frames with GPT-4 Vision
      functions.logger.info("Analyzing frames...");
      const frameAnalyses = await this.analyzeFrames(frameFiles);

      // Transcribe audio
      functions.logger.info("Transcribing audio...");
      const transcription = await this.transcribeAudio(tempFilePath);

      // Generate comprehensive analysis
      functions.logger.info("Generating comprehensive analysis...");
      const analysis = await this.generateAnalysis(frameAnalyses, transcription);

      // Clean up temporary files
      await this.cleanup([tempFilePath, ...frameFiles]);

      return analysis;
    } catch (error) {
      functions.logger.error("Error processing video:", error);
      throw error;
    }
  }

  private async downloadVideo(url: string, destPath: string): Promise<void> {
    const bucket = this.storage.bucket(url.split("/")[2]);
    const file = bucket.file(url.split("/").slice(3).join("/"));
    await file.download({ destination: destPath });
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
    // Implement parsing logic for GPT-4 Vision response
    // This is a simplified version - enhance based on actual response format
    return {
      timestamp: frameIndex * 5, // Assuming 5-second intervals
      description: content,
      detectedIngredients: [],
      detectedTools: [],
      detectedTechniques: [],
    };
  }

  private parseAnalysisResponse(content: string): VideoAnalysis {
    // Implement parsing logic for final analysis
    // This is a simplified version - enhance based on actual response format
    return {
      frames: [],
      transcription: "",
      summary: "",
      ingredients: [],
      tools: [],
      techniques: [],
      steps: [],
    };
  }

  private async cleanup(files: string[]): Promise<void> {
    await Promise.all(files.map((file) => fs.promises.unlink(file)));
  }
} 