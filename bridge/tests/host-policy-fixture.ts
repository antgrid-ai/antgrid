import { HostServer, type HostServerOptions } from "../src/host-server";
import { TestRemoteHostConnection } from "./test-peer-session-owner";

/** These unit tests inject plaintext sessions to exercise host policy. Native
 * enrollment and real E2E belong to the separate host transport smoke gate. */
export function createHostPolicyFixture(options: HostServerOptions): HostServer {
  return new HostServer({
    remoteHostFactory: (opts) => new TestRemoteHostConnection(opts),
    ...options,
  });
}
