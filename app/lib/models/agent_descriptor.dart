/// One agent as the bridge's registry describes it, independent of whether the
/// reporting machine has it installed.
///
/// Hand-mirrors `AgentDescriptorSchema` in `bridge/src/protocol.ts`, per the
/// convention that the Dart side mirrors the TS Zod schemas by hand. It is the
/// static half of the tools advertisement: `agent:tools.tools[]` says what is on
/// PATH on one machine, this says what each agent IS. That distinction is why
/// the app can no longer answer these questions itself — a cached session row
/// belongs to a machine whose tools were never probed here.
///
/// Every field is required: a bridge that sends the array has answered all of
/// it. The ARRAY is what is optional, and a key missing from the catalog means
/// "no bridge has told us about this agent" — never a set of false
/// capabilities.
class AgentDescriptor {
  /// Bridge registry key (`AgentKey` in `bridge/src/agents/types.ts`).
  final String tool;

  /// Display name. Authoritative: the app has no table to fall back to beyond
  /// the raw key.
  final String label;

  /// The agent has a chat driver, so a session of it can run in chat mode.
  final bool chatCapable;

  /// The agent can be driven headlessly as a Handler judge.
  final bool judgeCapable;

  /// Whether an armed Handler can OBSERVE this agent's terminal sessions —
  /// its installed integration posts `/handler-event`. "Unsupported" and
  /// "armed but quiet" are different facts, and this is the only thing that
  /// separates them.
  final bool handlerTerminal;

  /// The same question for chat sessions, where any chat driver qualifies.
  final bool handlerChat;

  const AgentDescriptor({
    required this.tool,
    required this.label,
    required this.chatCapable,
    required this.judgeCapable,
    required this.handlerTerminal,
    required this.handlerChat,
  });

  /// Null for a malformed entry. A partial descriptor is dropped rather than
  /// defaulted: a missing field would otherwise become a confident `false`,
  /// which is the exact failure the descriptor exists to remove.
  static AgentDescriptor? fromJson(Map<String, dynamic> json) {
    final tool = json['tool'];
    final label = json['label'];
    final chatCapable = json['chatCapable'];
    final judgeCapable = json['judgeCapable'];
    final handler = json['handler'];
    if (tool is! String ||
        tool.isEmpty ||
        label is! String ||
        chatCapable is! bool ||
        judgeCapable is! bool ||
        handler is! Map) {
      return null;
    }
    final terminal = handler['terminal'];
    final chat = handler['chat'];
    if (terminal is! bool || chat is! bool) return null;
    return AgentDescriptor(
      tool: tool,
      label: label,
      chatCapable: chatCapable,
      judgeCapable: judgeCapable,
      handlerTerminal: terminal,
      handlerChat: chat,
    );
  }

  /// Round-trips through [fromJson], so the persisted catalog and the wire
  /// frame stay one shape.
  Map<String, dynamic> toJson() => {
    'tool': tool,
    'label': label,
    'chatCapable': chatCapable,
    'judgeCapable': judgeCapable,
    'handler': {'terminal': handlerTerminal, 'chat': handlerChat},
  };

  // Value equality is load-bearing: the catalog notifier compares a merged map
  // against the current one to decide whether to persist, and a re-advert of an
  // unchanged registry must not write to disk or notify watchers.
  @override
  bool operator ==(Object other) =>
      other is AgentDescriptor &&
      other.tool == tool &&
      other.label == label &&
      other.chatCapable == chatCapable &&
      other.judgeCapable == judgeCapable &&
      other.handlerTerminal == handlerTerminal &&
      other.handlerChat == handlerChat;

  @override
  int get hashCode => Object.hash(
    tool,
    label,
    chatCapable,
    judgeCapable,
    handlerTerminal,
    handlerChat,
  );
}
