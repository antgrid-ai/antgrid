/// Reduced agent work status. Mirrors the bridge `WorkStatus` enum
/// (protocol.ts), which folds it at two scopes from the same reducer: per
/// project on the control-plane advert, and per session on `SessionEntry`.
/// `attention` = the agent is blocked on a permission/prompt (the
/// call-to-action); distinct from `running`, which is "dialable / holds a relay
/// slot", not activity. `unread` = the agent finished and nobody has opened the
/// session since — read state the BRIDGE owns end to end (it sees every turn end
/// and every `session:focus`), so this is only ever parsed off the wire and
/// never derived, cached, or persisted here.
///
/// Lives in `models/` rather than beside the control-plane client because
/// `SessionEntry` carries it too, and a model may not depend on a service.
enum AgentWorkStatus {
  working,
  attention,
  unread,
  done,
  error;

  static AgentWorkStatus? fromWire(Object? raw) => switch (raw) {
    'working' => AgentWorkStatus.working,
    'attention' => AgentWorkStatus.attention,
    'unread' => AgentWorkStatus.unread,
    'done' => AgentWorkStatus.done,
    'error' => AgentWorkStatus.error,
    _ => null,
  };
}
