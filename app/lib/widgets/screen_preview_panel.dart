import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_chip.dart';
import '../design/widgets/ab_empty_state.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_inline_banner.dart';
import '../design/widgets/ab_list_row.dart';
import '../design/widgets/ab_loading.dart';
import '../design/widgets/ab_toolbar.dart';
import '../models/screen_models.dart';
import '../providers/providers.dart';
import '../providers/remote_access.dart';
import '../providers/screen_control.dart';
import '../services/screen_share_backend.dart';
import '../services/screen_share_service.dart';
import '../services/screen_view_service.dart';
import 'remote_access_panel.dart';
import 'screen_remote_input_surface.dart';
import 'screen_window_picker.dart';

/// Renders one [ScreenViewState]. Pure: every affordance is a callback, so the
/// full state machine can be pinned without a peer connection.
///
/// Every wire status has a state here, including the ones that carry no picture.
/// A screen session that produced nothing is the case most likely to reach a
/// user, and a blank rectangle is the one thing it must never look like.
class ScreenViewStateView extends StatelessWidget {
  const ScreenViewStateView({
    super.key,
    required this.state,
    this.liveBody,
    this.onRequest,
    this.onHostPicks,
    this.onPickWindow,
    this.onStop,
    this.onToggleControl,
  });

  final ScreenViewState state;

  /// The video and its input capture, supplied by whoever owns the service.
  /// Null until the first frame, which is a real state of its own rather than
  /// an empty [ScreenViewStage.live].
  final Widget? liveBody;

  /// Ask for a session this device will choose the window for.
  final VoidCallback? onRequest;

  /// Ask for a session the person at the other machine chooses the window for.
  /// Kept beside [onRequest] because the two are not interchangeable: this one
  /// needs someone there to answer it.
  final VoidCallback? onHostPicks;

  final ValueChanged<String>? onPickWindow;
  final VoidCallback? onStop;
  final ValueChanged<bool>? onToggleControl;

  @override
  Widget build(BuildContext context) {
    switch (state.stage) {
      case ScreenViewStage.idle:
        return AbEmptyState(
          icon: AbIcons.deviceDesktop,
          title: 'Preview a desktop app',
          subtitle:
              'Ask this machine for its open windows and pick one to watch and '
              'control. Nothing is captured until you choose.',
          action: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AbButton(
                key: const Key('screen-view-request'),
                label: 'Choose a window',
                variant: AbButtonVariant.primary,
                onTap: onRequest,
              ),
              const SizedBox(height: AbTokens.space8),
              // Still worth offering: someone at that machine can pick a window
              // this device is not allowed to enumerate, and they may prefer to.
              AbButton(
                key: const Key('screen-view-request-host-picks'),
                label: 'Let them pick instead',
                onTap: onHostPicks,
              ),
            ],
          ),
        );

      case ScreenViewStage.requesting:
        return const AbLoading(message: 'asking the desktop app...');

      case ScreenViewStage.choosingWindow:
        return _RemoteWindowList(
          windows: state.windows,
          onPick: onPickWindow,
          onCancel: onStop,
        );

      case ScreenViewStage.noHost:
        return AbEmptyState.error(
          icon: AbIcons.deviceDesktop,
          title: 'No desktop app running there',
          subtitle:
              state.reason ??
              'Window sharing needs the Antgrid desktop app open on that '
                  'machine — the bridge alone has no windows to capture.',
          action: AbButton(label: 'Try again', onTap: onRequest),
        );

      case ScreenViewStage.awaitingConsent:
        return AbEmptyState(
          icon: AbIcons.shield,
          title: 'Waiting for a window to be picked',
          subtitle:
              'Choose a window in Antgrid on that machine. Nothing is captured '
              'until then.',
          action: AbButton(label: 'Cancel', onTap: onStop),
        );

      case ScreenViewStage.connecting:
        return AbLoading(
          message: state.windowTitle == null
              ? 'connecting...'
              : 'connecting to ${state.windowTitle}...',
        );

