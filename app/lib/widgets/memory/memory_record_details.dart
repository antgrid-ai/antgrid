import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/widgets/ab_inline_banner.dart';
import '../../design/widgets/ab_toast.dart';
import '../../models/memory.dart';
import '../../providers/account_machines.dart';
import 'memory_detail_pane.dart';
import 'memory_error.dart';
import 'memory_header.dart';

/// The pushed detail page for narrow layouts; wide layouts embed
/// [MemoryDetailPane] beside the list instead.
class MemoryRecordDetails extends ConsumerStatefulWidget {
  const MemoryRecordDetails({
    super.key,
    required this.target,
    required this.id,
    this.machineName,
  });
  final MemoryTarget target;
  final String id;

  /// Names a remote machine; null shows no offline notice.
  final String? machineName;

  @override
  ConsumerState<MemoryRecordDetails> createState() =>
      _MemoryRecordDetailsState();
}

class _MemoryRecordDetailsState extends ConsumerState<MemoryRecordDetails> {
  late String _id = widget.id;

  @override
  Widget build(BuildContext context) {
    final machineId = widget.target.machineId;
    final name = widget.machineName;
    // The list's banner is under this page, so an edit started here would
    // otherwise learn the machine dropped only when Save fails.
    final offline =
        machineId != null &&
        name != null &&
        !ref.watch(machineConnectedProvider(machineId));
    return Scaffold(
      backgroundColor: context.antgrid.bgDeepest,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Column(
          children: [
            MemoryHeader.compact(
              onBack: () => Navigator.of(context).pop(),
              backTooltip: 'Back to Memory',
            ),
            if (offline)
              AbInlineBanner(
                text: memoryOfflineBannerCopy(name),
                color: context.antgrid.textMuted,
              ),
            Expanded(
              child: MemoryDetailPane(
                key: ValueKey(_id),
                target: widget.target,
                id: _id,
                compact: true,
                onSaved: (id) => setState(() => _id = id),
                onForgotten: () => Navigator.of(context).pop(),
                onGone: () {
                  showAbToast(context, 'This memory was forgotten.');
                  Navigator.of(context).pop();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
