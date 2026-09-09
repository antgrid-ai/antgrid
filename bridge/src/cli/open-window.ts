import { existsSync } from "node:fs";

/**
 * Put a local URL in front of the operator, as its own OS window when we can.
 *
 * A capture viewer is read beside the thing it is watching — an editor, a
 * terminal, the app — so a browser TAB is the wrong container: it is buried
 * behind whatever else that window holds and it carries an address bar showing
 * a URL the page has already stripped. Chromium's `--app=` gives a real
 * standalone window with no tab strip and no omnibox, which is what was asked
 * for; every other browser gets the ordinary open and a tab, which still works.
 *
 * Nothing here is required for correctness — `--no-open` prints the URL and the
 * operator opens it however they like.
 */

/** Chromium-family binaries at their default install paths, most likely first.
 *  Forward slashes throughout: Windows accepts them and they keep this list
 *  free of escaping. */
function appModeCandidates(): string[] {
  if (process.platform === "win32") {
    const local = process.env.LOCALAPPDATA ?? "";
    const pf = process.env.ProgramFiles ?? "C:/Program Files";
    const pf86 = process.env["ProgramFiles(x86)"] ?? "C:/Program Files (x86)";
    return [
      `${pf86}/Microsoft/Edge/Application/msedge.exe`,
      `${pf}/Microsoft/Edge/Application/msedge.exe`,
      `${pf}/Google/Chrome/Application/chrome.exe`,
      `${pf86}/Google/Chrome/Application/chrome.exe`,
      ...(local ? [`${local}/Google/Chrome/Application/chrome.exe`] : []),
    ].map((p) => p.replace(/\\/g, "/"));
  }
  if (process.platform === "darwin") {
    return [
      "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
      "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
      "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
      "/Applications/Chromium.app/Contents/MacOS/Chromium",
    ];
  }
  // PATH names rather than paths: a Linux install could be a package, a snap or
  // a flatpak shim, and only the shell knows which.
  return ["google-chrome", "chromium", "chromium-browser", "microsoft-edge"]
    .map((name) => Bun.which(name))
    .filter((p): p is string => p !== null);
}

function spawnDetached(argv: string[]): boolean {
  try {
    const child = Bun.spawn(argv, { stdio: ["ignore", "ignore", "ignore"] });
    // The viewer outlives this CLI by design — the window is the session, and
    // holding the terminal open to babysit it would defeat the point.
    child.unref();
    return true;
  } catch {
    return false;
  }
}

/** The OS's own handler. On Windows that means `cmd`, so the URL is passed as a
 *  separate argv entry rather than concatenated: `start` treats an unquoted `&`
 *  as a command separator, and a fragment can carry one. */
function openWithDefault(url: string): boolean {
  if (process.platform === "win32") return spawnDetached(["cmd", "/c", "start", "", url]);
  if (process.platform === "darwin") return spawnDetached(["open", url]);
  return spawnDetached(["xdg-open", url]);
}

export type OpenResult = "window" | "browser" | "failed";

export function openStandaloneWindow(url: string): OpenResult {
  for (const bin of appModeCandidates()) {
    if (!existsSync(bin)) continue;
    if (spawnDetached([bin, `--app=${url}`])) return "window";
  }
  return openWithDefault(url) ? "browser" : "failed";
}
