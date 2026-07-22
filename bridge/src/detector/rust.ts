import { existsSync } from "node:fs";
import { join } from "node:path";
import type { Detector, Candidate } from "./types";

export const rustDetector: Detector = {
  name: "rust",
  async detect({ cwd }) {
    if (!existsSync(join(cwd, "Cargo.toml"))) return null;

    const services: Candidate[] = [
      { kind: "service", name: "run", command: "cargo run", source: "Cargo.toml" },
    ];
    const commands: Candidate[] = [
      { kind: "command", name: "test",   command: "cargo test",   source: "Cargo.toml" },
      { kind: "command", name: "build",  command: "cargo build",  source: "Cargo.toml" },
      { kind: "command", name: "check",  command: "cargo check",  source: "Cargo.toml" },
      { kind: "command", name: "clippy", command: "cargo clippy", source: "Cargo.toml" },
      { kind: "command", name: "fmt",    command: "cargo fmt",    source: "Cargo.toml" },
    ];

    return { services, commands, skipped: [], ports: [] };
  },
};
