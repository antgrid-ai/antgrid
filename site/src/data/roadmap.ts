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
export const LAST_REVIEWED = "2026-10-08";

export const ROADMAP: readonly RoadmapEntry[] = [
  {
    id: "agent-scheduling",
    title: "Agents can schedule work",
    description: "Ask the agent you are working with to set up a schedule instead of creating it by hand.",
    area: "Agent sessions",
    status: "done",
    update: "Completed: Antgrid MCP tools that let an agent list, create, change, pause, delete and run schedules for its own project, never with more approval freedom than its own session has. Sessions launched by a schedule can only read schedules.",
    updatedAt: "2026-10-08",
  },
  {
    id: "one-off-schedules",
    title: "One-off schedules",
    description: "Run a prompt once at a chosen time, such as tomorrow at 9.",
    area: "Agent sessions",
    status: "done",
    update: "Completed: a Once option in the schedule editor and for agents, with catch-up when the desktop was closed at the chosen time and a clear record of how each one-off ended.",
    updatedAt: "2026-10-08",
  },
  {
    id: "scheduler-catch-up",
    title: "Scheduler catch-up",
    description: "Run the latest missed occurrence when your desktop comes back, instead of silently skipping it.",
    area: "Agent sessions",
    status: "done",
    update: "Completed: a per-schedule choice to run the latest missed occurrence or skip missed runs, one consolidated record for earlier misses, and schedules that keep running after a phone signs out.",
    updatedAt: "2026-10-08",
  },
  {
    id: "scheduler",
    title: "Scheduled agent sessions",
    description: "Run recurring prompts on your desktop and manage schedules from connected devices.",
    area: "Agent sessions",
    status: "done",
    update: "Completed: local and remote schedule management, retained editing drafts, actionable run history, and recurring prompts that reuse a workspace owned by each schedule.",
    updatedAt: "2026-10-05",
    discussionUrl: "https://github.com/antgrid-ai/antgrid/pull/213",
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
