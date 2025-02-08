export interface VideoMetadata {
  id?: string;
  userId: string;
  status: string;
  privacy: string;
  tags: string[];
  aiDescription: string;
  contentLength: number;
  hasDescription: string;
  hasAiDescription: string;
  hasTags: string;
  version: number;
  updatedAt?: string;
}

export interface SearchResultData {
  id: string;
  score: number;
  data: VideoMetadata;
  type: "semantic" | "exact";
}

export interface VideoVector {
  id: string;
  values: number[];
  metadata: VideoMetadata;
}

export interface SearchResponse {
  query: string;
  results: SearchResultData[];
}