      case ScreenViewStage.live:
      case ScreenViewStage.interrupted:
        return Column(
          children: [
            _LiveHeader(
              title: state.windowTitle,
              frameSize: state.frameSize,
              controlEnabled: state.controlEnabled,
              onToggleControl: onToggleControl,
              onStop: onStop,
            ),
            // The last frame stays on screen — the texture is still there and
            // the path is expected back. The banner is the whole point: without
            // it a frozen picture reads as a working session.
            if (state.stage == ScreenViewStage.interrupted)
              AbInlineBanner(
                text: state.reason ?? kViewerInterruptedReason,
                color: context.antgrid.warning,
              ),
            Expanded(
              child:
                  liveBody ??
                  const AbLoading(message: 'waiting for the first frame...'),
            ),
          ],
        );

      case ScreenViewStage.ended:
        final minimised = state.reason == kMinimisedReason;
        return AbEmptyState.error(
          icon: minimised ? AbIcons.warning : AbIcons.error,
          title: minimised
              ? 'That window was minimised'
              : 'The screen session ended',
          subtitle:
              state.reason ??
              'The host stopped sharing. Ask again to start a new session.',
          action: AbButton(label: 'Ask again', onTap: onRequest),
        );

      case ScreenViewStage.unsupported:
        return AbEmptyState.error(
          icon: AbIcons.deviceDesktop,
          title: 'Not available here',
          subtitle: state.reason ?? kViewerUnsupportedReason,
        );
    }
  }
}

/// The host's window catalog, on the device that asked for it.
///
/// Titles only, and no thumbnails — that is the wire's shape rather than this
/// widget's economy (see `screen:windows`). Rows are deliberately plain: a
/// picture of a window nobody has agreed to share yet is exactly what this list
/// must not contain.
class _RemoteWindowList extends StatelessWidget {
  const _RemoteWindowList({
    required this.windows,
    required this.onPick,
    required this.onCancel,
  });

