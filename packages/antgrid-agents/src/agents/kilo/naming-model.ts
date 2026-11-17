import type { NamingModelProbe } from "../types";
import { resolveOpencodeV1FamilyNamingModel, type SmallModelRules } from "../opencode/naming-model";

/**
 * Kilo 7.8.x keeps opencode's title path, probe commands and output shapes, and
 * adds one tier to `getSmallModel`: on a `kilo*` provider the model id
 * `kilo-auto/small` comes before the family search.
 *
 * Not ported: Kilo's last fallback to `kilo/kilo-auto/small` from any other
 * provider, which it takes only when the user holds Kilo credentials. A stored
 * credential is visible only in Kilo's auth store, which the bridge must not
 * read, so that case names on Kilo's own default model instead.
 */
const KILO_RULES: SmallModelRules = {
  preferredIds: (providerID) => (providerID.startsWith("kilo") ? ["kilo-auto/small"] : []),
};

export function resolveKiloNamingModel(probe: NamingModelProbe): Promise<string | undefined> {
  return resolveOpencodeV1FamilyNamingModel(probe, KILO_RULES);
}
