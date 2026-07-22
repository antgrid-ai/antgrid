import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/preferences_models.dart';

class PreferencesService {
  static const _fileName = 'preferences.json';
  static const _debounceDuration = Duration(seconds: 5);

  File? _file;
  String? _projectId;
  bool _loaded = false;
  ProjectPreferences _current = const ProjectPreferences();
  Map<String, dynamic> _allPrefs = {};
  Timer? _debounceTimer;

  final _controller = StreamController<ProjectPreferences>.broadcast();

  Stream<ProjectPreferences> get stream => _controller.stream;
  ProjectPreferences get current => _current;
  String? get projectId => _projectId;

  Future<File> _getFile() async {
    if (_file != null) return _file!;
    final dir = await getApplicationSupportDirectory();
    _file = File('${dir.path}${Platform.pathSeparator}$_fileName');
    return _file!;
  }

  Future<void> _readAll() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = await _getFile();
      if (await file.exists()) {
        final raw = await file.readAsString();
        _allPrefs = jsonDecode(raw) as Map<String, dynamic>;
      }
    } catch (_) {
      _allPrefs = {};
    }
  }

  Future<ProjectPreferences> load(String projectId) async {
    await _flushIfPending();

    _projectId = projectId;
    await _readAll();

    final projectJson = _allPrefs[projectId];
    _current = projectJson is Map<String, dynamic>
        ? ProjectPreferences.fromJson(projectJson)
        : const ProjectPreferences();
    _controller.add(_current);
    return _current;
  }

  void update(ProjectPreferences prefs) {
    if (prefs == _current) return;
    _current = prefs;
    _controller.add(_current);
    _scheduleSave();
  }

  void _scheduleSave() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDuration, () => _save());
  }

  Future<void> _save() async {
    final id = _projectId;
    if (id == null) return;

    _allPrefs[id] = _current.toJson();

    try {
      final file = await _getFile();
      await file.writeAsString(jsonEncode(_allPrefs));
    } catch (_) {
      // Write failed — will retry on next save
    }
  }

  Future<void> flush() => _flushIfPending();

  Future<void> _flushIfPending() async {
    if (_debounceTimer?.isActive ?? false) {
      _debounceTimer!.cancel();
      _debounceTimer = null;
      await _save();
    }
  }

  Future<void> dispose() async {
    await _flushIfPending();
    _debounceTimer?.cancel();
    await _controller.close();
  }
}
