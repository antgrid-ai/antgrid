/** Identity used by central authentication and native Iroh sessions. These
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
  /** X25519 public key as raw 32-byte base64: the keychain pair the app
   *  launcher provisions at sign-in, reused as this machine's bus identity. */
  busX25519PublicKey?: string;
  /** X25519 private key as raw 32-byte base64 (same pair as above). */
  busX25519PrivateKey?: string;
}