  final List<ScreenWindowEntry> windows;
  final ValueChanged<String>? onPick;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    if (windows.isEmpty) {
      return AbEmptyState(
        key: const Key('screen-view-no-windows'),
        icon: AbIcons.browser,
        title: 'No shareable windows',
        subtitle: 'That machine has nothing capturable open.',
        action: AbButton(label: 'Cancel', onTap: onCancel),
      );
    }
    return Column(
      key: const Key('screen-view-window-list'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AbToolbar.custom(
          height: AbTokens.rowHeightSm,
          children: [
            const SizedBox(width: AbTokens.space8),
            Expanded(
              child: Text(
                'Pick a window to control',
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXs,
                  color: context.antgrid.textPrimary,
                ),
              ),
            ),
            AbButton(label: 'Cancel', onTap: onCancel),
            const SizedBox(width: AbTokens.space4),
          ],
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: AbTokens.space8),
            itemCount: windows.length,
            itemBuilder: (context, index) {
              final window = windows[index];
              return AbListRow(
                key: ValueKey(window.id),
                hoverable: true,
                leading: AbIcon(
                  window.minimised ? AbIcons.chevronDown : AbIcons.browser,
                  size: AbTokens.iconButtonGlyph,
                  color: context.antgrid.textMuted,
                ),
                title: Text(window.title),
                // Said before the tap, not after: this window is out of sight on
                // that machine and picking it puts it back on screen there.
                subtitle: window.minimised
                    ? Text(
                        'minimised — will be restored on that machine',
                        style: AbTokens.sansStyle(
                          fontSize: AbTokens.fontXxs,
                          color: context.antgrid.textMuted,
                        ),
                      )
                    : null,
                onTap: onPick == null ? null : () => onPick!(window.id),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _LiveHeader extends StatelessWidget {
  const _LiveHeader({
    required this.title,
    required this.frameSize,
    required this.controlEnabled,
    required this.onToggleControl,
    required this.onStop,
  });

  final String? title;
  final ScreenFrameSize? frameSize;
  final bool controlEnabled;
  final ValueChanged<bool>? onToggleControl;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final palette = context.antgrid;
    return AbToolbar.custom(
      height: AbTokens.rowHeightSm,
      children: [
        const SizedBox(width: AbTokens.space8),
        AbIcon(
          AbIcons.deviceDesktop,
          size: AbTokens.iconButtonGlyph,
          color: palette.accent,
        ),
        const SizedBox(width: AbTokens.space8),
        Expanded(
          child: Text(
            title ?? 'Shared window',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXs,
              color: palette.textPrimary,
            ),
          ),
        ),
        if (frameSize != null) ...[
          const SizedBox(width: AbTokens.space8),
          Text(
            '$frameSize',
            style: AbTokens.monoStyle(
              fontSize: AbTokens.fontXxs,
              color: palette.textMuted,
            ),
          ),
        ],
        const SizedBox(width: AbTokens.space8),
        AbChip.toggle(
          label: 'Control',
          selected: controlEnabled,
          color: palette.accent,
          onTap: onToggleControl == null
              ? null
              : () => onToggleControl!(!controlEnabled),
        ),
        const SizedBox(width: AbTokens.space8),
        AbButton(label: 'Stop', onTap: onStop),
        const SizedBox(width: AbTokens.space4),
      ],
    );
  }
}

/// A machine switch this feature needs that is currently off.
///
/// Ordered outer-to-inner, and resolved in that order: screen control grants
/// nothing while remote access is off, so fixing the inner one first would just
/// walk the user into the outer wall a tap later.
enum ScreenHostBlocker {
  /// Nothing can reach this machine, so a share would have no possible viewer.
  remoteAccessOff,

  /// The bridge will refuse the capture outright.
  screenControlOff,
}

/// Renders one [ScreenShareState] — the machine that owns the window.
class ScreenHostStateView extends StatelessWidget {
  const ScreenHostStateView({
    super.key,
    required this.state,
    required this.canHost,
    this.blocker,
    this.onChooseWindow,
    this.onStop,
    this.onResolveBlocker,
  });

  final ScreenShareState state;

  /// False on a platform with no capture backend. The host still gets a named
  /// state, because "the button does nothing" is the alternative.
  final bool canHost;

  /// The highest unmet precondition, or null when the machine is ready — or
  /// when its switches have not been read yet, which is NOT the same thing and
  /// must not be reported as one. Advisory only: the bridge remains the only
  /// thing that authorizes a capture, and this just stops the panel offering
  /// work it can already see being refused.
  final ScreenHostBlocker? blocker;

  final VoidCallback? onChooseWindow;
  final VoidCallback? onStop;
  final VoidCallback? onResolveBlocker;

  @override
  Widget build(BuildContext context) {
    if (!canHost) {
      return const AbEmptyState.error(
        icon: AbIcons.deviceDesktop,
        title: 'Window sharing is not available here',
        subtitle: kUnsupportedPlatformReason,
      );
    }
    switch (state.stage) {
      case ScreenShareStage.idle:
        return switch (blocker) {
          ScreenHostBlocker.remoteAccessOff => AbEmptyState(
            key: const Key('screen-host-blocked-remote-access'),
            icon: AbIcons.radioTower,
            title: 'Nothing can reach this machine',
            subtitle:
                'Remote access is off, so no device could connect to watch a '
                'window. Turn it on to share.',
            action: AbButton(
              label: 'Turn on remote access',
              variant: AbButtonVariant.primary,
              onTap: onResolveBlocker,
            ),
          ),
          ScreenHostBlocker.screenControlOff => AbEmptyState(
            key: const Key('screen-host-blocked-screen-control'),
            icon: AbIcons.shield,
            title: 'Screen control is off',
            subtitle:
                'This machine will not share a window, or list what it has open, '
                'until its screen-control switch is on.',
            action: AbButton(
              label: 'Turn on screen control',
              variant: AbButtonVariant.primary,
              onTap: onResolveBlocker,
            ),
          ),
          null => AbEmptyState(
            icon: AbIcons.deviceDesktop,
            title: 'Share a window',
            subtitle:
                'Pick one window to offer your other devices. Nothing else on '
                'this screen is captured, and nothing leaves this machine until '
                'a device connects.',
            action: AbButton(
              label: 'Choose a window',
              variant: AbButtonVariant.primary,
              onTap: onChooseWindow,
            ),
          ),
        };

      case ScreenShareStage.awaitingConsent:
        return AbEmptyState(
          icon: AbIcons.shield,
          title: 'A device asked to see a window',
          subtitle:
              'Pick the window to stream. Until you do, nothing is captured.',
          action: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AbButton(
                label: 'Choose a window',
                variant: AbButtonVariant.primary,
                onTap: onChooseWindow,
              ),
              const SizedBox(width: AbTokens.space8),
              AbButton(label: 'Decline', onTap: onStop),
            ],
          ),
        );

      // The catalog is out and the other device is choosing. Shown rather than
      // left blank because this is the one moment a list of this machine's open
      // windows exists on another device, and the person here should be able to
      // see that happening and stop it.
      case ScreenShareStage.awaitingPick:
        return AbEmptyState(
          key: const Key('screen-host-awaiting-pick'),
          icon: AbIcons.shield,
          title: 'A device is choosing a window',
          subtitle:
              'It has the titles of your open windows. Nothing is captured '
              'until it picks one.',
          action: AbButton(label: 'Cancel', onTap: onStop),
        );

      case ScreenShareStage.starting:
        return const AbLoading(message: 'starting capture...');

      case ScreenShareStage.live:
      case ScreenShareStage.interrupted:
        return _HostLiveView(state: state, onStop: onStop);

      case ScreenShareStage.failed:
        return AbEmptyState.error(
          icon: state.reason == kMinimisedReason
              ? AbIcons.warning
              : AbIcons.error,
          title: 'Sharing stopped',
          subtitle: state.reason ?? 'The capture ended unexpectedly.',
          action: AbButton(label: 'Choose a window', onTap: onChooseWindow),
        );
    }
  }
}

