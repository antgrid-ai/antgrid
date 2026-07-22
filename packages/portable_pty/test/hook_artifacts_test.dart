import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:portable_pty/src/hook/artifacts.dart';
import 'package:test/test.dart';

void main() {
  group('portablePtyPlatformLabel', () {
    test('labels desktop and mobile targets', () {
      expect(portablePtyPlatformLabel(OS.linux, Architecture.x64), 'linux-x64');
      expect(
        portablePtyPlatformLabel(OS.windows, Architecture.arm64),
        'windows-arm64',
      );
      expect(
        portablePtyPlatformLabel(OS.android, Architecture.arm),
        'android-arm',
      );
      expect(
        portablePtyPlatformLabel(
          OS.iOS,
          Architecture.arm64,
          iOSSdk: IOSSdk.iPhoneOS,
        ),
        'ios-arm64',
      );
      expect(
        portablePtyPlatformLabel(
          OS.iOS,
          Architecture.arm64,
          iOSSdk: IOSSdk.iPhoneSimulator,
        ),
        'ios-sim-arm64',
      );
      expect(portablePtyPlatformLabel(OS.iOS, Architecture.x64), 'ios-sim-x64');
    });

    test('tracks every prebuilt workflow target', () {
      expect(portablePtyPrebuiltArtifacts.keys.toSet(), {
        'linux-x64',
        'linux-arm64',
        'macos-arm64',
        'macos-x64',
        'windows-x64',
        'windows-arm64',
        'android-arm64',
        'android-arm',
        'android-x64',
        'ios-arm64',
        'ios-sim-arm64',
        'ios-sim-x64',
      });
    });
  });

  group('portablePtyLinkModeForBuild', () {
    test('uses static libraries for iOS device builds', () async {
      await testCodeBuildHook(
        mainMethod: _noopBuildHook,
        targetOS: OS.iOS,
        targetArchitecture: Architecture.arm64,
        targetIOSSdk: IOSSdk.iPhoneOS,
        linkModePreference: LinkModePreference.preferDynamic,
        check: (input, output) {
          final code = input.config.code;
          expect(portablePtyLinkModeForBuild(code), isA<StaticLinking>());
          expect(portablePtyLibraryNameForBuild(code), 'libportable_pty_rs.a');
          expect(portablePtyPlatformLabelForBuild(code), 'ios-arm64');
        },
      );
    });

    test('uses static libraries for iOS simulator builds', () async {
      await testCodeBuildHook(
        mainMethod: _noopBuildHook,
        targetOS: OS.iOS,
        targetArchitecture: Architecture.arm64,
        targetIOSSdk: IOSSdk.iPhoneSimulator,
        linkModePreference: LinkModePreference.preferDynamic,
        check: (input, output) {
          final code = input.config.code;
          expect(portablePtyLinkModeForBuild(code), isA<StaticLinking>());
          expect(portablePtyLibraryNameForBuild(code), 'libportable_pty_rs.a');
          expect(portablePtyPlatformLabelForBuild(code), 'ios-sim-arm64');
        },
      );
    });

    test('coerces explicit iOS dynamic preferences to static', () async {
      for (final targetSdk in [IOSSdk.iPhoneOS, IOSSdk.iPhoneSimulator]) {
        await testCodeBuildHook(
          mainMethod: _noopBuildHook,
          targetOS: OS.iOS,
          targetArchitecture: Architecture.arm64,
          targetIOSSdk: targetSdk,
          linkModePreference: LinkModePreference.dynamic,
          check: (input, output) {
            final code = input.config.code;
            expect(portablePtyLinkModeForBuild(code), isA<StaticLinking>());
            expect(
              portablePtyLibraryNameForBuild(code),
              'libportable_pty_rs.a',
            );
          },
        );
      }
    });

    test('uses dynamic libraries for non-iOS preferDynamic', () async {
      await testCodeBuildHook(
        mainMethod: _noopBuildHook,
        targetOS: OS.linux,
        targetArchitecture: Architecture.x64,
        linkModePreference: LinkModePreference.preferDynamic,
        check: (input, output) {
          final code = input.config.code;
          expect(
            portablePtyLinkModeForBuild(code),
            isA<DynamicLoadingBundled>(),
          );
          expect(portablePtyLibraryNameForBuild(code), 'libportable_pty_rs.so');
        },
      );
    });

    test('respects static preferences on non-iOS platforms', () async {
      await testCodeBuildHook(
        mainMethod: _noopBuildHook,
        targetOS: OS.android,
        targetArchitecture: Architecture.arm64,
        linkModePreference: LinkModePreference.static,
        check: (input, output) {
          final code = input.config.code;
          expect(portablePtyLinkModeForBuild(code), isA<StaticLinking>());
          expect(portablePtyLibraryNameForBuild(code), 'libportable_pty_rs.a');
        },
      );
    });
  });
}

Future<void> _noopBuildHook(List<String> args) async {
  await build(args, (_, _) async {});
}
