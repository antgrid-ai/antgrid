import { execFileSync } from "node:child_process";
import { logger } from "../../host";

/**
 * True for antigravity's `agy`/`agy.EXE` shim, bare or pathful. agy.EXE is a
 * real PE binary but is deliberately routed through cmd.exe on Windows rather
 * than direct-ConPTY-spawned like other .exe agents — see the isAgy usage in
 * spawn() for why (confirmed A/B: agy launched directly, outside any
 * ConPTY-attached spawn, completes its OAuth/eligibility check fine; the
 * identical binary, same user/machine/moment, fails every outbound HTTPS call
 * with `tls: ... certificate signed by unknown authority` only when bun-pty
 * makes it the direct ConPTY child).
 */
export function isAntigravityBinary(command: string): boolean {
  return /(^|[\\/])agy(\.exe)?$/i.test(command);
}

/**
 * Warms Windows' CryptoAPI intermediate-certificate cache for agy's target
 * host before spawning it. Go's crypto/x509 on Windows verifies via
 * CertGetCertificateChain with CACHE-ONLY lookups — unlike browsers/.NET, it
 * never fetches a missing intermediate CA over the network. If the
 * intermediate for daily-cloudcode-pa.googleapis.com isn't already cached in
 * this Windows profile, agy fails outright with `certificate signed by
 * unknown authority`. Confirmed live: with SSL_CERT_* / proxy vars already
 * stripped and the env otherwise identical, a plain PowerShell request
 * (Invoke-WebRequest → .NET → SChannel, which DOES fetch-and-cache missing
 * intermediates) against the same host succeeds every time — the failure is
 * specific to Go's cache-only lookup, not the environment or network path.
 *
 * Synchronous and blocking (not fire-and-forget): agy can fire its own HTTPS
 * call within ~1-2s of spawn, faster than an async priming request reliably
 * wins the race (that's what the async version of this probe demonstrated —
 * it usually completed just AFTER agy's own failing call). The priming has
 * to land before the PTY exists, not concurrently with it. Bounded by a
 * short timeout and fails open — a network hiccup here must never block
 * opening the terminal, since agy would then just show its normal error.
 *
 * Windows' CryptoAPI intermediate cache is machine/profile-level, so one
 * successful prime serves every agy spawn for this bridge's lifetime. We
 * memoize on success to pay the (event-loop-blocking) PowerShell cost at most
 * once per process — a failed prime is NOT recorded, so a later spawn retries.
 */
let antigravityCertCachePrimed = false;
export function primeAntigravityCertCache(env: Record<string, string>): void {
  if (process.platform !== "win32" || antigravityCertCachePrimed) return;
  const script =
    "try { Invoke-WebRequest -UseBasicParsing -Uri https://daily-cloudcode-pa.googleapis.com -Method Head -TimeoutSec 4 | Out-Null; Write-Output 'CERT-CACHE-PRIME-OK' } catch { Write-Output ('CERT-CACHE-PRIME-DONE ' + $_.Exception.Message) }";
  try {
    const out = execFileSync(
      "powershell.exe",
      ["-NoProfile", "-NonInteractive", "-Command", script],
      { env, timeout: 5_000, encoding: "utf8" },
    ).trim();
    antigravityCertCachePrimed = true;
    logger.info(`antigravity cert-cache prime: ${out}`);
  } catch (e) {
    logger.warn(`antigravity cert-cache prime failed, continuing spawn anyway: ${(e as Error).message}`);
  }
}