class _HostLiveView extends StatelessWidget {
  const _HostLiveView({required this.state, required this.onStop});

  final ScreenShareState state;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final palette = context.antgrid;
    final size = state.frameSize;
    final interrupted = state.stage == ScreenShareStage.interrupted;
    // Armed, but nobody has ever connected. Not an anomaly — it is what the
    // host-initiated flow looks like until a device picks the offer up, and
    // saying "sharing" here claims something that is not happening.
    final waiting = !interrupted && !state.viewerConnected;
    final window = state.windowTitle ?? 'a window';
    return AbEmptyState(
      key: waiting ? const Key('screen-host-awaiting-viewer') : null,
      icon: interrupted ? AbIcons.warning : AbIcons.radioTower,
      title: switch ((interrupted, waiting)) {
        (true, _) => 'Reconnecting to the viewer',
        (_, true) => 'Ready to share “$window”',
        _ => 'Sharing “$window”',
      },
      subtitle: waiting
          ? 'Waiting for a device to connect. Nothing is leaving this machine '
                'yet.'
          : size == null
          ? 'Streaming to your other device.'
          : '$size',
      action: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Input can only be judged against a viewer that exists. With none,
          // "remote control is unavailable" is true of every session in this
          // state and reads as a fault in this one. A reason alongside ACTIVE
          // input is the recoverable kind — a refused foreground raise — and
          // still has to be said, or the viewer's clicks vanish unexplained.
          if (interrupted ||
              (!waiting && (!state.inputActive || state.reason != null)))
            Padding(
              padding: const EdgeInsets.only(bottom: AbTokens.space8),
              child: Text(
                state.reason ??
                    'Remote control is unavailable in this session.',
                textAlign: TextAlign.center,
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXxs,
                  color: palette.warning,
                ),
              ),
            ),
          AbButton(label: 'Stop sharing', onTap: onStop),
        ],
      ),
    );
  }
}

/// The native-window mode of the preview panel.
///
/// Resolves which half of the feature this project is: a LOOPBACK session is the
/// machine that owns the windows, so it gets the host controls, and a RELAY
/// session is somebody else's machine, so it gets the viewer.
class ScreenPreviewPanel extends ConsumerWidget {
  const ScreenPreviewPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = serviceWhenReady(ref, screenViewServiceProvider);
    if (view == null) return const AbLoading(message: 'opening project...');
    return view.canView ? const _ViewerSurface() : const _HostSurface();
  }
}

class _ViewerSurface extends ConsumerWidget {
  const _ViewerSurface();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = serviceWhenReady(ref, screenViewServiceProvider);
    final state =
        ref.watch(screenViewStateProvider).value ??
        service?.currentState ??
        const ScreenViewState();
    if (service == null) return const AbLoading(message: 'opening project...');

