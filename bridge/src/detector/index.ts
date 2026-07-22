import type { DetectionResult, Detector } from "./types";
import { nodeDetector } from "./node";
import { rustDetector } from "./rust";
import { goDetector } from "./go";
import { pythonDetector } from "./python";
import { rubyDetector } from "./ruby";
import { flutterDetector } from "./flutter";
import { dockerDetector } from "./docker";
import { makefileDetector } from "./makefile";

const DETECTORS: Detector[] = [
  nodeDetector, rustDetector, goDetector, pythonDetector,
  rubyDetector, flutterDetector, dockerDetector, makefileDetector,
];

export async function runDetectors(cwd: string): Promise<DetectionResult> {
  const merged: DetectionResult = { services: [], commands: [], skipped: [], ports: [] };
  for (const d of DETECTORS) {
    const r = await d.detect({ cwd });
    if (!r) continue;
    merged.services.push(...r.services);
    merged.commands.push(...r.commands);
    merged.skipped.push(...r.skipped);
    for (const p of r.ports) if (!merged.ports.includes(p)) merged.ports.push(p);
  }
  return merged;
}

export type { Candidate, DetectionResult } from "./types";
