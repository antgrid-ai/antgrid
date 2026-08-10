/// Classifies parsed Antgrid protocol messages into one of three dispatch tiers.
///
/// Used by the project session manager to decide what to do with each frame
/// while the app is paused / unfocused. The classification is purely a
/// function of the message `type` string — no payload inspection.
///
/// Note on errors: a message that carries an `error` field is conceptually
/// status-tier regardless of its type (callers should always dispatch error
/// frames so the UI can surface the failure). This function does not look
/// at `error` — it only buckets by type. Callers that have the parsed
/// payload should additionally check `msg.error != null` and treat such
/// frames as status-tier even if the type is in the heavy bucket.
library;

/// Dispatch tier for a Antgrid protocol message.
enum MessageTier {
  /// Drawer-visible / always-dispatched (project listings, lifecycle,
  /// agent identity, low-frequency state). Sent through even while paused.
  status,

  /// Heavy stream (terminal output, file content, previews, search). Gated
  /// by focus / pause state.
  heavy,

  /// Handshake, ping/pong, and unknown types. Never dispatched to UI
  /// reducers.
  ignore,
}

/// Authoritative app-side mirror of the bridge checkout-variable contract.
/// Every type here must carry `checkoutId`; absence decodes as `main` only for
/// legacy frames. Services use this same set when filtering their bundles.
const Set<String> kCheckoutVariableMessageTypes = <String>{
  'terminal:start', 'terminal:stop', 'terminal:input', 'terminal:resize',
  'terminal:output', 'terminal:started', 'terminal:exited',
  'terminal:notification', 'terminal:size', 'terminal:snapshot:request',
  'terminal:snapshot', 'agent:status', 'tree:full', 'tree:update',
  'file:read', 'file:content', 'file:search', 'file:search-cancel',
  'file:search-result', 'file:search-done', 'file:upload-start',
  'file:upload-ready', 'file:upload-chunk', 'file:upload-ack',
  'file:upload-done', 'file:upload-result', 'git:status', 'git:diff',
  'git:diff-content', 'git:list-branches', 'git:branches', 'git:checkout',
  'git:checkout-result', 'git:commit', 'git:commit-result', 'git:discard',
  'git:discard-result', 'command:run', 'command:output', 'command:done',
  'config:read', 'config:read-result', 'config:write',
  'config:write-result', 'config:changed', 'config:detect-tools',
  'config:detect-tools-result', 'ports:update', 'port:detected',
  'preview:url', 'file:tree:snapshot:request', 'file:tree:snapshot',
  'preview:snapshot:request', 'preview:snapshot',
  'session:result', 'control:result',
};

String checkoutIdForEnvelope(Map<String, dynamic> envelope) {
  final value = envelope['checkoutId'];
  return value is String && value.isNotEmpty ? value : 'main';
}

/// Config frames that report config *validity* — the only frames that set or
/// clear the drawer's structural config-error dot (see `ProjectStatusNotifier`).
/// Excludes `config:write-result` / `config:detect-tools-result`, which carry
/// no config-validity signal. Single source of truth for these type strings so
/// the notifier's dot gate and the dispatch taxonomy cannot drift apart.
const Set<String> kConfigValidityTypes = <String>{
  'config:read-result',
  'config:changed',
};

const Set<String> _statusTypes = <String>{
  'session:list:result',
  'session:result',
  'session:updated',
  'command:done',
  'port:detected',
  'ports:update',
  'agent:status',
  'agent:hello',
  'agent:turn-start',
  'agent:session-reset',
  'agent:turn-end',
  'agent:capabilities',
  'agent:updateAvailable',
  'agent:updateResult',
  'agent:permission-request',
  'agent:question',
  'agent:request-retracted',
  'agent:error',
  'agent:usage',
  ...kConfigValidityTypes,
  'config:write-result',
  'config:detect-tools-result',
  'terminal:started',
  'terminal:exited',
  'terminal:notification',
  'notification:push',
  'terminal:size',
  'git:branches',
  'git:checkout-result',
  'git:commit-result',
  'git:discard-result',
  'git:status',
  'git:diff-content',
  'handler:status',
  'file:upload-ready',
  'file:upload-ack',
  'file:upload-result',
};

/// Inbound parser types (`parseAbMessage` cases in `models/ab_message.dart`)
/// that are DELIBERATELY not routed to a UI reducer via
/// [classifyAbMessageByType] — so a type that parses yet classifies as
/// [MessageTier.ignore] is a documented decision here, not a silent omission.
///
/// This is the receive-side of the reconciliation-checkpoint hazard: the parser
/// switch is the one place you MUST touch to receive a new agent→app type, so
/// `classification_gate_test.dart` derives the inbound-type set from it and
/// asserts every case is either classified non-ignore or listed here. That is
/// what makes "add an inbound type without classifying it" fail CI instead of
/// silently dropping the frame.
///
///   - `tunnel:http-response` arrives on the `preview` channel and is consumed
///     by PreviewService's direct transport subscription, bypassing the control
///     classification path entirely.
///   - `client:focus-state` is app→agent (outbound); it parses only for the
///     agent / loopback side.
///   - the three `*:snapshot:request` types are snapshot REQUESTS serviced
///     outside the heavy/status reducers.
const Set<String> kUnroutedInboundTypes = <String>{
  'tunnel:http-response',
  'client:focus-state',
  'terminal:snapshot:request',
  'file:tree:snapshot:request',
  'preview:snapshot:request',
};

const Set<String> _heavyTypes = <String>{
  'terminal:output',
  'terminal:snapshot',
  'tree:full',
  'tree:update',
  'file:tree:snapshot',
  'file:content',
  'preview:url',
  'preview:snapshot',
  'command:output',
  'file:search-result',
  'file:search-done',
  'handler:escalation',
  'handler:activity',
  'handler:snapshot',
  'agent:item-added',
  'agent:item-delta',
  'agent:item-updated',
  'agent:transcript-replay',
  'agent:snapshot',
};

/// Classify a Antgrid message by its `type` string.
///
/// Returns [MessageTier.ignore] for the empty string, unknown types, and
/// handshake / ping / pong / request-only types.
MessageTier classifyAbMessageByType(String type) {
  if (_statusTypes.contains(type)) return MessageTier.status;
  if (_heavyTypes.contains(type)) return MessageTier.heavy;
  return MessageTier.ignore;
}

/// Classify a parsed Antgrid message envelope (a JSON map with a `type`
/// field, as returned by `parseAbMessage` callers or read directly off
/// the wire).
///
/// Errors (`error` field present) are coerced to [MessageTier.status] so
/// the UI can always surface the failure — even when the type would
/// otherwise be classified as heavy.
MessageTier classifyAbMessage(Map<String, dynamic> envelope) {
  if (envelope['error'] != null) return MessageTier.status;
  final type = envelope['type'];
  if (type is! String) return MessageTier.ignore;
  return classifyAbMessageByType(type);
}
