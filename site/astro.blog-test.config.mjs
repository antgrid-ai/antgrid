import config from "./astro.config.mjs";

// Fixture builds must never replace the artifact Azure deploys.
const scenario = process.env.ANTGRID_BLOG_SCENARIO ?? "blog";
if (!["blog", "invalid", "conflicting"].includes(scenario)) throw new Error(`Unknown blog fixture scenario: ${scenario}`);
process.env.ANTGRID_BLOG_FIXTURES = `./tests/fixtures/${scenario}`;
export default { ...config, outDir: `./.test-output/${scenario}`, cacheDir: `./.test-cache/${scenario}` };
