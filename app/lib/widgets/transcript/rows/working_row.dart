import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../design/ab_colors.dart';
import '../../../design/ab_tokens.dart';
import '../../../design/widgets/ab_button.dart';
import '../../../design/widgets/ab_loading.dart';
import '../format.dart';
import '../transcript_rows.dart';

class WorkingRow extends StatefulWidget {
  final WorkingRowData data;
  final VoidCallback onStop;
  const WorkingRow({super.key, required this.data, required this.onStop});

  @override
  State<WorkingRow> createState() => _WorkingRowState();
}

class _WorkingRowState extends State<WorkingRow> {
  Timer? _timer;
  // Elapsed accumulates via ticks (seeded once from the receipt stamp) rather
  // than re-reading DateTime.now() in build — FakeAsync advances timers but
  // not the wall clock, so a now()-derived label would freeze in widget tests.
  late Duration _elapsed = widget.data.startedAt == null
      ? Duration.zero
      : DateTime.now().difference(widget.data.startedAt!);

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed += const Duration(seconds: 1));
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.antgrid;
    final elapsed = _elapsed;
    final label = widget.data.waitingOnUser
        ? 'Waiting for you'
        : 'Working for ${formatDuration(elapsed)}';
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space8,
        vertical: AbTokens.space4,
      ),
      child: Row(
        children: [
          AbLoadingDot(size: AbTokens.fontSm, color: c.accent),
          const SizedBox(width: AbTokens.space8),
          Expanded(
            child: Text(
              label,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontSm,
                color: c.textMuted,
              ),
            ),
          ),
          AbButton(
            label: 'Stop',
            compact: true,
            color: c.error,
            onTap: widget.onStop,
          ),
        ],
      ),
    );
  }
}
