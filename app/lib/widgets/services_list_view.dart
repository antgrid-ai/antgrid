import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_icons.dart';
import '../design/ab_status_tone.dart';
import '../design/widgets/ab_empty_state.dart';
import '../design/widgets/ab_list_row.dart';
import '../design/widgets/ab_loading.dart';
import '../design/widgets/ab_status_dot.dart';
import '../models/service_status.dart';
import '../models/terminal_models.dart';
import '../project/project_session_registry.dart';
import '../providers/agent_transport.dart';
import '../providers/providers.dart';
import '../services/terminal_service.dart';
import 'terminal_detail_view.dart';

/// Renders declared services (long-running processes from antgrid.yaml).
/// Running services can be opened to view live logs; the existing terminal
/// selection → send-to-agent flow works there unchanged.
class ServicesListView extends ConsumerStatefulWidget {
  const ServicesListView({super.key});

  @override
  ConsumerState<ServicesListView> createState() => _ServicesListViewState();
}

class _ServicesListViewState extends ConsumerState<ServicesListView> {
  String? _viewingLogsId;

  @override
  Widget build(BuildContext context) {
    final terminalService = serviceWhenReady(ref, terminalServiceProvider);
    if (terminalService == null) {
      return const AbLoading(message: 'loading services...');
    }
    final focusedId = ref.watch(selectedRegistrationIdProvider);
    final services = focusedId == null
        ? const <ServiceStatus>[]
        : ref.watch(
            projectStatusProvider(
              focusedId,
            ).select((s) => s.value?.services ?? const <ServiceStatus>[]),
          );

    if (_viewingLogsId != null) {
      final tabs =
          ref.watch(terminalStateProvider).value?.tabs ?? const {};
      final tab = tabs[_viewingLogsId];
      if (tab == null) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => setState(() => _viewingLogsId = null),
        );
        return const SizedBox.shrink();
      }
      return _buildLogsView(tab, terminalService);
    }

    if (services.isEmpty) {
      return const AbEmptyState.compact(title: 'No services declared');
    }
    return ListView.builder(
      itemCount: services.length,
      itemBuilder: (ctx, i) => _buildServiceRow(services[i], terminalService),
    );
  }

  Widget _buildServiceRow(
    ServiceStatus service,
    TerminalService terminalService,
  ) {
    final statusTone = service.running
        ? AbStatusTone.success
        : AbStatusTone.disabled;
    return AbListRow(
      leading: AbStatusDot(tone: statusTone),
      title: Text(service.name),
      subtitle: Text(service.command),
      actions: [
        if (service.running) ...[
          AbRowAction(
            icon: AbIcons.terminal,
            tooltip: 'View logs',
            onTap: () => setState(() => _viewingLogsId = service.id),
          ),
          AbRowAction(
            icon: AbIcons.restart,
            tooltip: 'Restart',
            onTap: () {
              terminalService.requestStop(service.id);
              terminalService.requestStart(service.id);
            },
          ),
          AbRowAction(
            icon: AbIcons.stop,
            tooltip: 'Stop',
            onTap: () => terminalService.requestStop(service.id),
          ),
        ] else
          AbRowAction(
            icon: AbIcons.start,
            tooltip: 'Start',
            onTap: () => terminalService.requestStart(service.id),
          ),
      ],
      divider: true,
      density: AbRowDensity.lg,
    );
  }

  Widget _buildLogsView(TerminalTab tab, TerminalService service) {
    return TerminalDetailView(
      tab: tab,
      terminalService: service,
      onBack: () => setState(() => _viewingLogsId = null),
    );
  }
}
