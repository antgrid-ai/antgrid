import { describe, expect, test } from "bun:test";
import { groupRoadmap, LAST_REVIEWED, ROADMAP, type RoadmapEntry } from "../../src/data/roadmap";

const details = { id: "feature", title: "Feature", description: "Benefit", area: "App", update: "Update", updatedAt: "2026-10-01" };

describe("roadmap", () => {
  test("groups in editorial order, keeping completed features out of Now and preserving active file order", () => {
    const entries: RoadmapEntry[] = [
      { ...details, id: "planned", status: "next" },
      { ...details, id: "another-working", status: "now" },
      { ...details, id: "idea", status: "exploring" },
      { ...details, id: "working", status: "now" },
      { ...details, id: "completed", status: "done" },
    ];
    const groups = groupRoadmap(entries);
    expect(groups.map((group) => group.title)).toEqual(["Now", "Next", "Exploring", "Done"]);
    expect(groups[0].entries.map((entry) => entry.id)).toEqual(["another-working", "working"]);
    expect(groups[3].entries.map((entry) => entry.id)).toEqual(["completed"]);
    expect(groupRoadmap([])).toEqual([]);
    expect(groupRoadmap(entries.slice(0, 1)).map((group) => group.id)).toEqual(["next"]);
  });

  test("shows only the newest five completed items without dropping source records", () => {
    const entries: RoadmapEntry[] = Array.from({ length: 7 }, (_, i) => ({
      ...details, id: `feature-${i}`, status: "done", updatedAt: `2026-10-0${i + 1}`,
    }));
    expect(groupRoadmap(entries)[0].entries.map((entry) => entry.id)).toEqual(["feature-6", "feature-5", "feature-4", "feature-3", "feature-2"]);
    expect(entries).toHaveLength(7);
    expect(entries[0].id).toBe("feature-0");
  });

  test("completion does not require a published release, but can link one", () => {
    const completed: RoadmapEntry = { ...details, status: "done" };
    const released: RoadmapEntry = { ...details, status: "done", releaseUrl: "https://example.com/releases/1" };
    expect(groupRoadmap([completed])[0].id).toBe("done");
    expect(released.releaseUrl).toMatch(/^https:\/\//);
  });

  test("committed entries have unique stable anchors, valid dates and valid optional release links", () => {
    expect(new Set(ROADMAP.map((entry) => entry.id)).size).toBe(ROADMAP.length);
    for (const entry of ROADMAP) {
      expect(entry.id).toMatch(/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/);
      expect(new Date(entry.updatedAt).toISOString().slice(0, 10)).toBe(entry.updatedAt);
      expect(entry.updatedAt <= LAST_REVIEWED).toBe(true);
      if (entry.releaseUrl) expect(new URL(entry.releaseUrl).protocol).toBe("https:");
    }
    expect(ROADMAP.find((entry) => entry.id === "cross-agent-cross-machine-memory")?.status).toBe("next");
    expect(ROADMAP.find((entry) => entry.id === "public-roadmap")?.status).toBe("done");
  });
});
