import 'package:flutter/material.dart'
    show BuildContext, Navigator, SelectionArea;
import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:flutter/widgets.dart';

import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_adaptive_sheet.dart';
import '../../design/widgets/ab_dialog.dart';

const _legalAssets = <String>[
  'assets/legal/LICENSE.md',
  'assets/legal/LICENSING.md',
  'assets/legal/THIRD-PARTY.md',
  'assets/legal/BRAND-ASSETS-LICENSE.md',
  'assets/legal/SOURCE_OFFER.md',
  'assets/legal/ELASTIC-2.0.md',
];

Future<String> loadBundledLegalNotices([AssetBundle? bundle]) async {
  final assets = bundle ?? rootBundle;
  final parts = <String>[];
  for (final path in _legalAssets) {
    parts.add(await assets.loadString(path));
  }
  return parts.join('\n\n---\n\n');
}

Future<void> showLegalNotices(
  BuildContext context, {
  Future<String> Function() load = loadBundledLegalNotices,
}) {
  return showAbAdaptiveSheet<void>(
    context,
    maxWidth: AbTokens.documentMaxWidth,
    child: LegalNoticesSheet(load: load),
  );
}

class LegalNoticesSheet extends StatelessWidget {
  const LegalNoticesSheet({super.key, required this.load});

  final Future<String> Function() load;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.8,
        child: Padding(
          padding: const EdgeInsets.all(AbTokens.space16),
          child: Column(
            children: [
              abDialogTitle(
                'Licences & notices',
                onClose: () => Navigator.of(context).pop(),
              ),
              const SizedBox(height: AbTokens.space12),
              Expanded(
                child: FutureBuilder<String>(
                  future: load(),
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return Text(
                        'Bundled notices could not be loaded.',
                        style: AbTokens.sansStyle(),
                      );
                    }
                    final text = snapshot.data;
                    if (text == null) {
                      return const SizedBox.shrink();
                    }
                    return SingleChildScrollView(
                      child: SelectionArea(
                        child: Text(
                          text,
                          style: AbTokens.monoStyle(
                            fontSize: AbTokens.fontXs,
                            height: 1.4,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
