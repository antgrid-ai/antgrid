import 'package:flutter/widgets.dart';

import 'pages/foundations/colors_page.dart';
import 'pages/foundations/density_page.dart';
import 'pages/foundations/icons_page.dart';
import 'pages/foundations/layers_page.dart';
import 'pages/foundations/typography_page.dart';

/// One page in the gallery's navigation.
class GalleryEntry {
  const GalleryEntry({
    required this.id,
    required this.title,
    required this.group,
    required this.builder,
  });

  final String id;
  final String title;

  /// 'Foundations', 'Components' or 'Compositions'.
  final String group;
  final WidgetBuilder builder;
}

const List<String> galleryGroups = <String>[
  'Foundations',
  'Components',
  'Compositions',
];

final List<GalleryEntry> galleryEntries = <GalleryEntry>[
  GalleryEntry(
    id: 'colors',
    title: 'Colors',
    group: 'Foundations',
    builder: (_) => const ColorsPage(),
  ),
  GalleryEntry(
    id: 'typography',
    title: 'Typography',
    group: 'Foundations',
    builder: (_) => const TypographyPage(),
  ),
  GalleryEntry(
    id: 'icons',
    title: 'Icons',
    group: 'Foundations',
    builder: (_) => const IconsPage(),
  ),
  GalleryEntry(
    id: 'layers',
    title: 'Layers',
    group: 'Foundations',
    builder: (_) => const LayersPage(),
  ),
  GalleryEntry(
    id: 'density',
    title: 'Density',
    group: 'Foundations',
    builder: (_) => const DensityPage(),
  ),
];
