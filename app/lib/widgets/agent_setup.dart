import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_dialog_surface.dart';
import '../design/widgets/ab_tap_target.dart';
import '../providers/agent_setup.dart';
import '../providers/ui_attention_providers.dart';
import '../util/detached.dart';
import '../util/external_url.dart';
import 'new_session/environment_menu.dart';

Future<void> showAgentSetup(BuildContext context, AgentSetupMachine machine) =>
    AbDialogSurface.show<void>(
      context: context,
      builder: (_) => AgentSetupDialog(machine: machine),
    );

class AgentSetupHelp extends ConsumerStatefulWidget {
  const AgentSetupHelp({
    super.key,
    this.tools,
    this.inDialog = false,
    this.showComputerChoice = true,
    this.compactButtons = true,
    this.buttonPadding,
  });

  final AsyncValue<Map<String, String?>?>? tools;
  final bool inDialog;
  final bool showComputerChoice;
  final bool compactButtons;
  final EdgeInsetsGeometry? buttonPadding;

  @override
  ConsumerState<AgentSetupHelp> createState() => _AgentSetupHelpState();
}

class _AgentSetupHelpState extends ConsumerState<AgentSetupHelp> {
  bool _troubleshooting = false;
  bool _retrying = false;
  String? _retryError;

  Future<void> _retry(AgentSetupMachine machine) async {
    final container = ref.container;
    setState(() {
      _retrying = true;
      _retryError = null;
    });
    try {
      await retryAgentSetup(container, machine);
    } catch (_) {
      if (mounted) {
        setState(
          () => _retryError = 'The check failed. Try troubleshooting below.',
        );
      }
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  Future<void> _chooseComputer() {
    final container = ref.container;
    return AbDialogSurface.show<void>(
      context: context,
      builder: (_) => AbDialogSurface(
        title: 'Choose a computer',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            EnvironmentPanel(
              onSelected: (_) {
                container
                    .read(workbenchSurfaceProvider.notifier)
                    .set(WorkbenchSurface.newSession);
              },
            ),
            const SizedBox(height: AbTokens.space12),
            Text(
              'To add another computer, install Antgrid there, sign in with '
              'the same account, and turn on Remote.',
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontSm,
                color: context.antgrid.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final machine = ref.watch(agentSetupMachineProvider);
    final AsyncValue<Map<String, String?>?> tools =
        widget.tools ?? ref.watch(agentSetupToolsProvider);
    final checking =
        _retrying ||
        tools.isLoading ||
        (!tools.hasError && tools.value == null);
    final failed = tools.hasError || _retryError != null;
    final found = !checking && !failed && (tools.value?.isNotEmpty ?? false);
    final names = tools.value?.entries.map((e) => e.value ?? e.key).join(', ');
    final actionRowSpacing = AbTapTarget.wrapRunSpacing(
      context,
      AbTokens.space8,
    );
    final status = checking
        ? 'Checking agents on ${machine.label}…'
        : failed
        ? 'Couldn’t check agents on ${machine.label}.'
        : found
        ? '$names detected on ${machine.label}.'
        : 'No coding agent found on ${machine.label}. Install one to start a session.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          liveRegion: true,
          child: Text(
            status,
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXs,
              color: context.antgrid.textSecondary,
            ),
          ),
        ),
        const SizedBox(height: AbTokens.space8),
        Wrap(
          spacing: AbTokens.space8,
          runSpacing: actionRowSpacing,
          children: [
            if (!widget.inDialog && !checking && !failed && !found)
              AbButton(
                label: 'Set up a coding agent',
                padding: widget.buttonPadding,
                variant: AbButtonVariant.primary,
                compact: widget.compactButtons,
                onTap: () => detached(
                  'AgentSetup',
                  'open setup',
                  () => showAgentSetup(context, machine),
                ),
              ),
            Semantics(
              enabled: !checking,
              child: AbButton(
                key: const ValueKey('agent-setup-retry'),
                padding: widget.buttonPadding,
                label: checking
                    ? 'Checking…'
                    : failed
                    ? 'Retry'
                    : 'Check again',
                compact: widget.compactButtons,
                // Retain keyboard focus while a scan changes the status above.
                onTap: () {
                  if (!checking) {
                    detached(
                      'AgentSetup',
                      'retry detection',
                      () => _retry(machine),
                    );
                  }
                },
              ),
            ),
          ],
        ),
        SizedBox(height: actionRowSpacing),
        Wrap(
          spacing: AbTokens.space8,
          runSpacing: actionRowSpacing,
          children: [
            if (!widget.inDialog && widget.showComputerChoice)
              AbButton(
                label: 'Use another computer',
                padding: widget.buttonPadding,
                compact: widget.compactButtons,
                onTap: () =>
                    detached('AgentSetup', 'choose computer', _chooseComputer),
              ),
            AbButton(
              label: failed ? 'Troubleshoot' : 'Already installed?',
              padding: widget.buttonPadding,
              compact: widget.compactButtons,
              onTap: () => setState(() => _troubleshooting = !_troubleshooting),
            ),
          ],
        ),
        if (_troubleshooting) ...[
          const SizedBox(height: AbTokens.space8),
          Text(
            machine.uuid == null
                ? 'Open the agent in a new terminal on this computer and finish '
                      'its sign-in. If it works there, check again. If Antgrid still '
                      'cannot find it, restart Antgrid to refresh its environment.'
                : 'Make sure ${machine.label} is awake, Antgrid is running, and '
                      'Remote is on. Install and sign in to the agent on that computer, '
                      'then check again here.',
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXs,
              color: context.antgrid.textSecondary,
            ),
          ),
          const SizedBox(height: AbTokens.space8),
          AbButton(
            label: 'Open support',
            padding: widget.buttonPadding,
            compact: widget.compactButtons,
            onTap: () => detached(
              'AgentSetup',
              'open support',
              () => openExternalUrl(context, 'https://antgrid.ai/support'),
            ),
          ),
        ],
      ],
    );
  }
}

