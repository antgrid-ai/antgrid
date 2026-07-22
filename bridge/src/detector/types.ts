export type CandidateKind = "service" | "command";

export interface Candidate {
  kind: CandidateKind;
  name: string;
  command: string;
  description?: string;
  source: string;
  inferredPort?: number;
}

export interface DetectionResult {
  services: Candidate[];
  commands: Candidate[];
  skipped: { name: string; source: string }[];
  ports: number[];
}

export interface DetectorInput {
  cwd: string;
}

export interface Detector {
  name: string;
  detect(input: DetectorInput): Promise<DetectionResult | null>;
}
