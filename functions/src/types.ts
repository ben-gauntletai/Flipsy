export interface VideoVector {
  id: string;
  values: number[];
  metadata: {
    userId: string;
    status: string;
    privacy: string;
    tags: string[];
    version: number;
    contentLength: number;
    hasDescription: string;
    hasAiDescription: string;
    hasTags: string;
  };
}
