// app/test/navigation/nav_location_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/navigation/nav_location.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/models/settings_section.dart';
import 'package:antgrid/models/workspace_view.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';

void main() {
  test('value equality over target, surface and sessionId', () {
    const a = NavLocation(
      target: LocalProject('p1'),
      surface: WorkbenchSurface.workspace,
      sessionId: 's1',
    );
    const b = NavLocation(
      target: LocalProject('p1'),
      surface: WorkbenchSurface.workspace,
      sessionId: 's1',
    );
    const c = NavLocation(
      target: LocalProject('p1'),
      surface: WorkbenchSurface.workspace,
      sessionId: 's2',
    );
    expect(a, equals(b));
    expect(a.hashCode, equals(b.hashCode));
    expect(a, isNot(equals(c)));
  });

  test('copyWith replaces sessionId, keeps the rest', () {
    const a = NavLocation(
      target: LocalProject('p1'),
      surface: WorkbenchSurface.workspace,
      sessionId: 's1',
    );
    final b = a.copyWith(sessionId: 's2');
    expect(b.sessionId, 's2');
    expect(b.target, const LocalProject('p1'));
    expect(b.surface, WorkbenchSurface.workspace);
  });

  test('copyWith can null out sessionId via clearSessionId', () {
    const a = NavLocation(
      target: LocalProject('p1'),
      surface: WorkbenchSurface.workspace,
      sessionId: 's1',
    );
    final b = a.copyWith(clearSessionId: true);
    expect(b.sessionId, isNull);
  });

  test('an omitted view defaults to null and equals an explicit null', () {
    const omitted = NavLocation(
      target: LocalProject('p1'),
      surface: WorkbenchSurface.workspace,
      sessionId: 's1',
    );
    const explicitNull = NavLocation(
      target: LocalProject('p1'),
      surface: WorkbenchSurface.workspace,
      sessionId: 's1',
      view: null,
    );
    expect(omitted.view, isNull);
    expect(omitted, equals(explicitNull));
    expect(omitted.hashCode, equals(explicitNull.hashCode));
  });

  test('view participates in equality and hashCode', () {
    const git = NavLocation(
      target: LocalProject('p1'),
      surface: WorkbenchSurface.workspace,
      view: WorkspaceView.git,
    );
    const sameGit = NavLocation(
      target: LocalProject('p1'),
      surface: WorkbenchSurface.workspace,
      view: WorkspaceView.git,
    );
    const files = NavLocation(
      target: LocalProject('p1'),
      surface: WorkbenchSurface.workspace,
      view: WorkspaceView.files,
    );
    const none = NavLocation(
      target: LocalProject('p1'),
      surface: WorkbenchSurface.workspace,
    );
    expect(git, equals(sameGit));
    expect(git.hashCode, equals(sameGit.hashCode));
    expect(git, isNot(equals(files)));
    expect(git, isNot(equals(none)));
  });

  test('copyWith replaces view, keeps the rest', () {
    const a = NavLocation(
      target: LocalProject('p1'),
      surface: WorkbenchSurface.workspace,
      sessionId: 's1',
      view: WorkspaceView.files,
    );
    final b = a.copyWith(view: WorkspaceView.terminals);
    expect(b.view, WorkspaceView.terminals);
    expect(b.target, const LocalProject('p1'));
    expect(b.surface, WorkbenchSurface.workspace);
    expect(b.sessionId, 's1');
  });

  test('copyWith keeps an existing view when view is omitted', () {
    const a = NavLocation(
      target: LocalProject('p1'),
      surface: WorkbenchSurface.workspace,
      view: WorkspaceView.git,
    );
    expect(a.copyWith(sessionId: 's2').view, WorkspaceView.git);
  });

  test('copyWith can null out view via clearView', () {
    const a = NavLocation(
      target: LocalProject('p1'),
      surface: WorkbenchSurface.workspace,
      view: WorkspaceView.git,
    );
    final b = a.copyWith(clearView: true);
    expect(b.view, isNull);
    expect(b.target, const LocalProject('p1'));
    expect(b.surface, WorkbenchSurface.workspace);
  });

  test('copyWith rejects clearView combined with an explicit view', () {
    const a = NavLocation(
      target: LocalProject('p1'),
      surface: WorkbenchSurface.workspace,
    );
    expect(
      () => a.copyWith(view: WorkspaceView.git, clearView: true),
      throwsA(isA<AssertionError>()),
    );
  });

  test('an omitted settingsSection defaults to null and equals an explicit '
      'null', () {
    const omitted = NavLocation(
      target: null,
      surface: WorkbenchSurface.appSettings,
    );
    const explicitNull = NavLocation(
      target: null,
      surface: WorkbenchSurface.appSettings,
      settingsSection: null,
    );
    expect(omitted.settingsSection, isNull);
    expect(omitted, equals(explicitNull));
    expect(omitted.hashCode, equals(explicitNull.hashCode));
  });

  test('settingsSection participates in equality and hashCode', () {
    const privacy = NavLocation(
      target: null,
      surface: WorkbenchSurface.appSettings,
      settingsSection: SettingsSection.privacy,
    );
    const samePrivacy = NavLocation(
      target: null,
      surface: WorkbenchSurface.appSettings,
      settingsSection: SettingsSection.privacy,
    );
    const account = NavLocation(
      target: null,
      surface: WorkbenchSurface.appSettings,
      settingsSection: SettingsSection.account,
    );
    const none = NavLocation(
      target: null,
      surface: WorkbenchSurface.appSettings,
    );
    expect(privacy, equals(samePrivacy));
    expect(privacy.hashCode, equals(samePrivacy.hashCode));
    expect(privacy, isNot(equals(account)));
    expect(privacy, isNot(equals(none)));
  });

  test('copyWith replaces settingsSection, keeps the rest', () {
    const a = NavLocation(
      target: LocalProject('p1'),
      surface: WorkbenchSurface.appSettings,
      sessionId: 's1',
      view: WorkspaceView.files,
      settingsSection: SettingsSection.help,
    );
    final b = a.copyWith(settingsSection: SettingsSection.privacy);
    expect(b.settingsSection, SettingsSection.privacy);
    expect(b.target, const LocalProject('p1'));
    expect(b.surface, WorkbenchSurface.appSettings);
    expect(b.sessionId, 's1');
    expect(b.view, WorkspaceView.files);
  });

  test('copyWith keeps an existing settingsSection when it is omitted', () {
    const a = NavLocation(
      target: null,
      surface: WorkbenchSurface.appSettings,
      settingsSection: SettingsSection.billing,
    );
    expect(
      a.copyWith(surface: WorkbenchSurface.workspace).settingsSection,
      SettingsSection.billing,
    );
  });

  test('copyWith can null out settingsSection via clearSettingsSection', () {
    const a = NavLocation(
      target: null,
      surface: WorkbenchSurface.appSettings,
      settingsSection: SettingsSection.billing,
    );
    final b = a.copyWith(clearSettingsSection: true);
    expect(b.settingsSection, isNull);
    expect(b.surface, WorkbenchSurface.appSettings);
  });

  test('copyWith rejects clearSettingsSection with an explicit section', () {
    const a = NavLocation(target: null, surface: WorkbenchSurface.appSettings);
    expect(
      () => a.copyWith(
        settingsSection: SettingsSection.help,
        clearSettingsSection: true,
      ),
      throwsA(isA<AssertionError>()),
    );
  });

  test('an omitted file defaults to null and equals an explicit null', () {
    const omitted = NavLocation(
      target: LocalProject('p1'),
      surface: WorkbenchSurface.workspace,
      view: WorkspaceView.files,
    );
    const explicitNull = NavLocation(
      target: LocalProject('p1'),
      surface: WorkbenchSurface.workspace,
      view: WorkspaceView.files,
      file: null,
    );
    expect(omitted.file, isNull);
    expect(omitted, equals(explicitNull));
    expect(omitted.hashCode, equals(explicitNull.hashCode));
  });

  test('file participates in equality and hashCode', () {
    const main = NavLocation(
      target: LocalProject('p1'),
      surface: WorkbenchSurface.workspace,
      file: 'lib/main.dart',
    );
    const sameMain = NavLocation(
      target: LocalProject('p1'),
      surface: WorkbenchSurface.workspace,
      file: 'lib/main.dart',
    );
    const other = NavLocation(
      target: LocalProject('p1'),
      surface: WorkbenchSurface.workspace,
      file: 'lib/other.dart',
    );
    const none = NavLocation(
      target: LocalProject('p1'),
      surface: WorkbenchSurface.workspace,
    );
    expect(main, equals(sameMain));
    expect(main.hashCode, equals(sameMain.hashCode));
    expect(main, isNot(equals(other)));
    expect(main, isNot(equals(none)));
  });

  test('copyWith replaces file, keeps the rest', () {
    const a = NavLocation(
      target: LocalProject('p1'),
      surface: WorkbenchSurface.workspace,
      sessionId: 's1',
      view: WorkspaceView.files,
      file: 'lib/main.dart',
    );
    final b = a.copyWith(file: 'README.md');
    expect(b.file, 'README.md');
    expect(b.target, const LocalProject('p1'));
    expect(b.surface, WorkbenchSurface.workspace);
    expect(b.sessionId, 's1');
    expect(b.view, WorkspaceView.files);
  });

  test('copyWith keeps an existing file when it is omitted', () {
    const a = NavLocation(
      target: LocalProject('p1'),
      surface: WorkbenchSurface.workspace,
      file: 'lib/main.dart',
    );
    expect(a.copyWith(sessionId: 's2').file, 'lib/main.dart');
  });

  test('copyWith can null out file via clearFile', () {
    const a = NavLocation(
      target: LocalProject('p1'),
      surface: WorkbenchSurface.workspace,
      file: 'lib/main.dart',
    );
    final b = a.copyWith(clearFile: true);
    expect(b.file, isNull);
    expect(b.target, const LocalProject('p1'));
    expect(b.surface, WorkbenchSurface.workspace);
  });

  test('copyWith rejects clearFile combined with an explicit file', () {
    const a = NavLocation(
      target: LocalProject('p1'),
      surface: WorkbenchSurface.workspace,
    );
    expect(
      () => a.copyWith(file: 'lib/main.dart', clearFile: true),
      throwsA(isA<AssertionError>()),
    );
  });
}
