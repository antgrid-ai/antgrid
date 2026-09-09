/// The account-scoped task a session was launched for, mirrored by hand from
/// `TaskRefSchema` in `bridge/src/protocol.ts` — the two drifting apart is
/// silent.
///
/// [taskId] is opaque to both the bridge and the app: it addresses the task in
/// the account, and nothing here parses it. [number] is the per-account display
/// id (`ANT-14`), carried alongside so a session can be labelled from the
/// session list alone, with no round trip to the account.
class TaskRef {
  final String taskId;
  final int number;

  const TaskRef({required this.taskId, required this.number});

  Map<String, dynamic> toJson() => {'taskId': taskId, 'number': number};

  /// Null for anything that is not a well-formed pair — a session predating the
  /// field, or a half-populated one. A label needs both halves, and a partial
  /// ref would render as a task that cannot be opened.
  static TaskRef? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final taskId = raw['taskId'];
    final number = raw['number'];
    if (taskId is! String || taskId.isEmpty || number is! num) return null;
    // Held to the schema's `int().positive()` rather than merely to `num`:
    // truncating a fractional id, or carrying a negative one, would label the
    // session with a task number that addresses nothing.
    final n = number.toInt();
    if (n <= 0 || n != number) return null;
    return TaskRef(taskId: taskId, number: n);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TaskRef && other.taskId == taskId && other.number == number;

  @override
  int get hashCode => Object.hash(taskId, number);

  @override
  String toString() => 'TaskRef($taskId, #$number)';
}
