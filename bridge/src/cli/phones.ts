import type { PairedPhonesStore, PairedPhone } from "../paired-phones";

/** Resolves a path/label/projectId against the host's known catalog.
 *  Returns the exact projectId, or null on any miss (fail-closed). May be
 *  async (the index.ts resolver hits the loopback control plane). */
export interface CatalogResolver {
  resolve(pathOrLabel: string): string | null | Promise<string | null>;
}

/** Find a phone by pubkey, deviceId, or label. Returns null if 0 or >1 match. */
function findPhone(store: PairedPhonesStore, ref: string): PairedPhone | null {
  const phones = store.list();
  const matches = phones.filter(
    (p) => p.phonePubkey === ref || p.phoneDeviceId === ref || p.label === ref,
  );
  return matches.length === 1 ? matches[0] : null;
}

export function phonesList(store: PairedPhonesStore): number {
  for (const p of store.list()) {
    const allowed = p.allowedProjects.length ? p.allowedProjects.join(", ") : "(none)";
    // Rows are read back without field validation, so a hand-edited file can
    // omit lastSeenAt — print "unknown", never the string "undefined".
    const lastSeen = p.lastSeenAt || "unknown";
    console.log(`${p.label ?? p.phoneDeviceId}  [${p.phoneDeviceId}]  last seen: ${lastSeen}  allowed: ${allowed}`);
  }
  return 0;
}

export async function phonesAllow(
  store: PairedPhonesStore,
  catalog: CatalogResolver,
  pathOrLabel: string,
  phoneRef: string,
): Promise<number> {
  const phone = findPhone(store, phoneRef);
  if (!phone) { console.error(`phone not found (or ambiguous): ${phoneRef}`); return 2; }
  const projectId = await catalog.resolve(pathOrLabel);
  if (!projectId) {
    console.error(`no known project matches "${pathOrLabel}". Open it once, then retry. Nothing was granted.`);
    return 3;
  }
  store.allowProject(phone.phonePubkey, projectId);
  console.log(`allowed ${phone.label ?? phone.phoneDeviceId} → ${projectId}`);
  return 0;
}

export async function phonesDeny(
  store: PairedPhonesStore,
  catalog: CatalogResolver,
  pathOrLabel: string,
  phoneRef: string,
): Promise<number> {
  const phone = findPhone(store, phoneRef);
  if (!phone) { console.error(`phone not found (or ambiguous): ${phoneRef}`); return 2; }
  // Resolve the same way `allow` does, so denying by the path/label that was
  // granted maps to the same projectId. Without this, deny takes the ref
  // verbatim and silently no-ops when allow had stored a resolved id.
  const projectId = await catalog.resolve(pathOrLabel);
  if (!projectId) {
    console.error(`no known project matches "${pathOrLabel}". Nothing was revoked.`);
    return 3;
  }
  const removed = store.denyProject(phone.phonePubkey, projectId);
  if (!removed) {
    console.error(`${phone.label ?? phone.phoneDeviceId} was not allowed → ${projectId} (no change)`);
    return 4;
  }
  console.log(`denied ${phone.label ?? phone.phoneDeviceId} → ${projectId}`);
  return 0;
}

export function phonesRemove(store: PairedPhonesStore, phoneRef: string): number {
  const phone = findPhone(store, phoneRef);
  if (!phone) { console.error(`phone not found (or ambiguous): ${phoneRef}`); return 2; }
  store.remove(phone.phonePubkey);
  console.log(`removed ${phone.label ?? phone.phoneDeviceId}`);
  return 0;
}
