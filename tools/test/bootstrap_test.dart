import 'dart:convert';
import 'dart:io';

import 'package:repotools/repotools.dart';
import 'package:test/test.dart';

import 'fake_gh.dart';

String b64(String s) => base64.encode(utf8.encode(s));

Map<String, Object?> file(String text) => {'content': b64(text), 'encoding': 'base64'};

GhException notFound() => GhException('Not Found', status: 404);

void main() {
  final central = testCentral();
  final vocab = central.loadVocabulary();
  final schema = central.loadSchema();
  final issueText = central.issueTemplate.readAsStringSync();
  final prText = central.pullRequestTemplate.readAsStringSync();

  Map<String, Object?> baseRoutes({
    bool private = false,
    Map<String, Object?> extra = const {},
    Map<String, Object?> repo = const {},
  }) =>
      {
        'GET repos/o/r': {
          'default_branch': 'main',
          'private': private,
          'allow_squash_merge': true,
          'allow_merge_commit': true,
          'allow_rebase_merge': true,
          'delete_branch_on_merge': false,
          ...repo,
        },
        'GET repos/o/r/contents/.github/project.json': notFound(),
        'GET repos/o/r/contents/.github/ISSUE_TEMPLATE': notFound(),
        'GET repos/o/r/contents/.github/ISSUE_TEMPLATE/issue.md': notFound(),
        'GET repos/o/r/contents/.github/pull_request_template.md': notFound(),
        'GET repos/o/r/contents/.github/workflows/tracker.yml': notFound(),
        'GET repos/o/r/contents/.github/workflows/ci.yml': notFound(),
        'GET repos/o/r/branches/main/protection': notFound(),
        'GET repos/o/r/rulesets': <Object?>[],
        ...extra,
      };

  Future<BootstrapPlan> plan(FakeGh gh, {String ref = 'v1'}) =>
      planBootstrap(gh, 'o/r', central, vocab, schema, workflowRef: ref);

  test('a bare repo gets both templates and the tracker, no CI without checks, no config', () async {
    final gh = FakeGh(baseRoutes());
    final p = await plan(gh);
    expect(p.toAdd.map((f) => f.path), [
      '.github/ISSUE_TEMPLATE/issue.md',
      '.github/pull_request_template.md',
      '.github/workflows/tracker.yml',
    ]);
    expect(renderBootstrap(p), contains('ci.yml not planned'));
    expect(p.configPresent, isFalse);
    expect(p.settings.map((s) => s.key),
        unorderedEquals(['allow_merge_commit', 'allow_rebase_merge', 'delete_branch_on_merge']));
    expect(gh.writes, isEmpty, reason: 'planning must be read-only');
  });

  test('identical files are left alone; differing files are never overwritten', () async {
    final p = await plan(FakeGh(baseRoutes(extra: {
      'GET repos/o/r/contents/.github/ISSUE_TEMPLATE/issue.md': file(issueText.replaceAll('\n', '\r\n')),
      'GET repos/o/r/contents/.github/pull_request_template.md': file('my own template'),
    })));
    expect(p.files[0].state, FileState.identical, reason: 'CRLF vs LF is not a difference');
    expect(p.files[1].state, FileState.differs);
    expect(p.toAdd.map((f) => f.path), ['.github/workflows/tracker.yml'],
        reason: 'only the missing file is planned; nothing existing is overwritten');
  });

  test('callers point at the requested workflow version', () async {
    final p = await plan(FakeGh(baseRoutes()), ref: 'feat/3-workflows');
    final tracker = p.files.firstWhere((f) => f.path == '.github/workflows/tracker.yml');
    expect(tracker.content, contains('actions/tracker@feat/3-workflows'));
    expect(tracker.content, isNot(contains('@v1')));
    expect((await plan(FakeGh(baseRoutes()))).files.last.content, contains('@v1'));
  });

  test('a repo with checks also gets the CI caller; the config is read, not guessed', () async {
    final p = await plan(FakeGh(baseRoutes(extra: {
      'GET repos/o/r/contents/.github/project.json':
          file('{"checks": {"toolchain": "dart", "test": "dart test"}}'),
    })));
    expect(p.config.ok, isTrue);
    expect(p.toAdd.map((f) => f.path), contains('.github/workflows/ci.yml'));
  });

  test('warns when adding a template to a repo that already has templates', () async {
    final p = await plan(FakeGh(baseRoutes(extra: {
      'GET repos/o/r/contents/.github/ISSUE_TEMPLATE': [
        {'name': 'bug_report.md'},
      ],
    })));
    expect(p.files.first.note, contains('bug_report.md'));
  });

  test('an invalid existing config is reported', () async {
    final p = await plan(FakeGh(baseRoutes(extra: {
      'GET repos/o/r/contents/.github/project.json': file('{"release": {"profile": "tag-only", "build": "ci"}}'),
    })));
    expect(p.configPresent, isTrue);
    expect(p.config.ok, isFalse);
    expect(renderBootstrap(p), contains('INVALID'));
  });

  group('branch protection report', () {
    test('public repo with no rules', () async {
      final p = await plan(FakeGh(baseRoutes()));
      final text = p.protection.join('\n');
      expect(text, contains('public repo'));
      expect(text, contains('no protection rules'));
    });

    test('private repo cannot be confirmed from the API', () async {
      final p = await plan(FakeGh(baseRoutes(private: true)));
      expect(p.protection.join('\n'), contains('depends on the account plan'));
    });

    test('existing rules are reported and promised untouched', () async {
      final p = await plan(FakeGh(baseRoutes(extra: {
        'GET repos/o/r/branches/main/protection': {'url': 'x'},
      })));
      expect(p.protection.join('\n'), contains('will not change them'));
    });

    test('a plan-limited repo (403) is reported, not an error', () async {
      final p = await plan(FakeGh(baseRoutes(private: true, extra: {
        'GET repos/o/r/branches/main/protection': GhException('Upgrade', status: 403),
      })));
      expect(p.protection.join('\n'), contains('not available'));
    });
  });

  test('writeFiles adds only missing files and never overwrites', () async {
    final p = await plan(FakeGh(baseRoutes(extra: {
      'GET repos/o/r/contents/.github/pull_request_template.md': file('mine'),
    })));
    final dir = Directory.systemTemp.createTempSync('bootstrap_test');
    try {
      File('${dir.path}/.github/pull_request_template.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('mine');
      final written = writeFiles(p, dir);
      expect(written, ['.github/ISSUE_TEMPLATE/issue.md', '.github/workflows/tracker.yml']);
      expect(File('${dir.path}/.github/pull_request_template.md').readAsStringSync(), 'mine');
      expect(File('${dir.path}/.github/ISSUE_TEMPLATE/issue.md').readAsStringSync(), issueText);
      expect(prText, isNotEmpty);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('applySettings sends only the settings that differ', () async {
    final gh = FakeGh({
      ...baseRoutes(),
      'PATCH repos/o/r': {},
    });
    final p = await plan(gh);
    await applySettings(gh, p);
    final patch = gh.writes.single;
    expect(patch, contains('allow_merge_commit: false'));
    expect(patch, isNot(contains('allow_squash_merge')));
  });
}
