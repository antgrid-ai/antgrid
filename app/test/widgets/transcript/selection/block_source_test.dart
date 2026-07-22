import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/agent_event.dart';
import 'package:antgrid/widgets/transcript/diff_view.dart';
import 'package:antgrid/widgets/transcript/selection/block_source.dart';

void main() {
  test('assistantSource keeps markdown, derives html', () {
    final s = assistantSource('Hello **bold** and `code`');
    expect(s.markdown, 'Hello **bold** and `code`');
    expect(s.html, contains('<strong>bold</strong>'));
    expect(s.html, contains('<code>code</code>'));
  });

  test('plainTextSource escapes html and preserves newlines as <br>', () {
    final s = plainTextSource('a < b\nc & d');
    expect(s.markdown, 'a < b\nc & d');
    expect(s.html, '<p>a &lt; b<br>c &amp; d</p>');
  });

  test('planSource reconstructs checklist markdown', () {
    final s = planSource(const [
      PlanEntry(text: 'done thing', status: 'completed'),
      PlanEntry(text: 'todo thing', status: 'pending'),
    ]);
    expect(s.markdown, '- [x] done thing\n- [ ] todo thing');
    expect(s.html, '<ul><li>done thing</li><li>todo thing</li></ul>');
  });

  test('codeSource fences with language and escapes html', () {
    final s = codeSource('echo <hi>', language: 'bash');
    expect(s.markdown, '```bash\necho <hi>\n```');
    expect(s.html, '<pre><code>echo &lt;hi&gt;</code></pre>');
  });

  test('diffSource renders unified prefixes and diff fence', () {
    final s = diffSource(const [
      DiffLine('kept', DiffOp.context),
      DiffLine('removed', DiffOp.del),
      DiffLine('added', DiffOp.add),
    ]);
    expect(s.markdown, '```diff\n kept\n-removed\n+added\n```');
    expect(s.html, '<pre><code> kept\n-removed\n+added</code></pre>');
  });
}
