// The relay envelope schemas now live in the shared `antgrid-wire` package so
// the bridge and relay validate against a single source of truth. This module
// re-exports that surface to keep existing import paths (`./protocol`) stable.
export * from "antgrid-wire";
