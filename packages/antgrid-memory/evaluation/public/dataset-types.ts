// SPDX-License-Identifier: MPL-2.0

export type PublicDocument = {
  id: string;
  content: string;
  title?: string;
  description?: string;
  sourceIds: string[];
};

export type PublicQuery = {
  id: string;
  text: string;
  relevantIds: string[];
  category: string;
  questionDate?: string;
  answer?: unknown;
  unanswerable?: boolean;
};

export type PublicGroup = {
  id: string;
  documents: PublicDocument[];
  queries: PublicQuery[];
};

export type DatasetManifest = {
  dataset: string;
  variant: string;
  sourceUrl: string;
  revision: string;
  sha256: string;
  sourceBytes: number;
  preparedAt: string;
  groups: number;
  documents: number;
  queries: number;
  answerableQueries: number;
  unanswerableQueries: number;
  chunking: { maxBytes: number; version: string };
};
