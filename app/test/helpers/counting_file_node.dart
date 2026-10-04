import 'package:antgrid/models/file_tree_models.dart';

/// Counts reads of [name] and [children], so a test can tell which nodes a
/// sort, scan or tree walk touched.
class CountingFileNode extends FileNode {
  CountingFileNode(
    String path, {
    super.type = FileNodeType.file,
    super.children = const [],
  }) : super(name: path.substring(path.lastIndexOf('/') + 1), path: path);

  int nameReads = 0;
  int childrenReads = 0;

  @override
  String get name {
    nameReads++;
    return super.name;
  }

  @override
  List<FileNode> get children {
    childrenReads++;
    return super.children;
  }
}
