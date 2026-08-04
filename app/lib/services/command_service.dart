import 'dart:async';

import '../models/command_models.dart';
import '../models/ab_message.dart';
import '../project/project_session.dart';

/// Per-project on-demand command runner.
///
/// Constructed at [ProjectSession] creation time. Subscribes to both the
/// heavy tier (for `command:output`) and the status tier (for
/// `command:done` — which is status-tier because it's drawer-visible via
/// `ProjectStatusNotifier.activeCommandName`, but the service also needs
/// it locally to mark the current execution's success/failed status).
///
/// Lifetime is bound to the session; calling [dispose] cancels both
/// subscriptions and closes the state controller.
class CommandService {
  final ProjectSession session;
  final String checkoutId;

  StreamSubscription<Map<String, dynamic>>? _heavySub;
  StreamSubscription<Map<String, dynamic>>? _statusSub;
  bool _disposed = false;

  final _stateController = StreamController<CommandState>.broadcast();
  CommandState _state = const CommandState();

  /// Buffer for accumulating output chunks before flushing to the notifier.
  StringBuffer? _outputBuffer;
  Timer? _flushTimer;

  Stream<CommandState> get stateStream => _stateController.stream;
  CommandState get currentState => _state;

  String get projectId => session.projectId;

  CommandService.fromSession(this.session, {this.checkoutId = 'main'}) {
    _heavySub = session.checkoutHeavyStream(checkoutId).listen(_onHeavyJson);
    _statusSub = session.checkoutStatusStream(checkoutId).listen(_onStatusJson);
  }

  void _setState(CommandState newState) {
    if (_disposed) return;
    final oldOutput = _state.current?.output;
    final newOutput = newState.current?.output;
    if (oldOutput != null && oldOutput != newOutput) {
      oldOutput.dispose();
    }
    _state = newState;
    _stateController.add(newState);
  }

  void _onHeavyJson(Map<String, dynamic> json) {
    final abMsg = parseAbMessage(json);
    if (abMsg == null) return;
    if (abMsg is CommandOutputMessage) {
      _handleCommandOutput(abMsg);
    }
  }

  void _onStatusJson(Map<String, dynamic> json) {
    final abMsg = parseAbMessage(json);
    if (abMsg == null) return;
    if (abMsg is CommandDoneMessage) {
      _handleCommandDone(abMsg);
    }
  }

  // --- Message handlers ---

  void _handleCommandOutput(CommandOutputMessage msg) {
    final current = _state.current;
    if (current == null ||
        current.commandName != msg.commandName ||
        current.projectId != msg.projectId) {
      return;
    }
    (_outputBuffer ??= StringBuffer()).write(msg.data);
    _flushTimer ??= Timer(const Duration(milliseconds: 16), _flushOutput);
  }

  void _flushOutput() {
    _flushTimer?.cancel();
    _flushTimer = null;
    final buf = _outputBuffer;
    if (buf == null || buf.isEmpty) return;
    final current = _state.current;
    if (current != null) {
      current.output.value += buf.toString();
    }
    _outputBuffer = null;
  }

  void _handleCommandDone(CommandDoneMessage msg) {
    final current = _state.current;
    if (current == null ||
        current.commandName != msg.commandName ||
        current.projectId != msg.projectId) {
      return;
    }

    _flushOutput();

    final exitCode = msg.exitCode;
    final status = (exitCode == 0)
        ? CommandStatus.success
        : CommandStatus.failed;

    _setState(
      _state.copyWith(
        current: current.copyWith(status: status, exitCode: exitCode),
      ),
    );
  }

  // --- Public methods ---

  void runCommand(String commandName, {bool confirmed = false}) {
    if (_disposed) return;
    _flushTimer?.cancel();
    _flushTimer = null;
    _outputBuffer = null;

    // Anchor on the bare wire id, NOT the compound relay registrationId: the
    // bridge echoes back the projectId it received (= wireProjectId) on
    // command:output/done, and _handleCommandOutput matches against
    // current.projectId. Storing the compound id here would mismatch the echo
    // and silently drop all output over relay.
    final projectId = session.wireProjectId;
    _setState(
      CommandState(
        current: CommandExecution(
          commandName: commandName,
          projectId: projectId,
        ),
      ),
    );

    session.sendForCheckout(checkoutId,
      createAbMessage('command:run', {
        'projectId': projectId,
        'commandName': commandName,
        if (confirmed) 'confirmed': true,
      }),
    );
  }

  void dismiss() {
    if (_disposed) return;
    _flushTimer?.cancel();
    _flushTimer = null;
    _outputBuffer = null;
    _setState(const CommandState());
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    _outputBuffer = null;
    await _heavySub?.cancel();
    _heavySub = null;
    await _statusSub?.cancel();
    _statusSub = null;
    await _stateController.close();
  }
}
