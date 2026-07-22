/**
 * Identity record passed into RelayClient. With the OAuth migration these
 * fields no longer live on disk — they're populated from the stdin bootstrap
 * payload (see `auth/credentials.ts`) and held in memory only.
 */
export interface DeviceIdentity {
  deviceId: string;
  deviceName: string;
  createdAt: string;
  /** Ed25519 public key as base64 (for central relay auth) */
  ed25519PublicKey?: string;
  /** Ed25519 private key as base64 (for central relay auth) */
  ed25519PrivateKey?: string;
}
