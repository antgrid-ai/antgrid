// The marketing site is a separate deploy; these public URLs are the contract.
// Keep in lockstep with site/src/config.ts links.download / links.getStarted.
const SITE_DOWNLOAD_URL = "https://antgrid.ai/#download";
const SITE_GET_STARTED_URL = "https://antgrid.ai/get-started";

export function DownloadCard() {
  return (
    <div class="card bg-base-100 border border-base-300 mt-6">
      <div class="card-body">
        <div class="flex items-start justify-between gap-6 flex-wrap">
          <div class="flex-1 min-w-0">
            <h2 class="card-title font-mono text-lg">Download the desktop app</h2>
            <p class="text-sm text-base-content/70 mt-1 max-w-md">
              Your coding agents run inside the Antgrid desktop app on your
              computer. Install it and sign in with this account — your machine
              shows up here automatically, no pairing step.
            </p>
          </div>
          <div class="flex items-center gap-2">
            <a
              class="btn btn-primary btn-sm font-mono"
              href={SITE_DOWNLOAD_URL}
              target="_blank"
              rel="noopener"
            >
              Download
            </a>
            <a
              class="btn btn-ghost btn-sm font-mono"
              href={SITE_GET_STARTED_URL}
              target="_blank"
              rel="noopener"
            >
              Setup guide
            </a>
          </div>
        </div>
      </div>
    </div>
  );
}
