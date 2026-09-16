import { HostServer, type HostServerOptions } from "../src/host-server";
import { RelayClient } from "../src/relay-client";

/** These unit tests inject plaintext sessions to exercise host policy. Native
 * enrollment and real E2E belong to the separate host transport smoke gate. */
export function createHostPolicyFixture(options: HostServerOptions): HostServer {
  return new HostServer({
    relayClientFactory: (opts) => new RelayClient(opts),
    ...options,
  });
}
