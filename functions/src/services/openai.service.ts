import OpenAI from "openai";
import * as functions from "firebase-functions";

export class OpenAIService {
  private openai: OpenAI;

  constructor() {
    this.openai = new OpenAI({
      apiKey: process.env.OPENAI_API_KEY,
    });
  }

  async generateEmbedding(text: string): Promise<number[]> {
    try {
      const response = await this.openai.embeddings.create({
        model: "text-embedding-3-large",
        input: text,
      });

      if (!response.data[0]?.embedding) {
        throw new Error("No embedding generated");
      }

      return response.data[0].embedding;
    } catch (error) {
      functions.logger.error("Error generating embedding:", error);
      throw error;
    }
  }
}
