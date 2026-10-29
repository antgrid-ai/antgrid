import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/widgets.dart';

import '../../design/ab_colors.dart';
import '../../design/widgets/ab_toast.dart';
import '../../models/memory.dart';
import 'memory_detail_pane.dart';
import 'memory_header.dart';

/// The pushed detail page for narrow layouts; wide layouts embed
/// [MemoryDetailPane] beside the list instead.
class MemoryRecordDetails extends StatefulWidget {
  const MemoryRecordDetails({
    super.key,
    required this.target,
    required this.id,
  });
  final MemoryTarget target;
  final String id;

  @override
  State<MemoryRecordDetails> createState() => _MemoryRecordDetailsState();
}

class _MemoryRecordDetailsState extends State<MemoryRecordDetails> {
  late String _id = widget.id;

  @override
  Widget build(BuildContext context) {
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
