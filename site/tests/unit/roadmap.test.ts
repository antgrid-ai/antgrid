import { describe, expect, test } from "bun:test";
import { groupRoadmap, LAST_REVIEWED, ROADMAP, type RoadmapEntry } from "../../src/data/roadmap";

const details = { id: "feature", title: "Feature", description: "Benefit", area: "App", update: "Update", updatedAt: "2026-10-01" };

describe("roadmap", () => {
  test("groups in editorial order, keeping awaiting release in Now and preserving active file order", () => {
    const entries: RoadmapEntry[] = [
      { ...details, id: "planned", status: "next" },
      { ...details, id: "ready", status: "awaiting-release" },
      { ...details, id: "idea", status: "exploring" },
      { ...details, id: "working", status: "now" },
      { ...details, id: "released", status: "shipped", releaseUrl: "https://example.com/releases/1" },
    ];
    const groups = groupRoadmap(entries);
    expect(groups.map((group) => group.title)).toEqual(["Now", "Next", "Exploring", "Recently shipped"]);
    expect(groups[0].entries.map((entry) => entry.id)).toEqual(["ready", "working"]);
    expect(groupRoadmap([])).toEqual([]);
    expect(groupRoadmap(entries.slice(0, 1)).map((group) => group.id)).toEqual(["next"]);
  });

  test("shows only the newest five shipped items without dropping source records", () => {
    const entries: RoadmapEntry[] = Array.from({ length: 7 }, (_, i) => ({
      ...details, id: `feature-${i}`, status: "shipped", updatedAt: `2026-10-0${i + 1}`, releaseUrl: `https://example.com/releases/${i}`,
    }));
    expect(groupRoadmap(entries)[0].entries.map((entry) => entry.id)).toEqual(["feature-6", "feature-5", "feature-4", "feature-3", "feature-2"]);
    expect(entries).toHaveLength(7);
    expect(entries[0].id).toBe("feature-0");
  });

  test("shipped entries require a release link in the authoring type", () => {
    // @ts-expect-error Shipment must point to a published release.
    const missingRelease: RoadmapEntry = { ...details, status: "shipped" };
    const shipped: RoadmapEntry = { ...details, status: "shipped", releaseUrl: "https://example.com/releases/1" };
    expect(shipped.releaseUrl).toMatch(/^https:\/\//);
    expect(missingRelease.status).toBe("shipped");
  });

  test("committed entries have unique stable anchors, valid dates and published links when shipped", () => {
    expect(new Set(ROADMAP.map((entry) => entry.id)).size).toBe(ROADMAP.length);
    for (const entry of ROADMAP) {
      expect(entry.id).toMatch(/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/);
      expect(new Date(entry.updatedAt).toISOString().slice(0, 10)).toBe(entry.updatedAt);
      expect(entry.updatedAt <= LAST_REVIEWED).toBe(true);
      if (entry.status === "shipped") expect(new URL(entry.releaseUrl).protocol).toBe("https:");
    }
    expect(ROADMAP.find((entry) => entry.id === "cross-agent-cross-machine-memory")?.status).toBe("next");
  });
});
