/** Identity used by central authentication and native E2E sessions. These
 * credentials are provisioned by the web service; the private seed never
 * leaves the machine. */
export interface DeviceIdentity {
  deviceId: string;
  deviceName: string;
  createdAt: string;
  /** Ed25519 public key as base64 (for central relay auth) */
  ed25519PublicKey?: string;
  /** Ed25519 private key as base64 (for central relay auth) */
  ed25519PrivateKey?: string;
}