    // Read through the service every frame rather than caching: the peer owns
    // the renderer, so this is a reference to a widget that outlives any rebuild
    // — including the unmount/remount a desktop panel-mode toggle would cause if
    // the GlobalKey reparent ever failed.
    final video = service.videoView;
    final frameSize = state.frameSize;
    final liveBody = (video == null || frameSize == null)
        ? null
        : ScreenRemoteInputSurface(
            frameSize: frameSize,
            enabled: state.controlEnabled,
            onPointer: (action, frame, button) => service.sendPointer(
              action: action,
              frame: frame,
              button: button,
            ),
            onScroll: (frame, dx, dy) =>
                service.sendScroll(frame: frame, deltaX: dx, deltaY: dy),
            onKey: (vk, down) => service.sendKey(vk, down: down),
            onText: service.sendText,
            child: video,
          );

    return ScreenViewStateView(
      state: state,
      liveBody: liveBody,
      onRequest: () => unawaited(service.requestSession()),
      onHostPicks: () =>
          unawaited(service.requestSession(chooser: ScreenChooser.host)),
      onPickWindow: service.pickWindow,
      onStop: () => unawaited(service.stopSession('Stopped from the viewer')),
      onToggleControl: service.setControlEnabled,
    );
  }
}

class _HostSurface extends ConsumerWidget {
  const _HostSurface();

  /// Flip the switch the preflight named, behind the same confirm the remote
  /// access panel uses. Both notifiers are read BEFORE the dialog: this panel
  /// can be rebuilt out from under the await, and a `WidgetRef` read afterwards
  /// would land on a dead element.
  Future<void> _resolve(
    BuildContext context,
    WidgetRef ref,
    ScreenHostBlocker blocker,
  ) async {
    switch (blocker) {
      case ScreenHostBlocker.remoteAccessOff:
        final notifier = ref.read(remoteAccessPolicyProvider.notifier);
        if (await confirmRemoteAccessOn(context)) {
          await notifier.setEnabled(true);
        }
      case ScreenHostBlocker.screenControlOff:
        final notifier = ref.read(screenControlSwitchProvider.notifier);
        if (await confirmScreenControlOn(context)) {
          await notifier.setEnabled(true);
        }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = serviceWhenReady(ref, screenShareServiceProvider);
    final state =
        ref.watch(screenShareStateProvider).value ??
        service?.currentState ??
        const ScreenShareState();
    if (service == null) return const AbLoading(message: 'opening project...');

    // Only a switch KNOWN to be off blocks. A read that has not landed yet, or
    // one that failed, leaves the offer in place: telling the user to fix a
    // setting that may already be correct is worse than letting the attempt
    // through and reporting what the bridge actually said.
    final remoteOff =
        ref.watch(remoteAccessPolicyProvider).value?.enabled == false;
    final screenOff = ref.watch(screenControlSwitchProvider).value == false;
    final blocker = remoteOff
        ? ScreenHostBlocker.remoteAccessOff
        : screenOff
        ? ScreenHostBlocker.screenControlOff
        : null;

    return ScreenHostStateView(
      state: state,
      canHost: service.canHost,
      blocker: blocker,
      onChooseWindow: () => unawaited(pickAndShareWindow(context, service)),
      onStop: () => unawaited(service.stopSession('Stopped on this machine')),
      onResolveBlocker: blocker == null
          ? null
          : () => unawaited(_resolve(context, ref, blocker)),
    );
  }
}

/// Opens the local picker and starts the session on the chosen window.
///
/// Shared by the preview panel and the consent gate so a request that arrives
/// while the user is on another tab reaches exactly the same dialog.
Future<void> pickAndShareWindow(
  BuildContext context,
  ScreenShareService service, {
  String? prompt,
}) async {
  final windowId = await showScreenWindowPicker(
    context,
    listWindows: service.listWindows,
    windowUpdates: service.windowUpdates,
    prompt: prompt,
  );
  if (windowId == null) {
    // Closing the picker on a pending request is the decline. Left unanswered,
    // the asking device waits forever and holds the session against every
    // other device.
    if (service.currentState.stage == ScreenShareStage.awaitingConsent) {
      await service.stopSession(kConsentDeclinedReason);
    }
    return;
  }
  await service.startSession(windowId);
}
