import 'package:flutter/widgets.dart';

import 'pages/breadcrumb_page.dart';
import 'pages/button_page.dart';
import 'pages/checkbox_page.dart';
import 'pages/compositions/settings_form_page.dart';
import 'pages/compositions/action_toolbar_page.dart';
import 'pages/compositions/row_actions_list_page.dart';
import 'pages/compositions/searchable_picker_page.dart';
import 'pages/compositions/confirmation_flow_page.dart';
import 'pages/contained_list_page.dart';
import 'pages/data_table_page.dart';
import 'pages/content_switcher_page.dart';
import 'pages/dropdown_page.dart';
import 'pages/form_page.dart';
import 'pages/inline_loading_page.dart';
import 'pages/link_page.dart';
import 'pages/loading_page.dart';
import 'pages/menu_page.dart';
import 'pages/menu_button_page.dart';
import 'pages/modal_page.dart';
import 'pages/notification_page.dart';
import 'pages/search_page.dart';
import 'pages/select_page.dart';
import 'pages/tabs_page.dart';
import 'pages/tag_page.dart';
import 'pages/text_input_page.dart';
import 'pages/toggle_page.dart';
import 'pages/tooltip_page.dart';
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
  GalleryEntry(
    id: 'button',
    title: 'Button',
    group: 'Components',
    builder: (_) => const ButtonPage(),
  ),
  GalleryEntry(
    id: 'text-input',
    title: 'Text input',
    group: 'Components',
    builder: (_) => const TextInputPage(),
  ),
  GalleryEntry(
    id: 'form',
    title: 'Form',
    group: 'Components',
    builder: (_) => const FormPage(),
  ),
  GalleryEntry(
    id: 'search',
    title: 'Search',
    group: 'Components',
    builder: (_) => const SearchPage(),
  ),
  GalleryEntry(
    id: 'select',
    title: 'Select',
    group: 'Components',
    builder: (_) => const SelectPage(),
  ),
  GalleryEntry(
    id: 'dropdown',
    title: 'Dropdown',
    group: 'Components',
    builder: (_) => const DropdownPage(),
  ),
  GalleryEntry(
    id: 'checkbox',
    title: 'Checkbox',
    group: 'Components',
    builder: (_) => const CheckboxPage(),
  ),
  GalleryEntry(
    id: 'toggle',
    title: 'Toggle',
    group: 'Components',
    builder: (_) => const TogglePage(),
  ),
  GalleryEntry(
    id: 'tabs',
    title: 'Tabs',
    group: 'Components',
    builder: (_) => const TabsPage(),
  ),
  GalleryEntry(
    id: 'content-switcher',
    title: 'Content switcher',
    group: 'Components',
    builder: (_) => const ContentSwitcherPage(),
  ),
  GalleryEntry(
    id: 'menu',
    title: 'Menu',
    group: 'Components',
    builder: (_) => const MenuPage(),
  ),
  GalleryEntry(
    id: 'menu-button',
    title: 'Menu button',
    group: 'Components',
    builder: (_) => const MenuButtonPage(),
  ),
  GalleryEntry(
    id: 'modal',
    title: 'Modal',
    group: 'Components',
    builder: (_) => const ModalPage(),
  ),
  GalleryEntry(
    id: 'tooltip',
    title: 'Tooltip',
    group: 'Components',
    builder: (_) => const TooltipPage(),
  ),
  GalleryEntry(
    id: 'notification',
    title: 'Notification',
    group: 'Components',
    builder: (_) => const NotificationPage(),
  ),
  GalleryEntry(
    id: 'loading',
    title: 'Loading',
    group: 'Components',
    builder: (_) => const LoadingPage(),
  ),
  GalleryEntry(
    id: 'inline-loading',
    title: 'Inline loading',
    group: 'Components',
    builder: (_) => const InlineLoadingPage(),
  ),
  GalleryEntry(
    id: 'breadcrumb',
    title: 'Breadcrumb',
    group: 'Components',
    builder: (_) => const BreadcrumbPage(),
  ),
  GalleryEntry(
    id: 'link',
    title: 'Link',
    group: 'Components',
    builder: (_) => const LinkPage(),
  ),
  GalleryEntry(
    id: 'tag',
    title: 'Tag',
    group: 'Components',
    builder: (_) => const TagPage(),
  ),
  GalleryEntry(
    id: 'contained-list',
    title: 'Contained list',
    group: 'Components',
    builder: (_) => const ContainedListPage(),
  ),
  GalleryEntry(
    id: 'data-table',
    title: 'Data table',
    group: 'Components',
    builder: (_) => const DataTablePage(),
  ),
  GalleryEntry(
    id: 'settings-form',
    title: 'Settings form',
    group: 'Compositions',
    builder: (_) => const SettingsFormComposition(),
  ),
  GalleryEntry(
    id: 'action-toolbar',
    title: 'Action toolbar',
    group: 'Compositions',
    builder: (_) => const ActionToolbarComposition(),
  ),
  GalleryEntry(
    id: 'row-actions-list',
    title: 'List with row actions',
    group: 'Compositions',
    builder: (_) => const RowActionsListComposition(),
  ),
  GalleryEntry(
    id: 'searchable-picker',
    title: 'Searchable picker',
    group: 'Compositions',
    builder: (_) => const SearchablePickerComposition(),
  ),
  GalleryEntry(
    id: 'confirmation-flow',
    title: 'Confirmation flow',
    group: 'Compositions',
    builder: (_) => const ConfirmationFlowComposition(),
  ),
];
