import 'package:repotools/repotools.dart';
import 'package:test/test.dart';

import 'fake_gh.dart';

Item item(
  int n, {
  List<String> labels = const [],
  String created = '2026-01-01T00:00:00Z',
  String updated = '2026-10-20T00:00:00Z',
}) =>
    Item(
      repo: 'o/r',
      number: n,
      title: 'Issue $n',
      labels: labels.map((l) => l.toLowerCase()).toSet(),
      createdAt: DateTime.parse(created),
      updatedAt: DateTime.parse(updated),
    );

void main() {
  group('tags', () {
    test('compares numbers as numbers, not text', () {
      expect(latestTag(['v0.9.0', 'v0.10.0', 'v0.2.0'])!.name, 'v0.10.0');
    });

    test('build number breaks ties; a tag without one is older', () {
      expect(latestTag(['v2.0.30+56', 'v2.0.31+57'])!.name, 'v2.0.31+57');
      expect(latestTag(['v1.0.0', 'v1.0.0+3'])!.name, 'v1.0.0+3');
    });

    test('ignores tags that are not release-style', () {
      expect(latestTag(['nightly', 'v1', 'release-2']), isNull);
      expect(latestTag(['nightly', 'v1.0.0'])!.name, 'v1.0.0');
    });

    test('reads PR numbers from squash and merge-commit subjects', () {
      expect(changeFromCommit('a', 'Fix crash (#12)\n\nbody').pr, 12);
      expect(changeFromCommit('b', 'Merge pull request #7 from x/y').pr, 7);
      expect(changeFromCommit('c', 'Plain commit').pr, isNull);
    });

    test('changesSinceLastTag asks GitHub to compare from the newest tag', () async {
      final gh = FakeGh({
        'GET repos/o/r/git/matching-refs/tags/v': [
          {'ref': 'refs/tags/v2.0.30+56'},
          {'ref': 'refs/tags/v2.0.31+57'},
        ],
        'GET repos/o/r/compare/v2.0.31%2B57...main': {
          'ahead_by': 2,
          'commits': [
            {'sha': '1', 'commit': {'message': 'First (#3)'}},
            {'sha': '2', 'commit': {'message': 'Second'}},
          ],
        },
      });
      final s = await changesSinceLastTag(gh, 'o/r', 'main');
      expect(s!.tag, 'v2.0.31+57');
      expect(s.total, 2);
      expect(s.changes.first.pr, 3);
    });

    test('a repo with no release tags has no since-tag section', () async {
      final gh = FakeGh({'GET repos/o/r/git/matching-refs/tags/v': <Object?>[]});
      expect(await changesSinceLastTag(gh, 'o/r', 'main'), isNull);
    });
  });

  group('status', () {
    final now = DateTime.parse('2026-10-26T00:00:00Z');

    RepoStatus run(List<Item> items) {
      final s = RepoStatus('o/r');
      for (final i in items) {
        classify(s, i, now: now, staleDays: 7);
      }
      return s;
    }

    test('parked ideas never need attention, even with p1', () {
      final s = run([item(1, labels: ['p1', 'not-urgent'])]);
      expect(s.needsAttention, isFalse);
      expect(s.ready, isEmpty);
    });

    test('each issue lands in one bucket, most important first', () {
      final s = run([
        item(1, labels: ['to verify', 'p1']),
        item(2, labels: ['blocked']),
        item(3, labels: ['p1']),
        item(4, labels: ['in review'], updated: '2026-10-01T00:00:00Z'),
        item(5, labels: ['in review'], updated: '2026-10-25T00:00:00Z'),
      ]);
      expect(s.toVerify.map((i) => i.number), [1]);
      expect(s.blocked.map((i) => i.number), [2]);
      expect(s.urgent.map((i) => i.number), [3]);
      expect(s.staleInReview.map((i) => i.number), [4]);
    });

    test('a status label takes an issue out of the ready pool', () {
      final s = run([item(1, labels: ['in progress']), item(2)]);
      expect(s.ready.map((i) => i.number), [2]);
    });

    test('next up: priority first, then bugs, then oldest', () {
      final a = RepoStatus('o/r')
        ..ready.addAll([
          item(1, labels: ['p3'], created: '2025-01-01T00:00:00Z'),
          item(2, labels: ['p2', 'feature'], created: '2025-06-01T00:00:00Z'),
          item(3, labels: ['p2', 'bug'], created: '2026-01-01T00:00:00Z'),
          item(4, labels: ['p2', 'bug'], created: '2025-12-01T00:00:00Z'),
        ]);
      expect(nextUp([a])!.number, 4);
    });

    test('unlabelled counts as normal: after p2, before p3', () {
      final s = RepoStatus('o/r')
        ..ready.addAll([item(1, labels: ['p3']), item(2), item(3, labels: ['p2'])]);
      expect(nextUp([s])!.number, 3);
      s.ready.removeWhere((i) => i.number == 3);
      expect(nextUp([s])!.number, 2);
    });

    test('collectStatus separates PRs from issues and skips drafts', () async {
      Map<String, Object?> raw(int n, {bool pr = false, bool draft = false, List<String> labels = const []}) => {
            'number': n,
            'title': 'T$n',
            'labels': [for (final l in labels) {'name': l}],
            'created_at': '2026-10-01T00:00:00Z',
            'updated_at': '2026-10-24T00:00:00Z',
            if (pr) 'pull_request': {},
            if (pr) 'draft': draft,
          };
      final gh = FakeGh({
        'GET repos/o/r': {'default_branch': 'main'},
        'GET repos/o/r/issues?state=open&per_page=100': [
          raw(1, labels: ['p1']),
          raw(2, pr: true),
          raw(3, pr: true, draft: true),
        ],
        'GET repos/o/r/git/matching-refs/tags/v': <Object?>[],
      });
      final s = await collectStatus(gh, 'o/r', DateTime.parse('2026-10-26T00:00:00Z'));
      expect(s.urgent.map((i) => i.number), [1]);
      expect(s.prsToMerge.map((i) => i.number), [2]);
      expect(gh.writes, isEmpty);
    });

    test('render says so when nothing needs attention', () {
      expect(renderStatus([RepoStatus('o/r')], now), contains('Nothing needs attention'));
    });
  });
}
