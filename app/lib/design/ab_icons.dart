import 'package:iconify_flutter/icons/codicon.dart';
import 'package:iconify_flutter/icons/mdi.dart';

/// Icon constants using VS Code Codicons via Iconify (SVG-rendered).
abstract final class AbIcons {
  static const preview = Codicon.browser;
  static const files = Codicon.files;
  static const git = Codicon.source_control;
  static const terminal = Codicon.terminal;
  static const comment = Codicon.comment;
  static const services = Codicon.server_process;
  static const settings = Codicon.settings_gear;
  static const account = Codicon.account;
  static const signIn = Codicon.sign_in;
  static const signOut = Codicon.sign_out;
  // MDI, not Codicon: the Codicon set has no diagonal expand/collapse pair
  // (`screen_full`/`screen_normal` are bracketed boxes that read as "fullscreen
  // the window" rather than "grow this pane").
  static const expand = Mdi.arrow_expand;
  static const collapse = Mdi.arrow_collapse;
  static const close = Codicon.close;
  // Pane-visibility toggle, macOS/Xcode convention: the glyph depicts the
  // CURRENT state (filled edge = pane showing), not the result of clicking.
  static const layoutSidebarRight = Codicon.layout_sidebar_right;
  static const layoutSidebarRightOff = Codicon.layout_sidebar_right_off;
  static const layoutSidebarLeft = Codicon.layout_sidebar_left;
  static const layoutSidebarLeftOff = Codicon.layout_sidebar_left_off;
  // The workspace views as one thing, for the agent bar's menu into them.
  // Deliberately not a sidebar glyph: in chat mode there is no pane to point
  // at — the views arrive as a floating card.
  static const workspace = Codicon.layout;
  static const back = Codicon.arrow_left;
  static const chevronLeft = Codicon.chevron_left;
  static const chevronRight = Codicon.chevron_right;
  static const chevronDown = Codicon.chevron_down;
  static const chevronUp = Codicon.chevron_up;
  static const refresh = Codicon.refresh;
  static const revert = Codicon.discard;
  static const pin = Codicon.pin;
  static const unpin = Codicon.pinned;
  static const start = Codicon.play;
  static const stop = Codicon.stop_circle;
  static const restart = Codicon.debug_restart;
  static const send = Codicon.arrow_right;
  static const shield = Codicon.shield;
  static const search = Codicon.search;
  static const arrowUp = Codicon.arrow_up;
  static const arrowDown = Codicon.arrow_down;
  static const copy = Codicon.copy;
  static const check = Codicon.check;
  static const deviceMobile = Codicon.device_mobile;
  static const deviceDesktop =
      Codicon.vm; // closest to "remote desktop machine" in Codicons
  static const radioTower = Codicon.radio_tower; // machine reachable remotely
  static const server = Codicon.server;
  static const link = Codicon.link;
  static const openExternal = Codicon.link_external;
  static const elementPicker = Codicon.inspect;
  // "edit" is VS Code's pencil glyph — reads as "mark this up", distinct
  // from the pointer-shaped [elementPicker].
  static const draw = Codicon.edit;
  static const undo = Codicon.discard;
  // MDI, not Codicon: the Codicon set has no shape-drawing primitives at all
  // — `primitive_square`/`circle_large_outline` are filled status dots drawn
  // for list decoration, not outlines that read as "draw a box here".
  static const drawLine = Mdi.vector_line;
  static const drawRect = Mdi.rectangle_outline;
  static const drawEllipse = Mdi.ellipse_outline;
  static const drawText = Mdi.format_text;
  static const previewTabs = Codicon.multiple_windows;
  static const add = Codicon.add;
  static const trash = Codicon.trash;
  // Alias mirroring `add`; semantic for git's stage-changes action.
  static const gitStage = Codicon.add;
  // VS Code's own codicon name for its unstage/"−" action.
  static const gitUnstage = Codicon.remove;
  static const menu = Codicon.menu;
  static const more = Codicon.kebab_vertical;
  static const list = Codicon.list_unordered;
  static const browser =
      Codicon.browser; // alias mirroring `preview`; semantic for empty states
  static const folder = Codicon.folder;
  static const newFolder =
      Codicon.new_folder; // folder + plus (add-local action)
  static const fileBinary = Codicon.file_binary;
  static const error = Codicon.error;
  static const warning = Codicon.warning;
  static const info = Codicon.info;
  static const bell = Codicon.bell;
  static const gitCommit = Codicon.git_commit;
  static const gitBranch = Codicon.source_control;
  static const code = Codicon.code;
  // Unchecked-state indicator for toggle rows (outline only, no fill).
  static const circle = Codicon.circle_large_outline;
  // Checked partner to [circle] — the same disc, filled, with the check
  // inside, so a toggle's two states differ in weight as well as in glyph.
  static const circleCheck = Codicon.pass_filled;
  static const upload = Codicon.cloud_upload;
  static const zoomIn = Codicon.zoom_in;
  static const zoomOut = Codicon.zoom_out;
  // Codicons ship no paperclip — Mdi's is the one non-codicon glyph. Route
  // any future exceptions through here so this file stays the icon choke
  // point.
  static const attach = Mdi.paperclip;
  // Codicons ship no literal keyboard glyph; record_keys (key caps) is VS
  // Code's own keyboard-shortcuts icon.
  static const keyboard = Codicon.record_keys;
  // Reveal/mask pair for secret fields. The glyph depicts the ACTION, not the
  // state: [eye] while the value is masked (tap to reveal), [eyeClosed] while
  // it is showing (tap to hide) — the convention every password manager uses.
  static const eye = Codicon.eye;
  static const eyeClosed = Codicon.eye_closed;
  // A session running off its own workspace. The fork glyph reads as "split
  // off from the main line" without naming a backend — the marker stands for
  // every non-`main` checkout kind, not for worktrees specifically.
  static const isolated = Codicon.repo_forked;
  // More than one session working in one directory. The collaborative-session
  // glyph, because what the marker reports is company rather than a place:
  // paired against [isolated], which says a session has a workspace to itself.
  static const sharedWorkspace = Codicon.live_share;
  // Sign-in method glyphs. `key` rather than `lock`: the cell offers a
  // credential the user supplies, not a state of being secured.
  static const password = Codicon.key;
  static const github = Codicon.github;
}
