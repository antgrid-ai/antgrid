import type { HandoffEventsFn } from "../handoff/events";
import { opencodeFamilyEvents } from "../opencode/handoff-events";

/** Kilo is an opencode fork whose snapshot has the same document shape. */
export const kiloHandoffEvents: HandoffEventsFn = opencodeFamilyEvents;
