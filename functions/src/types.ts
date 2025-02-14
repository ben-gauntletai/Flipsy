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
  summary?: string;
  transcription?: string;
  ingredients?: string[];
  tools?: string[];
  techniques?: string[];
  steps?: string[];
  updatedAt?: string;
  createdAt?: string;
  duration?: number;
  resolution?: string;
  fileSize?: number;
  fileType?: string;
  thumbnailUrl?: string;
  hasIngredients?: string;
  hasTools?: string;
  hasTechniques?: string;
  searchableText?: string;
  lastIndexed?: string;
  processingStatus?: 'pending' | 'processing' | 'completed' | 'failed';
  processingError?: string;
  processingStartedAt?: string;
  processingCompletedAt?: string;
  schemaVersion?: number;
  viewCount?: number;
  likeCount?: number;
  commentCount?: number;
  shareCount?: number;
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

export interface VideoAnalysis {
  frames: any[];
  transcription: string;
  transcriptionSegments: Array<{
    start: number;
    end: number;
    text: string;
  }>;
  summary: string;
  ingredients: string[];
  tools: string[];
  techniques: string[];
  steps: string[];
}

// Recipe Substitution Types
export interface SubstitutionHistoryItem {
  selected: string;
  history?: string[];
}

export interface SubstitutionData {
  history: (string | SubstitutionHistoryItem)[];
  selected: string | SubstitutionHistoryItem;
}

export interface SubstitutionRequest {
  ingredients: string[];
  dietaryTags: string[];
  existingSubstitutions?: { [key: string]: SubstitutionData };
  recipeDescription?: string;
  userId: string;
  videoId: string;
}

export interface SubstitutionResponse {
  substitutions: { [key: string]: string };
  appliedPreferences: string[];
  savedToFirestore: boolean;
}

export interface RecipeContext {
  description?: string;
  allIngredients: string[];
  steps: string[];
}

export interface SubstitutionHistory {
  history: string[];
  selected: string;
  timestamp: FirebaseFirestore.Timestamp;
}

export interface StoredSubstitutions {
  ingredients: Record<string, SubstitutionHistory>;
  appliedPreferences: string[];
  updatedAt: FirebaseFirestore.Timestamp;
}
