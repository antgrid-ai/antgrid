// Bun serves `with { type: "text" }` imports as the file's contents. Declared
// here because tsc has no built-in loader for them — see src/ui/wordmark.tsx.
declare module "*.svg" {
  const contents: string;
  export default contents;
}
