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
  static const server = Codicon.server;
  static const scan =
      Codicon.device_camera; // QR scan (no QR glyph in Codicons)
  static const link = Codicon.link;
  static const add = Codicon.add;
  static const trash = Codicon.trash;
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
  static const code = Codicon.code;
  // Unchecked-state indicator for toggle rows (outline only, no fill).
  static const circle = Codicon.circle_large_outline;
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
}
