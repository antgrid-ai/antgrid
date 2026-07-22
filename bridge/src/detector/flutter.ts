import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import type { Detector } from "./types";

export const flutterDetector: Detector = {
  name: "flutter",
  async detect({ cwd }) {
    const pub = join(cwd, "pubspec.yaml");
    if (!existsSync(pub)) return null;
    const content = readFileSync(pub, "utf8");
    if (!/flutter:\s*$|sdk:\s*flutter/m.test(content)) return null;

    return {
      services: [
        { kind: "service", name: "run", command: "flutter run", source: "pubspec.yaml" },
      ],
      commands: [
        { kind: "command", name: "test",      command: "flutter test",      source: "pubspec.yaml" },
        { kind: "command", name: "build",     command: "flutter build apk", source: "pubspec.yaml" },
        { kind: "command", name: "analyze",   command: "flutter analyze",   source: "pubspec.yaml" },
      ],
      skipped: [],
      ports: [],
    };
  },
};
