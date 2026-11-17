import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Built-in strings used by Carbon components. English by default.
///
/// Supply translations either through the app's localization delegates
/// ([delegateFor]) or for a subtree with [CarbonLocalizationsScope]. Text
/// direction comes from the host's [Directionality].
@immutable
class CarbonLocalizations {
  const CarbonLocalizations({
    this.clear = 'Clear',
    this.clearSearch = 'Clear search',
    this.showPassword = 'Show password',
    this.hidePassword = 'Hide password',
    this.close = 'Close',
    this.loading = 'Loading',
    this.noResults = 'No results',
    this.search = 'Search',
    this.requiredField = 'Required',
    this.optionalField = '(optional)',
    this.invalid = 'Invalid',
    this.menu = 'Menu',
    this.openMenu = 'Open menu',
    this.moreOptions = 'Options',
    this.back = 'Back',
    this.selectPlaceholder = 'Choose an option',
    this.error = 'Error',
    this.warning = 'Warning',
    this.success = 'Success',
    this.info = 'Information',
    this.dismissNotification = 'Close notification',
    this.scrollBackward = 'Scroll back',
    this.scrollForward = 'Scroll forward',
    this.retry = 'Retry',
    this.on = 'On',
    this.off = 'Off',
    this.unavailableValue = 'Unavailable',
    this.sideNavigation = 'Side navigation',
    String Function(int count)? resultCount,
    String Function(String label)? removeItem,
  }) : _resultCount = resultCount,
       _removeItem = removeItem;

  final String clear;
  final String clearSearch;
  final String showPassword;
  final String hidePassword;
  final String close;
  final String loading;
  final String noResults;
  final String search;

  /// Announced for required fields. The visible marker is not color alone.
  final String requiredField;
  final String optionalField;
  final String invalid;
  final String menu;
  final String openMenu;

  /// Accessible name for an overflow (⋯) trigger.
  final String moreOptions;
  final String back;
  final String selectPlaceholder;
  final String error;
  final String warning;
  final String success;
  final String info;
  final String dismissNotification;
  final String scrollBackward;
  final String scrollForward;
  final String retry;

  /// The visible state word beside a toggle that is on, so its value is never
  /// carried by color alone.
  final String on;
  final String off;

  /// Shown by a select or dropdown whose committed value is not among its
  /// options. The value is displayed as unavailable, never replaced.
  final String unavailableValue;

  /// The default name of a side navigation landmark.
  final String sideNavigation;
  final String Function(int count)? _resultCount;
  final String Function(String label)? _removeItem;

  /// "1 result" / "3 results".
  String resultCount(int count) =>
      _resultCount?.call(count) ?? (count == 1 ? '1 result' : '$count results');

  /// Accessible name for a tag's remove action: "Remove <label>".
  String removeItem(String label) =>
      _removeItem?.call(label) ?? 'Remove $label';

  static const CarbonLocalizations english = CarbonLocalizations();

  /// The nearest messages: a [CarbonLocalizationsScope], then the app's
  /// [Localizations], then [english].
  static CarbonLocalizations of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<CarbonLocalizationsScope>()
          ?.messages ??
      Localizations.of<CarbonLocalizations>(context, CarbonLocalizations) ??
      english;

  /// English for every locale.
  static const LocalizationsDelegate<CarbonLocalizations> delegate =
      _CarbonLocalizationsDelegate(null);

  /// A delegate resolving messages per locale; [english] where [resolve]
  /// returns null.
  static LocalizationsDelegate<CarbonLocalizations> delegateFor(
    CarbonLocalizations? Function(Locale locale) resolve,
  ) => _CarbonLocalizationsDelegate(resolve);
}

class _CarbonLocalizationsDelegate
    extends LocalizationsDelegate<CarbonLocalizations> {
  const _CarbonLocalizationsDelegate(this._resolve);

  final CarbonLocalizations? Function(Locale locale)? _resolve;

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<CarbonLocalizations> load(Locale locale) =>
      SynchronousFuture<CarbonLocalizations>(
        _resolve?.call(locale) ?? CarbonLocalizations.english,
      );

  @override
  bool shouldReload(_CarbonLocalizationsDelegate old) =>
      old._resolve != _resolve;
}

/// Overrides [CarbonLocalizations] for a subtree.
class CarbonLocalizationsScope extends InheritedWidget {
  const CarbonLocalizationsScope({
    super.key,
    required this.messages,
    required super.child,
  });

  final CarbonLocalizations messages;

  @override
  bool updateShouldNotify(CarbonLocalizationsScope old) =>
      !identical(old.messages, messages);
}
