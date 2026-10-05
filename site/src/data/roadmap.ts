type RoadmapDetails = {
  id: string;
  title: string;
  description: string;
  area: string;
  update: string;
  updatedAt: string;
  discussionUrl?: string;
};

export type RoadmapEntry = RoadmapDetails & (
  | { status: "now" | "next" | "exploring"; releaseUrl?: never }
  | { status: "done"; releaseUrl?: string }
);

// Review dates record an editorial check, never a build timestamp.
export const LAST_REVIEWED = "2026-10-05";

export const ROADMAP: readonly RoadmapEntry[] = [
  {
    id: "scheduler",
    title: "Scheduled agent sessions",
    description: "Run recurring prompts on your desktop and manage schedules from connected devices.",
    area: "Agent sessions",
    status: "now",
    update: "Agreed specification: recurring prompts with a persistent workspace owned by each schedule.",
    updatedAt: "2026-10-05",
    discussionUrl: "https://github.com/antgrid-ai/antgrid/blob/main/docs/specs/scheduler.md",
  },
  {
    id: "public-roadmap",
    title: "Public roadmap",
    description: "Follow what Antgrid is building and what is done.",
    area: "Website",
    status: "done",
    update: "Completed: a public roadmap with a file-based maintenance workflow.",
    updatedAt: "2026-10-05",
    discussionUrl: "https://github.com/antgrid-ai/antgrid/pull/211",
  },
  {
    id: "tasks",
    title: "Tasks",
    description: "Manage tasks across projects and launch work from connected repositories.",
    area: "Projects & tasks",
    status: "now",
    update: "Cross-project task navigation and launching work from connected repositories are in an open implementation PR.",
    updatedAt: "2026-10-05",
    discussionUrl: "https://github.com/antgrid-ai/antgrid/pull/171",
  },
  {
    id: "native-app-preview",
    title: "Native app preview",
    description: "View native application windows inside Antgrid’s previewer.",
    area: "Preview · Desktop",
    status: "now",
    update: "Window streaming and remote input are implemented on a feature branch; platform integration remains in progress.",
    updatedAt: "2026-10-05",
  },
  {
    id: "voice-input",
    title: "Voice input",
    description: "Dictate instructions to agents.",
    area: "Agent input",
    status: "now",
    update: "On-device dictation for Windows and Linux is on a feature branch. Android recognition and warm-up work are still being verified.",
    updatedAt: "2026-10-05",
  },
  {
    id: "cross-agent-cross-machine-memory",
    title: "Cross-agent and cross-machine memory",
    description: "Carry useful project context across agents and machines so future sessions can build on earlier work.",
    area: "Project context",
    status: "next",
    update: "Planned as a shared-context capability across agents and machines.",
    updatedAt: "2026-10-05",
  },
];

export function groupRoadmap(entries: readonly RoadmapEntry[]) {
  return [
    { id: "now", title: "Now", description: "Work in progress.", entries: entries.filter((entry) => entry.status === "now") },
    { id: "next", title: "Next", description: "Planned work.", entries: entries.filter((entry) => entry.status === "next") },
    { id: "exploring", title: "Exploring", description: "Ideas under consideration, not commitments.", entries: entries.filter((entry) => entry.status === "exploring") },
    { id: "done", title: "Done", description: "The latest completed features.", entries: entries.filter((entry) => entry.status === "done").sort((a, b) => b.updatedAt.localeCompare(a.updatedAt)).slice(0, 5) },
  ].filter((group) => group.entries.length > 0);
}

export function formatRoadmapDate(date: string) {
  return new Date(`${date}T00:00:00Z`).toLocaleDateString("en-GB", {
    day: "numeric", month: "short", year: "numeric", timeZone: "UTC",
  });
}
