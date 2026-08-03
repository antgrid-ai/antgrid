export interface GitBranchCatalog {
  isRepository: boolean;
  current: string | null;
  branches: string[];
}

export class GitHelperError extends Error {
  constructor(
    public readonly code: "NOT_GIT_REPOSITORY" | "UNKNOWN_BRANCH" | "CHECKOUT_FAILED",
    message: string,
  ) {
    super(message);
    this.name = "GitHelperError";
  }
}

export async function listLocalBranches(projectPath: string): Promise<GitBranchCatalog> {
  // Check if inside work tree
  const revParseProc = Bun.spawn(["git", "rev-parse", "--is-inside-work-tree"], {
    cwd: projectPath,
    stdout: "pipe",
    stderr: "pipe",
  });
  const revParseExit = await revParseProc.exited;
  if (revParseExit !== 0) {
    return {
      isRepository: false,
      current: null,
      branches: [],
    };
  }

  // Concurrent reads
  const currentProc = Bun.spawn(["git", "branch", "--show-current"], {
    cwd: projectPath,
    stdout: "pipe",
    stderr: "pipe",
  });
  const refsProc = Bun.spawn(["git", "for-each-ref", "--format=%(refname:short)", "refs/heads"], {
    cwd: projectPath,
    stdout: "pipe",
    stderr: "pipe",
  });

  const [currentText, refsText] = await Promise.all([
    new Response(currentProc.stdout).text(),
    new Response(refsProc.stdout).text(),
  ]);

  await Promise.all([currentProc.exited, refsProc.exited]);

  const rawCurrent = currentText.trim();
  const current = rawCurrent.length > 0 ? rawCurrent : null;

  const rawBranches = refsText
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0);

  // Deduplicate preserving order
  const uniqueBranches = Array.from(new Set(rawBranches));

  // Sort: current first if present, remainder sorted case-insensitively with exact string tie-breaker
  const otherBranches = uniqueBranches.filter((b) => b !== current);
  otherBranches.sort((a, b) => {
    const lowerA = a.toLowerCase();
    const lowerB = b.toLowerCase();
    if (lowerA < lowerB) return -1;
    if (lowerA > lowerB) return 1;
    if (a < b) return -1;
    if (a > b) return 1;
    return 0;
  });

  const finalBranches: string[] = [];
  if (current && uniqueBranches.includes(current)) {
    finalBranches.push(current);
  }
  finalBranches.push(...otherBranches);

  return {
    isRepository: true,
    current,
    branches: finalBranches,
  };
}

export async function checkoutLocalBranch(
  projectPath: string,
  branch: string,
): Promise<{ current: string }> {
  const catalog = await listLocalBranches(projectPath);
  if (!catalog.isRepository) {
    throw new GitHelperError("NOT_GIT_REPOSITORY", "Not a Git repository");
  }

  if (!catalog.branches.includes(branch)) {
    throw new GitHelperError("UNKNOWN_BRANCH", `Branch '${branch}' does not exist`);
  }

  if (catalog.current === branch) {
    return { current: branch };
  }

  const proc = Bun.spawn(["git", "switch", branch], {
    cwd: projectPath,
    stdout: "pipe",
    stderr: "pipe",
  });

  const stderr = (await new Response(proc.stderr).text()).trim();
  const exitCode = await proc.exited;

  if (exitCode !== 0) {
    throw new GitHelperError("CHECKOUT_FAILED", stderr || `git switch ${branch} failed with exit code ${exitCode}`);
  }

  // Re-verify current branch
  const verifyProc = Bun.spawn(["git", "branch", "--show-current"], {
    cwd: projectPath,
    stdout: "pipe",
    stderr: "pipe",
  });
  const verifyText = (await new Response(verifyProc.stdout).text()).trim();
  await verifyProc.exited;

  if (verifyText !== branch) {
    throw new GitHelperError("CHECKOUT_FAILED", `Verification failed: expected branch '${branch}', got '${verifyText}'`);
  }

  return { current: branch };
}
