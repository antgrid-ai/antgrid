import 'package:antgrid/models/file_tree_models.dart';

/// Counts reads of [name], so a test can tell which siblings a sort or scan
/// touched.
class CountingFileNode extends FileNode {
  CountingFileNode(String path, {super.type = FileNodeType.file})
    : super(name: path.substring(path.lastIndexOf('/') + 1), path: path);

  int nameReads = 0;

  @override
  String get name {
    nameReads++;
    return super.name;
  }
}
