import { RecordMetadata } from "@pinecone-database/pinecone";

export interface VideoMetadata extends RecordMetadata {
  userId: string;
  status: string;
  privacy: string;
  tags: string[];
  aiDescription?: string;
  version: number;
  contentLength: number;
  hasDescription: string;
  hasAiDescription: string;
  hasTags: string;
  type?: string;
  videoId?: string;
  ingredients?: string[];
  tools?: string[];
  techniques?: string[];
  updatedAt?: string;
}

export interface VideoVector {
  id: string;
  values: number[];
  metadata: VideoMetadata;
}

export interface SearchResult {
  id: string;
  score: number;
  metadata: VideoMetadata;
  type: "semantic" | "exact";
}

export interface SearchResultData {
  results: SearchResult[];
}

export interface SearchResponse {
  query: string;
  results: SearchResultData[];
}
