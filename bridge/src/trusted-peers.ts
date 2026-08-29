import { readFileSync } from "node:fs";
import { atomicWriteFile } from "./discovery";
import { logger } from "./logger";
const log = logger.child({ component: "trusted-peers" });

export interface TrustedPeer {
  deviceId: string;
  ed25519Pub: string;
}

export interface TrustedPeersOpts {
  licenseApiUrl: string;
  getToken: () => string;
  /** Durable cache, e.g. `<abDir>/trusted-peers.json`. */
  filePath: string;
  fetchFn?: typeof fetch;
  missRefreshCooldownMs?: number;
}

/**
 * Account device inventory as the E2E-admission trust source.
 * Sync lookup from an in-memory map backed by a durable disk cache so
 * handleClientHello stays synchronous; an unknown identity triggers a throttled
 * background refresh and relies on the phone's handshake retransmit landing on
 * the warmed cache — same self-heal shape as the relay's JWKS kid-miss cooldown.
 */
export class TrustedPeersProvider {
  private byDeviceId = new Map<string, string>();
  private lastMissRefreshAt = 0;
  private inflight: Promise<void> | null = null;

  constructor(private readonly opts: TrustedPeersOpts) {
    this.loadFromDisk();
  }

  lookup(deviceId: string): string | undefined {
    return this.byDeviceId.get(deviceId);
  }

  /** Unknown identity seen — refresh at most once per cooldown window. */
  noteMiss(): void {
    const cooldown = this.opts.missRefreshCooldownMs ?? 60_000;
    if (Date.now() - this.lastMissRefreshAt < cooldown) return;
    this.lastMissRefreshAt = Date.now();
    void this.refresh();
  }

  /** Single-flight fetch + persist; a failed fetch keeps the old cache. */
  refresh(): Promise<void> {
    if (this.inflight) return this.inflight;
    this.inflight = (async () => {
      const f = this.opts.fetchFn ?? fetch;
      const res = await f(`${this.opts.licenseApiUrl}/account/devices/me/peers`, {
        headers: { authorization: `Bearer ${this.opts.getToken()}` },
      });
      if (!res.ok) throw new Error(`peers fetch failed: ${res.status}`);
      const body = (await res.json()) as { devices?: TrustedPeer[] };
      if (!body.devices) return; // web not yet serving devices[] — keep cache
      this.byDeviceId = new Map(body.devices.map((d) => [d.deviceId, d.ed25519Pub]));
      this.saveToDisk(body.devices);
    })()
      .catch((err) => {
        log.warn("trusted-peers refresh failed: %s", String(err));
      })
      .finally(() => {
        this.inflight = null;
      });
    return this.inflight;
  }

  private loadFromDisk(): void {
    try {
      const devices = JSON.parse(readFileSync(this.opts.filePath, "utf8")) as TrustedPeer[];
      this.byDeviceId = new Map(devices.map((d) => [d.deviceId, d.ed25519Pub]));
    } catch {
      // First run: cache empty until the first successful refresh().
    }
  }

  private saveToDisk(devices: TrustedPeer[]): void {
    try {
      // 0o600 like every sibling store: this is the account's device inventory,
      // and the rename installs a fresh inode each time, so a mode the previous
      // file carried is not preserved.
      atomicWriteFile(this.opts.filePath, JSON.stringify(devices, null, 2), { fileMode: 0o600 });
    } catch (err) {
      log.warn("trusted-peers cache write failed: %s", String(err));
    }
  }
}
