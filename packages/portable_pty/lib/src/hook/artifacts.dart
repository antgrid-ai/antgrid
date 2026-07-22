import 'package:code_assets/code_assets.dart';

/// Rust library stem used by portable_pty native assets.
const String portablePtyLibraryStem = 'portable_pty_rs';

/// Prebuilt PTY artifacts produced by the release workflow.
const Map<String, String> portablePtyPrebuiltArtifacts = {
  'linux-x64': 'pty-linux-x64.tar.gz',
  'linux-arm64': 'pty-linux-arm64.tar.gz',
  'macos-arm64': 'pty-macos-arm64.tar.gz',
  'macos-x64': 'pty-macos-x64.tar.gz',
  'windows-x64': 'pty-windows-x64.tar.gz',
  'windows-arm64': 'pty-windows-arm64.tar.gz',
  'android-arm64': 'pty-android-arm64.tar.gz',
  'android-arm': 'pty-android-arm.tar.gz',
  'android-x64': 'pty-android-x64.tar.gz',
  'ios-arm64': 'pty-ios-arm64.tar.gz',
  'ios-sim-arm64': 'pty-ios-sim-arm64.tar.gz',
  'ios-sim-x64': 'pty-ios-sim-x64.tar.gz',
};

/// Returns the link mode used for the portable_pty native asset.
///
/// VENDORED PATCH (diverges from pub.dev portable_pty 0.0.5): upstream forces
/// `StaticLinking()` for ALL iOS, but current Flutter's iOS native-assets driver
/// (device AND simulator) requests a `dynamic` preference and rejects a static
/// CodeAsset ("link mode static not allowed by preference dynamic"). So we honour
/// the requested preference on every target, iOS included — dynamic yields a
/// cdylib that the build hook compiles from source (the crate already declares
/// `crate-type=["staticlib","cdylib"]`) and the archive embeds + re-signs into
/// `.app/Frameworks/`. iOS is relay-only (the sandbox forbids local PTYs), so the
/// lib is never *called* — only load-time linking matters. Because the download
/// gate (`_canDownloadPrebuilt` in build.dart) only fetches iOS prebuilts for
/// StaticLinking, a dynamic iOS build correctly skips the static upstream tarball
/// and builds from source instead. Keep until upstream respects the iOS
/// link-mode preference — kingwill101/dart_terminal.
LinkMode portablePtyLinkModeForBuild(CodeConfig code) {
  return switch (code.linkModePreference) {
    LinkModePreference.dynamic ||
    LinkModePreference.preferDynamic => DynamicLoadingBundled(),
    LinkModePreference.static ||
    LinkModePreference.preferStatic => StaticLinking(),
    _ => throw UnsupportedError(
      'Unsupported LinkModePreference: ${code.linkModePreference}',
    ),
  };
}

/// Returns the library filename expected by the Dart native-assets runtime.
String portablePtyLibraryNameForBuild(CodeConfig code) {
  return code.targetOS.libraryFileName(
    portablePtyLibraryStem,
    portablePtyLinkModeForBuild(code),
  );
}

/// Returns the platform label used for PTY prebuilt artifacts.
String portablePtyPlatformLabelForBuild(CodeConfig code) {
  return portablePtyPlatformLabel(
    code.targetOS,
    code.targetArchitecture,
    iOSSdk: code.targetOS == OS.iOS ? code.iOS.targetSdk : null,
  );
}

/// Returns a platform label like `linux-x64` or `ios-sim-arm64`.
String portablePtyPlatformLabel(OS os, Architecture arch, {IOSSdk? iOSSdk}) {
  final archLabel = switch (arch) {
    Architecture.x64 => 'x64',
    Architecture.arm64 => 'arm64',
    Architecture.arm => 'arm',
    Architecture.ia32 => 'x86',
    _ => arch.toString(),
  };
  final osLabel = switch (os) {
    OS.linux => 'linux',
    OS.macOS => 'macos',
    OS.windows => 'windows',
    OS.android => 'android',
    OS.iOS => 'ios',
    _ => os.toString(),
  };

  if (os == OS.iOS) {
    if (iOSSdk == IOSSdk.iPhoneSimulator || arch == Architecture.x64) {
      return 'ios-sim-$archLabel';
    }
  }

  return '$osLabel-$archLabel';
}
