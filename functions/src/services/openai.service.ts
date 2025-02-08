import OpenAI from "openai";
import * as functions from "firebase-functions";

/**
 * Service class for interacting with OpenAI API.
 */
export class OpenAIService {
  /** OpenAI client instance. */
  private openai: OpenAI;

  /**
   * Initialize OpenAI service with API credentials from environment.
   */
  constructor() {
    this.openai = new OpenAI({
      apiKey: process.env.OPENAI_API_KEY,
    });
  }

  /**
   * Generate an embedding vector for the given text.
   * @param {string} text The input text to generate embedding for
   * @return {Promise<number[]>} The generated embedding vector
   * @throws {Error} When embedding generation fails or returns no result
   */
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
