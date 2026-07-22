import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_text_field.dart';
import '../design/ab_icons.dart';
import '../pairing/remote_pair_actions.dart';

/// Tabbed modal pair flow. Replaces the old right-side `_PairingPanel` and
/// the standalone `_ManualPairDialog` previously embedded in `home_screen`.
class PairDialog extends ConsumerStatefulWidget {
  const PairDialog({super.key, this.initialTab = 0});

  final int initialTab;

  static Future<void> show(BuildContext context, {int initialTab = 0}) {
    return showDialog<void>(
      context: context,
      builder: (_) => PairDialog(initialTab: initialTab),
    );
  }

  @override
  ConsumerState<PairDialog> createState() => _PairDialogState();
}

class _PairDialogState extends ConsumerState<PairDialog>
    with SingleTickerProviderStateMixin, RemotePairActions {
  late final TabController _tabs;
  final _uriController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabs = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTab,
    );
  }

  @override
  void dispose() {
    _tabs.dispose();
    _uriController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(AbTokens.space16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Pair New Project',
                      style: AbTokens.sansStyle(
                        fontSize: AbTokens.fontBody,
                      ),
                    ),
                  ),
                  AbIconButton(
                    icon: AbIcons.close,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: AbTokens.space12),
              TabBar(
                controller: _tabs,
                tabs: const [
                  Tab(text: 'Scan QR'),
                  Tab(text: 'Enter URI'),
                ],
              ),
              const SizedBox(height: AbTokens.space12),
              SizedBox(
                height: 180,
                child: TabBarView(
                  controller: _tabs,
                  children: [
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'Open the scanner to read the agent\'s QR code.',
                          style: TextStyle(
                            fontSize: AbTokens.fontSm,
                            color: context.antgrid.textMuted,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: AbTokens.space12),
                        AbButton(label: 'Open Scanner', onTap: scanAndPair),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AbTextField(
                          controller: _uriController,
                          hintText: 'antgrid://pair?v=1&...',
                          autofocus: true,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => submitPairUri(_uriController),
                        ),
                        const SizedBox(height: AbTokens.space12),
                        AbButton(
                          label: 'Pair',
                          onTap: () => submitPairUri(_uriController),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
