import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import type { Detector, Candidate } from "./types";

export const rubyDetector: Detector = {
  name: "ruby",
  async detect({ cwd }) {
    const gemfile = join(cwd, "Gemfile");
    if (!existsSync(gemfile)) return null;
    const content = readFileSync(gemfile, "utf8");
    const isRails = /\bgem\s+['"]rails['"]/.test(content);

    const services: Candidate[] = [];
    const commands: Candidate[] = [];

    if (isRails) {
      services.push({ kind: "service", name: "server", command: "bundle exec rails server", source: "Gemfile" });
      commands.push(
        { kind: "command", name: "rspec",   command: "bundle exec rspec",            source: "Gemfile" },
        { kind: "command", name: "migrate", command: "bundle exec rails db:migrate", source: "Gemfile" },
      );
    } else {
      commands.push({ kind: "command", name: "rspec", command: "bundle exec rspec", source: "Gemfile" });
    }

    return { services, commands, skipped: [], ports: isRails ? [3000] : [] };
  },
};
