// The @opencode-ai/plugin package is supplied by opencode's own runtime at load
// time (the plugin executes inside opencode, not the bridge), so it is not a
// bridge dependency. Declaring the slice of its type we use keeps `tsc` green for
// tests that import plugin/opencode/plugin.ts without vendoring the SDK.
declare module "@opencode-ai/plugin" {
  export type Plugin = (input?: unknown) => Promise<{
    event?: (input: { event: any }) => unknown | Promise<unknown>;
  }>;
}
