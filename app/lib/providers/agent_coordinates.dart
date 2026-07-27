import 'package:collection/collection.dart';

import '../services/account_agents_api.dart';
import '../storage/recent_agents_store.dart';

/// An agent's endpoint/identity coordinates: where to dial it and which
/// Ed25519 pubkey its handshake must verify against, plus display metadata.
///
/// These are the fields that go STALE on a stored [RecentAgent] — the durable
/// trust record (agentDeviceId + phone keypair + pairedAt) never changes, but
/// the host can move LAN/relay or re-provision its identity. So they are always
/// re-resolved against the fresh account inventory at use-time (see
/// [resolveAgentCoordinates]); the values pinned on [RecentAgent] are only a
/// last-known cache for the offline case.
class AgentCoordinates {
  /// Where to dial. Nullable: the host may not have enabled mobile access, or
  /// the inventory heartbeat may lag — callers that need to dial must handle a
  /// null (autoOpen/reconnect already throw on a missing relayUrl).
  final String? relayUrl;

  /// The agent's Ed25519 pubkey — the relay-independent MITM anchor the E2E
  /// handshake verifies against. Authoritative from inventory: a
  /// re-provisioned agent would otherwise loop the handshake against a stale
  /// pinned pubkey, unrecoverable until the inventory refreshes.
  final String ed25519Pub;

  final String label;
  final String? machineName;

  const AgentCoordinates({
    required this.relayUrl,
    required this.ed25519Pub,
    required this.label,
    this.machineName,
  });
}

/// Resolve the coordinates for the machine [base], preferring the FRESH account
/// [inventory] (`/account/agents` over TLS — the same relay-independent anchor
/// `autoOpen` already trusts) over the last-known values pinned on [cached].
///
/// Freshness is the default; the cache is an explicit offline fallback, never
/// authoritative — that polarity is the whole fix. When an inventory entry
/// exists its `ed25519Pub`/`label` win outright (they can't be stale), while
/// `relayUrl`/`machineName` fall back per-field to the cache so a transiently
/// null inventory value doesn't blank a known-good address. Returns null only
/// when neither source knows the machine.
AgentCoordinates? resolveAgentCoordinates({
  required String base,
  required List<InventoryAgent>? inventory,
  required RecentAgent? cached,
}) {
  final inv = inventory?.firstWhereOrNull((a) => a.deviceUuid == base);
  if (inv != null) {
    return AgentCoordinates(
      relayUrl: inv.relayUrl ?? cached?.relayUrl,
      ed25519Pub: inv.ed25519Pub,
      label: inv.displayName,
      machineName: inv.machineName ?? cached?.hostMachineName,
    );
  }
  if (cached != null) {
    return AgentCoordinates(
      relayUrl: cached.relayUrl,
      ed25519Pub: cached.agentEd25519Pubkey,
      label: cached.agentLabel,
      machineName: cached.hostMachineName,
    );
  }
  return null;
}