class AgentSetupDialog extends ConsumerWidget {
  const AgentSetupDialog({
    super.key,
    required this.machine,
    this.openUrl = openExternalUrl,
  });

  final AgentSetupMachine machine;
  final Future<void> Function(BuildContext, String) openUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(agentSetupCatalogProvider);
    final guides = catalog.where((agent) {
      final uri = Uri.tryParse(agent.installUrl ?? '');
      return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
    }).toList();
    return AbDialogSurface(
      title: 'Set up a coding agent',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Install one agent on ${machine.label}. Choose a guide and follow '
            'the instructions for that computer’s operating system.',
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontSm,
              color: context.antgrid.textSecondary,
            ),
          ),
          const SizedBox(height: AbTokens.space12),
          for (final agent in guides) ...[
            AbButton(
              label: '${agent.label} installation guide',
              wrapLabel: true,
              onTap: () => detached(
                'AgentSetup',
                'open installation guide',
                () => openUrl(context, agent.installUrl!),
              ),
            ),
            const SizedBox(height: AbTokens.space8),
          ],
          if (guides.isEmpty)
            AbButton(
              label: 'Open getting-started guide',
              onTap: () => detached(
                'AgentSetup',
                'open getting started',
                () => openUrl(context, 'https://antgrid.ai/get-started'),
              ),
            ),
          const SizedBox(height: AbTokens.space12),
          Text(
            'After installing, open the agent in a terminal and finish signing '
            'in, then check again here.',
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontSm,
              color: context.antgrid.textSecondary,
            ),
          ),
          const SizedBox(height: AbTokens.space12),
          AgentSetupHelp(key: ValueKey(machine.uuid), inDialog: true),
        ],
      ),
    );
  }
}
