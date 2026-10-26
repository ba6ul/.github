import 'package:repotools/repotools.dart';
import 'package:test/test.dart';

import 'fake_gh.dart';

const goodBody = '''
Refs #5

## What
Fix the crash.

## Why
It exits the daemon.

## How
Catch and report.

## Verified by
dart test, 43 pass.
''';

Map<String, dynamic> prPayload(
  String action, {
  String? body = goodBody,
  bool draft = false,
  bool merged = false,
  String title = 'Fix the crash',
}) =>
    {
      'action': action,
      'pull_request': {
        'number': 9,
        'title': title,
        'body': body,
        'draft': draft,
        'merged': merged,
        'merge_commit_sha': 'abcdef1234567890',
        'head': {'sha': 'headsha'},
      },
    };

void main() {
  final vocab = testCentral().loadVocabulary();

  group('parseRefs', () {
    test('reads Refs lines only', () {
      expect(parseRefs('Refs #12'), [12]);
      expect(parseRefs('refs #3, #4'), [3, 4]);
      expect(parseRefs('intro\nRefs: #7\nmore\nsee #99 for context'), [7]);
    });

    test('an empty Refs line or one inside a comment links nothing', () {
      expect(parseRefs('Refs #\n\n## What'), isEmpty);
      expect(parseRefs('<!-- Refs #4 -->\nbody'), isEmpty);
      expect(parseRefs(null), isEmpty);
    });

    test('closing keywords are not links', () {
      expect(parseRefs('Closes #8'), isEmpty);
    });
  });

  group('closingKeywordTargets', () {
    test('finds the GitHub keywords', () {
      expect(closingKeywordTargets('Closes #1 and fixes #2, resolved: #3'), [1, 2, 3]);
    });

    test('ignores Refs, prose and the template comment', () {
      expect(closingKeywordTargets('Refs #4'), isEmpty);
      expect(closingKeywordTargets('<!-- Never write "Closes #5" -->'), isEmpty);
      expect(closingKeywordTargets('closed the loop on this'), isEmpty);
    });
  });

  group('parseSections', () {
    test('reads the four sections', () {
      final s = parseSections(goodBody);
      expect(s['what'], 'Fix the crash.');
      expect(s['verified by'], 'dart test, 43 pass.');
    });

    test('a section holding only the template comment is missing', () {
      final s = parseSections('## What\nx\n## Verified by\n<!-- Concrete evidence -->\n');
      expect(s['what'], 'x');
      expect(s['verified by'], isNull);
      expect(s['why'], isNull);
    });

    test('null body gives all-missing', () {
      expect(parseSections(null).values.every((v) => v == null), isTrue);
    });
  });

  group('planPullRequest', () {
    PullRequestEvent ev(String action, {bool draft = false, bool merged = false}) =>
        PullRequestEvent.fromPayload(prPayload(action, draft: draft, merged: merged));

    test('draft is in progress, ready is in review', () {
      expect(planPullRequest(ev('opened', draft: true), [5]).single.add, ['in progress']);
      expect(planPullRequest(ev('opened'), [5]).single.add, ['in review']);
      expect(planPullRequest(ev('ready_for_review'), [5]).single.add, ['in review']);
      expect(planPullRequest(ev('converted_to_draft', draft: true), [5]).single.add, ['in progress']);
    });

    test('moving a status removes the other managed ones but never blocked', () {
      final c = planPullRequest(ev('opened'), [5]).single;
      expect(c.remove, unorderedEquals(['in progress', 'to verify']));
      expect(c.remove, isNot(contains('blocked')));
    });

    test('merged goes to to verify with a summary; unmerged close clears', () {
      final merged = planPullRequest(ev('closed', merged: true), [5]).single;
      expect(merged.add, ['to verify']);
      expect(merged.comment, contains('Waiting for you to verify'));
      final unmerged = planPullRequest(ev('closed'), [5]).single;
      expect(unmerged.add, isEmpty);
      expect(unmerged.remove, containsAll(managedStatuses));
      expect(unmerged.comment, isNull);
    });

    test('the summary says plainly what is missing', () {
      final e = PullRequestEvent.fromPayload(
        prPayload('closed', merged: true, body: 'Refs #5\n\n## What\nDid it\n'),
      );
      final text = verifyComment(e, const CheckSummary(2, 1));
      expect(text, contains('Missing from the PR description: Why, How, Verified by.'));
      expect(text, contains('2 passed, 1 failed'));
      expect(text, contains('`abcdef1`'));
    });
  });

  group('runTracker', () {
    Map<String, Object?> issue(int n, {String state = 'open', List<String> labels = const [], bool pr = false}) => {
          'number': n,
          'state': state,
          'labels': [for (final l in labels) {'name': l}],
          if (pr) 'pull_request': {},
        };

    Future<List<String>> run(FakeGh gh, Map<String, dynamic> payload, {String event = 'pull_request'}) =>
        runTracker(gh: gh, repo: 'o/r', eventName: event, payload: payload, vocabulary: vocab);

    test('a draft PR puts the issue in progress, creating the label from the vocabulary if absent', () async {
      final gh = FakeGh({
        'GET repos/o/r/issues/5': issue(5),
        'GET repos/o/r/labels/in%20progress': GhException('Not Found', status: 404),
        'POST repos/o/r/labels': {},
        'POST repos/o/r/issues/5/labels': [],
      });
      final log = await run(gh, prPayload('opened', draft: true));
      expect(log.single, '#5: now in progress');
      expect(gh.writes.first, contains('c2e0c6'), reason: 'label created with the vocabulary colour');
      expect(gh.writes.last, contains('[in progress]'));
    });

    test('opening for review swaps in progress for in review; blocked is left alone', () async {
      final gh = FakeGh({
        'GET repos/o/r/issues/5': issue(5, labels: ['in progress', 'blocked']),
        'GET repos/o/r/labels/in%20review': {},
        'POST repos/o/r/issues/5/labels': [],
        'DELETE repos/o/r/issues/5/labels/in%20progress': [],
      });
      await run(gh, prPayload('ready_for_review'));
      expect(gh.writes.any((w) => w.contains('blocked')), isFalse);
      expect(gh.writes.any((w) => w.startsWith('DELETE') && w.contains('in%20progress')), isTrue);
    });

    test('merge posts the summary once, sets to verify, and never closes the issue', () async {
      Map<String, Object?> routes(List<Object?> existingComments) => {
            'GET repos/o/r/commits/headsha/check-runs?per_page=100': {
              'check_runs': [
                {'status': 'completed', 'conclusion': 'success'},
                {'status': 'in_progress', 'conclusion': null},
              ],
            },
            'GET repos/o/r/issues/5': issue(5, labels: ['in review']),
            'GET repos/o/r/labels/to%20verify': {},
            'POST repos/o/r/issues/5/labels': [],
            'DELETE repos/o/r/issues/5/labels/in%20review': [],
            'GET repos/o/r/issues/5/comments?per_page=100': existingComments,
            'POST repos/o/r/issues/5/comments': {},
          };
      final first = FakeGh(routes([]));
      final log = await run(first, prPayload('closed', merged: true));
      expect(log.single, '#5: now to verify, summary posted');
      expect(first.writes.any((w) => w.contains('1 passed, 0 failed')), isTrue);
      expect(first.calls.any((c) => c.contains('PATCH') || c.contains('state: closed')), isFalse);

      final second = FakeGh(routes([
        {'body': 'x <!-- tracker:verify pr=9 -->'},
      ]));
      await run(second, prPayload('closed', merged: true));
      expect(second.writes.any((w) => w.startsWith('POST repos/o/r/issues/5/comments')), isFalse,
          reason: 're-runs must not duplicate the summary');
    });

    test('closed-without-merge clears the status without a comment', () async {
      final gh = FakeGh({
        'GET repos/o/r/issues/5': issue(5, labels: ['in review']),
        'DELETE repos/o/r/issues/5/labels/in%20review': [],
      });
      final log = await run(gh, prPayload('closed'));
      expect(log.single, '#5: status cleared');
      expect(gh.writes.length, 1);
    });

    test('skips an issue that is already closed, is a PR, or does not exist', () async {
      for (final route in [
        issue(5, state: 'closed'),
        issue(5, pr: true),
        GhException('Not Found', status: 404),
      ]) {
        final gh = FakeGh({'GET repos/o/r/issues/5': route});
        await run(gh, prPayload('opened'));
        expect(gh.writes, isEmpty);
      }
    });

    test('a PR with no Refs line is ignored', () async {
      final gh = FakeGh({});
      final log = await run(gh, prPayload('opened', body: '## What\nsmall fix\n'));
      expect(log.single, contains('no Refs line'));
      expect(gh.calls, isEmpty);
    });

    test('a closing keyword gets one warning, not two', () async {
      Map<String, Object?> routes(List<Object?> comments) => {
            'GET repos/o/r/issues/9/comments?per_page=100': comments,
            'POST repos/o/r/issues/9/comments': {},
          };
      final once = FakeGh(routes([]));
      await run(once, prPayload('opened', body: 'Closes #5'));
      expect(once.writes.single, contains('Use `Refs #N`'));

      final again = FakeGh(routes([
        {'body': '<!-- tracker:closing-keyword pr=9 -->'},
      ]));
      await run(again, prPayload('edited', body: 'Closes #5'));
      expect(again.writes, isEmpty);
    });

    test('closing an issue clears every status label, including blocked', () async {
      final gh = FakeGh({
        'DELETE repos/o/r/issues/5/labels/to%20verify': [],
        'DELETE repos/o/r/issues/5/labels/blocked': [],
      });
      final log = await run(
        gh,
        {
          'action': 'closed',
          'issue': {
            'number': 5,
            'labels': [
              {'name': 'to verify'},
              {'name': 'blocked'},
              {'name': 'bug'},
            ],
          },
        },
        event: 'issues',
      );
      expect(log.single, '#5 closed: cleared to verify, blocked');
      expect(gh.writes.length, 2);
    });

    test('other issue events and other event types are ignored', () async {
      final gh = FakeGh({});
      expect((await run(gh, {'action': 'opened', 'issue': {}}, event: 'issues')).single, contains('ignored'));
      expect((await run(gh, {}, event: 'push')).single, contains('ignored'));
    });
  });

  test('ReadOnlyGh passes reads and reports writes without sending them', () async {
    final inner = FakeGh({'GET repos/o/r': {'ok': true}});
    final logged = <String>[];
    final gh = ReadOnlyGh(inner, logged.add);
    expect(await gh.api('repos/o/r'), {'ok': true});
    await gh.api('repos/o/r/labels', method: 'POST', body: {'name': 'x'});
    expect(logged.single, startsWith('would POST repos/o/r/labels'));
    expect(inner.writes, isEmpty);
  });
}
