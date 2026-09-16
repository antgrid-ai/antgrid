/// The tabs the workspace panel can show.
///
/// A model rather than a widget-layer type so `NavLocation` and the deep-link
/// codec can name a tab without importing UI. The label/icon extension
/// ([WorkspaceViewUI]) stays in `widgets/workspace_tab_bar.dart`, which
/// re-exports this enum so widget-layer callers still get both from one import.
///
/// APPEND ONLY. `ProjectPreferences.workspaceViewIndex` persists a raw ordinal
/// (see `WorkspaceShellState._applyPrefs`), so inserting a value moves every
/// saved workspace onto a different tab with nothing to notice it. Dropping the
/// LAST one shifts none, which is what made removing `inbox` a deletion rather
/// than a migration — an install that had it selected falls back on the bounds
/// check `_applyPrefs` already does.
///
/// Not every value need be offered at every moment; the single rule for that is
/// `visibleWorkspaceViewsProvider`, and nothing may render `values` directly.
enum WorkspaceView { preview, files, git, terminals, handler }
