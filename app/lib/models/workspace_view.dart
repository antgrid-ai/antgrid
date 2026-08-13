/// The tabs the workspace panel can show.
///
/// A model rather than a widget-layer type so `NavLocation` and the deep-link
/// codec can name a tab without importing UI. The label/icon extension
/// ([WorkspaceViewUI]) stays in `widgets/workspace_tab_bar.dart`, which
/// re-exports this enum so widget-layer callers still get both from one import.
enum WorkspaceView { preview, files, git, terminals, handler }
