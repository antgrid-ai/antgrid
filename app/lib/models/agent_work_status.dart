/// Reduced agent work status. Mirrors the bridge `WorkStatus` enum
/// (protocol.ts), which folds it at two scopes from the same reducer: per
/// project on the control-plane advert, and per session on `SessionEntry`.
/// `attention` = the agent is blocked on a permission/prompt (the
/// call-to-action); distinct from `running`, which is "dialable / holds a relay
/// slot", not activity.
///
/// Lives in `models/` rather than beside the control-plane client because
/// `SessionEntry` carries it too, and a model may not depend on a service.
enum AgentWorkStatus {
  working,
  attention,
  done,
  error;

  static AgentWorkStatus? fromWire(Object? raw) => switch (raw) {
    'working' => AgentWorkStatus.working,
    'attention' => AgentWorkStatus.attention,
    'done' => AgentWorkStatus.done,
    'error' => AgentWorkStatus.error,
    _ => null,
  };
}
