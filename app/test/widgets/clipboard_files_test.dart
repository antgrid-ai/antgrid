import 'dart:async';
import 'dart:io';

import 'package:antgrid/widgets/clipboard_files.dart';
import 'package:antgrid/widgets/terminal_attachment_uploader.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_clipboard/super_clipboard.dart';

class _Item extends ClipboardDataReader {
  _Item(this.uri, {this.advertisesFile = true, this.error});
  final Uri? uri;
  final bool advertisesFile;
  final Object? error;

  @override
  bool canProvide(DataFormat format) => advertisesFile;

  @override
  Future<T?> readValue<T extends Object>(ValueFormat<T> format) async {
    if (error != null) throw error!;
    return uri as T?;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'captures all file URIs in order, ignoring text and web links',
    () async {
      final windows = Uri.file(r'C:\Users\Test\some image.png', windows: true);
      final mac = Uri.file('/Users/test/café/report.pdf');
      final items = [
        _Item(windows),
        _Item(Uri.parse('https://example.com/file.png')),
        _Item(null),
        _Item(mac),
        _Item(windows, advertisesFile: false),
      ];
      final files = await readClipboardFiles(
        read: () async => ClipboardReader(items),
      );
      items.clear();
      expect(files, [windows, mac]);
      expect(
        windows.toFilePath(windows: true),
        r'C:\Users\Test\some image.png',
      );
      expect(mac.toFilePath(windows: false), '/Users/test/café/report.pdf');
    },
  );

  test(
    'unavailable clipboard falls through, failed metadata does not',
    () async {
      expect(await readClipboardFiles(read: () async => null), isEmpty);
      expect(
        await readClipboardFiles(
          read: () async => throw MissingPluginException(),
        ),
        isEmpty,
      );
      await expectLater(
        readClipboardFiles(
          read: () async =>
              ClipboardReader([_Item(null, error: StateError('read failed'))]),
        ),
        throwsStateError,
      );
      await expectLater(
        readClipboardFiles(
          read: () => Completer<ClipboardReader?>().future,
          timeout: Duration.zero,
        ),
        throwsA(isA<TimeoutException>()),
      );
    },
  );

  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('clipboard-files-');
  });
  tearDown(() async => directory.delete(recursive: true));

  Future<File> file(String name, List<int> bytes) =>
      File('${directory.path}/$name').writeAsBytes(bytes);

  test(
    'reads original file bytes in order and snapshots the selection',
    () async {
      final first = await file('first image.png', [0, 255, 42]);
      final second = await file('café.txt', [5, 6]);
      final files = [first.uri, second.uri];
      final started = Completer<void>();
      final release = Completer<void>();
      final uploaded = <(String, List<int>)>[];
      final errors = <String>[];
      final operation = attachClipboardFiles(
        files: files,
        attach: ({required bytes, required fileName}) async {
          uploaded.add((fileName, bytes));
          if (uploaded.length == 1) {
            started.complete();
            await release.future;
          }
        },
        onError: errors.add,
      );
      await started.future;
      files.clear();
      expect(uploaded.map((item) => item.$1), ['first image.png']);
      expect(uploaded.map((item) => item.$2), [
        [0, 255, 42],
      ]);
      release.complete();
      await operation;
      expect(uploaded.map((item) => item.$1), ['first image.png', 'caf_.txt']);
      expect(uploaded.map((item) => item.$2), [
        [0, 255, 42],
        [5, 6],
      ]);
      expect(errors, isEmpty);
    },
  );

  test(
    'missing, directory, oversize and failed items do not lose later files',
    () async {
      final large = await file('large.bin', [1, 2, 3, 4]);
      final fails = await file('fails.txt', [1]);
      final empty = await file('empty.txt', []);
      final good = await file('good.txt', [2]);
      final names = <String>[];
      final errors = <String>[];
      await attachClipboardFiles(
        files: [
          File('${directory.path}/missing.txt').uri,
          directory.uri,
          large.uri,
          fails.uri,
          empty.uri,
          good.uri,
        ],
        limit: 3,
        attach: ({required bytes, required fileName}) async {
          if (fileName == 'fails.txt') throw StateError('upload failed');
          names.add(fileName);
        },
        onError: errors.add,
      );
      expect(names, ['empty.txt', 'good.txt']);
      expect(errors, hasLength(4));
      expect(errors.join('\n'), contains('Cannot paste folder'));
      expect(errors.join('\n'), contains('larger than'));
    },
  );

  test(
    'batch reservation survives disposal and excludes competing uploads',
    () async {
      final board = TerminalAttachBoard();
      final typed = <String>[];
      final errors = <String>[];
      TerminalAttachmentUploader uploader() => TerminalAttachmentUploader(
        board: board,
        boardKey: () => 'original-terminal',
        resolveUpload: () =>
            ({required fileName, required bytes, mimeType, onProgress}) async =>
                '/remote/$fileName',
        insert: typed.add,
        onError: errors.add,
      );
      final batch = uploader();
      final other = uploader();
      addTearDown(batch.dispose);
      addTearDown(other.dispose);
      final started = Completer<void>();
      final release = Completer<void>();
      final operation = batch.exclusive(() async {
        started.complete();
        await release.future;
        await batch.attach(bytes: Uint8List(0), fileName: 'a.txt');
        await other.attach(bytes: Uint8List(0), fileName: 'interleaved.txt');
        await batch.attach(bytes: Uint8List(0), fileName: 'b.txt');
      });
      await started.future;
      batch.dispose();
      await other.exclusive(
        () async => fail('must not enter a competing batch'),
      );
      await other.attach(bytes: Uint8List(0), fileName: 'busy.txt');
      release.complete();
      await operation;
      expect(typed, ['"/remote/a.txt" ', '"/remote/b.txt" ']);
      expect(errors, hasLength(3));
      await other.attach(bytes: Uint8List(0), fileName: 'after.txt');
      expect(typed.last, '"/remote/after.txt" ');
    },
  );
}
