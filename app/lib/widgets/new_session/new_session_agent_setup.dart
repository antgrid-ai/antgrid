import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_tap_target.dart';
import '../../design/widgets/ab_text_field.dart';
import '../../providers/agent_setup.dart';
import '../../providers/new_session_picker.dart';
import '../agent_setup.dart';
import 'environment_menu.dart';

class NewSessionAgentSetup extends ConsumerStatefulWidget {
  const NewSessionAgentSetup({super.key});

  @override
  ConsumerState<NewSessionAgentSetup> createState() =>
      _NewSessionAgentSetupState();
}

class _NewSessionAgentSetupState extends ConsumerState<NewSessionAgentSetup> {
  late final TextEditingController _command;
  bool _customExpanded = false;

  @override
  void initState() {
    super.initState();
    _command = TextEditingController(
      text: ref.read(newSessionCustomCmdProvider),
    );
  }

  @override
  void dispose() {
    _command.dispose();
    super.dispose();
  }

  void _confirmCommand() {
    final command = _command.text.trim();
    if (command.isEmpty) return;
    ref.read(newSessionCustomCmdProvider.notifier).set(command);
    ref.read(newSessionAgentTouchedProvider.notifier).set(true);
    ref.read(newSessionAgentProvider.notifier).set(const CustomAgent());
  }

  @override
  Widget build(BuildContext context) {
    final tools = ref.watch(newSessionDetectedToolsProvider);
    final machine = ref.watch(agentSetupMachineProvider);
    final source = ref.watch(visiblePickerSourceProvider);
    final noComputer =
        ref.watch(selectedTargetProjectProvider) == null &&
        source?.isLocal != true &&
        source?.machineUuid == null;
    final checking =
        tools.isLoading || (!tools.hasError && tools.value == null);
    final p = context.antgrid;
    return Container(
      key: const Key('new-session-agent-setup'),
      padding: const EdgeInsets.all(AbTokens.space16),
      decoration: BoxDecoration(
        color: p.bgSurface,
        border: Border.all(color: p.borderDefault),
        borderRadius: AbTokens.borderRadius8,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            noComputer
                ? 'Connect a computer to start coding'
                : tools.hasError
                ? 'Couldn’t check coding agents'
                : checking
                ? 'Checking coding agents'
                : 'Set up an agent to start coding',
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontMd,
              fontWeight: FontWeight.w600,
              color: p.textPrimary,
            ),
          ),
          const SizedBox(height: AbTokens.space12),
          const EnvironmentChip(),
          const SizedBox(height: AbTokens.space12),
          if (noComputer)
            Text(
              'Install Antgrid on your computer, sign in with the same account, '
              'and turn on Remote. Then select it here.',
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontSm,
                color: p.textSecondary,
              ),
            )
          else ...[
            AgentSetupHelp(
              key: ValueKey(machine.uuid),
              tools: tools,
              showComputerChoice: false,
              compactButtons: false,
              buttonPadding: const EdgeInsets.all(AbTokens.space8),
            ),
            SizedBox(
              height: AbTapTarget.wrapRunSpacing(context, AbTokens.space8),
            ),
            AbButton(
              padding: const EdgeInsets.all(AbTokens.space8),
              label: _customExpanded
                  ? 'Cancel custom command'
                  : 'Advanced: Use a custom command',
              wrapLabel: true,
              onTap: () => setState(() => _customExpanded = !_customExpanded),
            ),
            if (_customExpanded) ...[
              const SizedBox(height: AbTokens.space12),
              Text(
                'Enter the command for an agent installed on ${machine.label}.',
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontSm,
                  color: p.textSecondary,
                ),
              ),
              const SizedBox(height: AbTokens.space8),
              Semantics(
                label: 'Custom agent command',
                child: AbTextField(
                  key: const Key('new-session-setup-command'),
                  controller: _command,
                  hintText: 'Agent command or executable path',
                  autofocus: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _confirmCommand(),
                ),
              ),
              const SizedBox(height: AbTokens.space8),
              AbButton(
                label: 'Use this command',
                padding: const EdgeInsets.all(AbTokens.space8),
                variant: AbButtonVariant.primary,
                onTap: _command.text.trim().isEmpty ? null : _confirmCommand,
              ),
            ],
          ],
        ],
      ),
    );
  }
}
