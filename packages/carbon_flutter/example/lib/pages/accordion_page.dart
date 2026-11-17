import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../gallery_scaffold.dart';

class AccordionPage extends StatefulWidget {
  const AccordionPage({super.key});

  @override
  State<AccordionPage> createState() => _AccordionPageState();
}

class _AccordionPageState extends State<AccordionPage> {
  static const _titles = ['Choose your plan', 'Add team members', 'Payment'];
  final Set<int> _open = <int>{};

  CarbonAccordionItem _item(String title, {bool initiallyOpen = false}) =>
      CarbonAccordionItem(
        title: Text(title),
        initiallyOpen: initiallyOpen,
        child: const Text(
          'Compare plan features and select the option that best matches '
          'your expected usage.',
        ),
      );

  @override
  Widget build(BuildContext context) {
    return GalleryPage(
      title: 'Accordion',
      summary:
          'Collapsible sections with a heading button. Items open '
          'independently; Enter or Space toggles the focused heading.',
      children: [
        GallerySection(
          title: 'Default',
          children: [
            CarbonAccordion(
              children: [
                _item(_titles[0], initiallyOpen: true),
                _item(_titles[1]),
                _item(_titles[2]),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'Flush',
          description: 'Title, chevron and content lose their inline padding.',
          children: [
            CarbonAccordion(
              flush: true,
              children: [_item(_titles[0]), _item(_titles[1])],
            ),
          ],
        ),
        GallerySection(
          title: 'Chevron at the start',
          children: [
            CarbonAccordion(
              align: CarbonAccordionAlign.start,
              children: [_item(_titles[0]), _item(_titles[1])],
            ),
          ],
        ),
        GallerySection(
          title: 'Sizes',
          children: [
            for (final size in CarbonAccordionSize.values)
              CarbonAccordion(
                size: size,
                children: [_item('Size ${size.name}')],
              ),
          ],
        ),
        GallerySection(
          title: 'Controlled',
          children: [
            CarbonAccordion(
              children: [
                for (var i = 0; i < _titles.length; i++)
                  CarbonAccordionItem(
                    title: Text(_titles[i]),
                    open: _open.contains(i),
                    onOpenChanged: (open) => setState(
                      () => open ? _open.add(i) : _open.remove(i),
                    ),
                    child: const Text('Host-owned open state.'),
                  ),
              ],
            ),
          ],
        ),
        GallerySection(
          title: 'Disabled',
          children: [
            CarbonAccordion(
              disabled: true,
              children: [_item(_titles[0]), _item(_titles[1])],
            ),
          ],
        ),
      ],
    );
  }
}
