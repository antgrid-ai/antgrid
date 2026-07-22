/// Downloads the prebuilt portable_pty native library for the host platform.
///
/// Usage:
///   dart run portable_pty:setup [--tag portable_pty-v0.0.4] [--platform linux-x64]
///
/// The library is placed in `.prebuilt/<platform>/` at the project root,
/// where the build hook will find it automatically.
library;

import 'dart:io';

import 'package:portable_pty/src/hook/artifacts.dart';
import 'package:portable_pty/src/hook/asset_hashes.dart';

const _repo = 'kingwill101/dart_terminal';
const _defaultTag = releaseTag;

Future<void> main(List<String> args) async {
  var tag = _defaultTag;
  String? platform;

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--tag':
      case '-t':
        tag = args[++i];
      case '--platform':
      case '-p':
        platform = args[++i];
      case '--help':
      case '-h':
        stdout.writeln(
          'Usage: dart run portable_pty:setup [options]\n'
          '\n'
          'Downloads the prebuilt portable_pty native library for your platform\n'
          'into .prebuilt/<platform>/ at your project root.\n'
          '\n'
          '  --tag, -t       Release tag (default: $_defaultTag)\n'
          '  --platform, -p  e.g. linux-x64, macos-arm64 (default: auto-detect)\n',
        );
        return;
    }
  }

  platform ??= _hostPlatform();

  final artifact = tag == releaseTag
      ? assetHashes[platform]?.tarball
      : portablePtyPrebuiltArtifacts[platform];
  if (artifact == null) {
    final available = tag == releaseTag
        ? assetHashes.keys
        : portablePtyPrebuiltArtifacts.keys;
    stderr.writeln(
      'No prebuilt portable_pty artifact for platform "$platform" in $tag.\n'
      'Available: ${available.join(', ')}',
    );
    exitCode = 1;
    return;
  }

  final projectRoot = _findProjectRoot(Directory.current);
  final outDir = Directory('${projectRoot.path}/.prebuilt/$platform')
    ..createSync(recursive: true);

  stdout.writeln('portable_pty setup');
  stdout.writeln('  Release:  $tag');
  stdout.writeln('  Platform: $platform');
  stdout.writeln('  Target:   ${outDir.path}');
  stdout.writeln('');

  try {
    await _downloadAndExtract(tag, artifact, outDir);
    stdout.writeln('Done. The build hook will use this library automatically.');
  } on Exception catch (e) {
    stderr.writeln('Failed: $e');
    exitCode = 1;
  }
}

// ── Download ────────────────────────────────────────────────────────

Future<void> _downloadAndExtract(
  String tag,
  String filename,
  Directory outDir,
) async {
  // Try gh CLI first (handles auth, private repos, URL encoding).
  final ghResult = await Process.run('gh', [
    'release',
    'download',
    tag,
    '--repo',
    _repo,
    '--pattern',
    filename,
    '--dir',
    outDir.path,
    '--clobber',
  ]);

  final tarPath = '${outDir.path}/$filename';

  if (ghResult.exitCode != 0) {
    // Fall back to curl with the direct URL.
    final encodedTag = Uri.encodeComponent(tag);
    final url =
        'https://github.com/$_repo/releases/download/$encodedTag/$filename';
    stdout.writeln('  gh CLI unavailable, trying curl...');

    final curlResult = await Process.run('curl', [
      '-fSL',
      '--retry',
      '3',
      '-o',
      tarPath,
      url,
    ]);
    if (curlResult.exitCode != 0) {
      throw Exception(
        'Download failed.\n'
        '  gh error: ${ghResult.stderr}\n'
        '  curl error: ${curlResult.stderr}',
      );
    }
  }

  // Extract.
  final extractResult = await Process.run('tar', [
    'xzf',
    tarPath,
    '-C',
    outDir.path,
  ]);
  if (extractResult.exitCode != 0) {
    throw Exception('tar extract failed: ${extractResult.stderr}');
  }

  // Clean up tarball.
  File(tarPath).deleteSync();

  // Verify the library exists.
  final files = outDir.listSync().whereType<File>().toList();
  if (files.isEmpty) {
    throw Exception('Archive extracted but no files found in ${outDir.path}');
  }
  for (final f in files) {
    stdout.writeln('  Extracted: ${f.path}');
  }
}

// ── Helpers ─────────────────────────────────────────────────────────

String _hostPlatform() {
  final os = Platform.operatingSystem;
  final arch = _hostArch();
  switch (os) {
    case 'linux':
      return 'linux-$arch';
    case 'macos':
      return 'macos-$arch';
    case 'windows':
      return 'windows-$arch';
    default:
      return '$os-$arch';
  }
}

String _hostArch() {
  if (Platform.isWindows) {
    final pa = Platform.environment['PROCESSOR_ARCHITECTURE'] ?? '';
    return pa.contains('ARM') ? 'arm64' : 'x64';
  }
  final result = Process.runSync('uname', ['-m']);
  final machine = (result.stdout as String).trim();
  switch (machine) {
    case 'x86_64':
    case 'amd64':
      return 'x64';
    case 'aarch64':
    case 'arm64':
      return 'arm64';
    default:
      return machine;
  }
}

/// Find the consuming project root.
/// Prefers a monorepo root (pubspec.yaml + pkgs/), falls back to nearest
/// pubspec.yaml.
Directory _findProjectRoot(Directory start) {
  var dir = start.absolute;

  // First: look for monorepo root.
  var cursor = dir;
  while (true) {
    if (File('${cursor.path}/pubspec.yaml').existsSync() &&
        Directory('${cursor.path}/pkgs').existsSync()) {
      return cursor;
    }
    final parent = cursor.parent;
    if (parent.path == cursor.path) break;
    cursor = parent;
  }

  // Fallback: nearest pubspec.yaml.
  cursor = dir;
  while (true) {
    if (File('${cursor.path}/pubspec.yaml').existsSync()) {
      return cursor;
    }
    final parent = cursor.parent;
    if (parent.path == cursor.path) return start;
    cursor = parent;
  }
}
