import 'gh.dart';
import 'vocabulary.dart';

/// Statuses the tracker moves on its own. `blocked` is deliberately absent: it
/// is set by hand with a reason, so automation never adds or clears it (except
/// when the issue is closed).
const managedStatuses = ['in progress', 'in review', 'to verify'];
const allStatuses = [...managedStatuses, 'blocked'];

final _comments = RegExp(r'<!--[\s\S]*?-->');

String _stripComments(String? s) => (s ?? '').replaceAll(_comments, '');

/// Issue numbers named on a `Refs` line, for example `Refs #12` or
/// `Refs #3, #4`. Only lines that start with `Refs` count, so a number
/// mentioned in prose does not link anything. An empty `Refs #` links nothing.
List<int> parseRefs(String? body) {
  final found = <int>{};
  for (final line in _stripComments(body).split('\n')) {
    final m = RegExp(r'^\s*refs?\b\s*:?\s*(.*)$', caseSensitive: false).firstMatch(line);
    if (m == null) continue;
    for (final n in RegExp(r'#(\d+)').allMatches(m.group(1)!)) {
      found.add(int.parse(n.group(1)!));
    }
  }
  return found.toList();
}

/// Issue numbers GitHub would close when the PR merges (`Closes #1`,
/// `fixes #2`, `resolved #3`). The workflow wants `Refs`, so these get a warning.
List<int> closingKeywordTargets(String? text) => [
      for (final m in RegExp(
        r'\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b\s*:?\s+#(\d+)',
        caseSensitive: false,
      ).allMatches(_stripComments(text)))
        int.parse(m.group(1)!),
    ];

const sectionNames = ['what', 'why', 'how', 'verified by'];

/// The PR description's sections, keyed by lower-cased heading. A section that
/// is missing, or still holds only the template's comment, is null.
Map<String, String?> parseSections(String? body) {
  final result = <String, String?>{for (final n in sectionNames) n: null};
  String? current;
  final buffer = <String>[];
  void flush() {
    final heading = current;
    if (heading != null && result.containsKey(heading)) {
      final text = buffer.join('\n').trim();
      result[heading] = text.isEmpty ? null : text;
    }
    buffer.clear();
  }

  for (final line in _stripComments(body).split('\n')) {
    final h = RegExp(r'^##\s+(.+?)\s*$').firstMatch(line);
    if (h != null) {
      flush();
      current = h.group(1)!.toLowerCase();
    } else if (current != null) {
      buffer.add(line);
    }
  }
  flush();
  return result;
}

class PullRequestEvent {
  const PullRequestEvent({
    required this.action,
    required this.number,
    required this.title,
    required this.body,
    required this.draft,
    required this.merged,
    required this.mergeCommitSha,
    required this.headSha,
  });

  factory PullRequestEvent.fromPayload(Map<String, dynamic> payload) {
    final pr = payload['pull_request'] as Map<String, dynamic>;
    return PullRequestEvent(
      action: payload['action'] as String,
      number: pr['number'] as int,
      title: pr['title'] as String,
      body: pr['body'] as String?,
      draft: (pr['draft'] as bool?) ?? false,
      merged: (pr['merged'] as bool?) ?? false,
      mergeCommitSha: pr['merge_commit_sha'] as String?,
      headSha: (pr['head'] as Map)['sha'] as String,
    );
  }

  final String action;
  final int number;
  final String title;
  final String? body;
  final bool draft;
  final bool merged;
  final String? mergeCommitSha;
  final String headSha;
}

class CheckSummary {
  const CheckSummary(this.passed, this.failed, {this.unknown = false});

  static const none = CheckSummary(0, 0);

  /// The check results could not be read (usually a missing permission).
  static const unreadable = CheckSummary(0, 0, unknown: true);

  final int passed;
  final int failed;
  final bool unknown;

  /// Only finished checks are counted: the tracker's own run is still in
  /// progress when it writes this, and must not look like a pending failure.
  String describe() => unknown
      ? 'could not be read (the calling workflow needs "checks: read")'
      : passed + failed == 0
          ? 'no finished checks were reported on the PR'
          : '$passed passed, $failed failed';
}

class IssueChange {
  const IssueChange({
    required this.issue,
    this.add = const [],
    this.remove = const [],
    this.comment,
    this.marker,
  });

  final int issue;
  final List<String> add;
  final List<String> remove;
  final String? comment;

  /// Hidden text in [comment]; if an existing comment has it, the comment is
  /// not posted again (re-runs must not duplicate).
  final String? marker;
}

/// The status a PR implies for the issues it references, or null for "no
/// status" (an unmerged close).
String? statusFor(PullRequestEvent e) {
  if (e.action == 'closed') return e.merged ? 'to verify' : null;
  return e.draft ? 'in progress' : 'in review';
}

String verifyComment(PullRequestEvent e, CheckSummary checks) {
  final sections = parseSections(e.body);
  final sha = e.mergeCommitSha == null ? '' : ' as `${e.mergeCommitSha!.substring(0, 7)}`';
  final b = StringBuffer()
    ..writeln('**Merged. Waiting for you to verify.**')
    ..writeln()
    ..writeln('PR #${e.number} "${e.title}" was squash-merged$sha. '
        'This issue stays open until you close it.')
    ..writeln();
  final missing = <String>[];
  for (final name in sectionNames) {
    final text = sections[name];
    final heading = name[0].toUpperCase() + name.substring(1);
    b.writeln('**$heading**');
    if (text == null) {
      b.writeln('(missing from the PR description)');
      missing.add(heading);
    } else {
      b.writeln(text);
    }
    b.writeln();
  }
  b.writeln('Checks: ${checks.describe()}.');
  if (missing.isNotEmpty) {
    b.writeln('Missing from the PR description: ${missing.join(', ')}.');
  }
  b
    ..writeln()
    ..writeln('Close this issue once you have confirmed it works.')
    ..write('<!-- tracker:verify pr=${e.number} -->');
  return b.toString();
}

/// What should change on each issue the PR references. Pure.
List<IssueChange> planPullRequest(
  PullRequestEvent e,
  List<int> issues, {
  CheckSummary checks = CheckSummary.none,
}) {
  final target = statusFor(e);
  return [
    for (final n in issues)
      IssueChange(
        issue: n,
        add: [if (target != null) target],
        remove: [for (final s in managedStatuses) if (s != target) s],
        comment: target == 'to verify' ? verifyComment(e, checks) : null,
        marker: target == 'to verify' ? '<!-- tracker:verify pr=${e.number} -->' : null,
      ),
  ];
}

/// Never throws on a refused read: the status change matters more than the
/// check summary, so an unreadable result is reported as such in the comment.
Future<CheckSummary> fetchChecks(Gh gh, String repo, String sha) async {
  final Map<String, dynamic> json;
  try {
    json = await gh.api('repos/$repo/commits/$sha/check-runs?per_page=100')
        as Map<String, dynamic>;
  } on GhException catch (e) {
    if (e.status == 403 || e.status == 404) return CheckSummary.unreadable;
    rethrow;
  }
  var passed = 0;
  var failed = 0;
  for (final r in (json['check_runs'] as List).cast<Map<String, dynamic>>()) {
    if (r['status'] != 'completed') continue;
    switch (r['conclusion']) {
      case 'success' || 'neutral' || 'skipped':
        passed++;
      case 'failure' || 'cancelled' || 'timed_out' || 'action_required' || 'startup_failure':
        failed++;
    }
  }
  return CheckSummary(passed, failed);
}

Future<void> _ensureLabel(Gh gh, String repo, String name, Vocabulary vocab) async {
  try {
    await gh.api('repos/$repo/labels/${Uri.encodeComponent(name)}');
  } on GhException catch (e) {
    if (e.status != 404) rethrow;
    final def = vocab.find(name);
    await gh.api('repos/$repo/labels', method: 'POST', body: {
      'name': name,
      if (def != null) 'color': def.color,
      if (def != null) 'description': def.description,
    });
  }
}

Future<bool> _hasMarker(Gh gh, String repo, int number, String marker) async {
  final comments = await gh.api('repos/$repo/issues/$number/comments?per_page=100',
      paginate: true) as List;
  return comments.any((c) => ((c as Map)['body'] as String? ?? '').contains(marker));
}

/// Applies one issue's change, skipping anything that is already true.
Future<void> _applyChange(
  Gh gh,
  String repo,
  IssueChange c,
  Set<String> current,
  Vocabulary vocab,
) async {
  final toAdd = [for (final l in c.add) if (!current.contains(l)) l];
  final toRemove = [for (final l in c.remove) if (current.contains(l)) l];
  if (toAdd.isNotEmpty) {
    for (final l in toAdd) {
      await _ensureLabel(gh, repo, l, vocab);
    }
    await gh.api('repos/$repo/issues/${c.issue}/labels',
        method: 'POST', body: {'labels': toAdd});
  }
  for (final l in toRemove) {
    await gh.api('repos/$repo/issues/${c.issue}/labels/${Uri.encodeComponent(l)}',
        method: 'DELETE');
  }
  if (c.comment != null &&
      !(c.marker != null && await _hasMarker(gh, repo, c.issue, c.marker!))) {
    await gh.api('repos/$repo/issues/${c.issue}/comments',
        method: 'POST', body: {'body': c.comment});
  }
}

/// Handles one GitHub Actions event. Returns a log line per decision.
Future<List<String>> runTracker({
  required Gh gh,
  required String repo,
  required String eventName,
  required Map<String, dynamic> payload,
  required Vocabulary vocabulary,
}) async {
  final log = <String>[];

  if (eventName == 'issues') {
    if (payload['action'] != 'closed') {
      log.add('ignored issues event "${payload['action']}"');
      return log;
    }
    final issue = payload['issue'] as Map<String, dynamic>;
    final number = issue['number'] as int;
    final have = {
      for (final l in (issue['labels'] as List).cast<Map<String, dynamic>>())
        l['name'] as String,
    };
    final change = IssueChange(issue: number, remove: allStatuses);
    await _applyChange(gh, repo, change, have, vocabulary);
    final removed = allStatuses.where(have.contains).toList();
    log.add(removed.isEmpty
        ? '#$number closed: no status labels to clear'
        : '#$number closed: cleared ${removed.join(', ')}');
    return log;
  }

  if (eventName != 'pull_request') {
    log.add('ignored event "$eventName"');
    return log;
  }

  final e = PullRequestEvent.fromPayload(payload);

  final closing = closingKeywordTargets('${e.title}\n${e.body ?? ''}');
  if (closing.isNotEmpty && const ['opened', 'edited', 'reopened'].contains(e.action)) {
    final marker = '<!-- tracker:closing-keyword pr=${e.number} -->';
    if (!await _hasMarker(gh, repo, e.number, marker)) {
      await gh.api('repos/$repo/issues/${e.number}/comments', method: 'POST', body: {
        'body': 'This PR uses a closing keyword for ${closing.map((n) => '#$n').join(', ')}. '
            'GitHub will close it automatically on merge. Use `Refs #N` instead, so the issue '
            'moves to `to verify` and you decide when it is done.\n$marker',
      });
      log.add('PR #${e.number}: warned about closing keyword for ${closing.join(', ')}');
    }
  }

  final refs = parseRefs(e.body);
  if (refs.isEmpty) {
    log.add('PR #${e.number}: no Refs line, nothing to track');
    return log;
  }

  final checks = e.merged ? await fetchChecks(gh, repo, e.headSha) : CheckSummary.none;
  for (final change in planPullRequest(e, refs, checks: checks)) {
    final Map<String, dynamic> issue;
    try {
      issue = await gh.api('repos/$repo/issues/${change.issue}') as Map<String, dynamic>;
    } on GhException catch (err) {
      if (err.status == 404) {
        log.add('#${change.issue}: not found, skipped');
        continue;
      }
      rethrow;
    }
    if (issue.containsKey('pull_request')) {
      log.add('#${change.issue}: is a pull request, skipped');
      continue;
    }
    if (issue['state'] == 'closed') {
      log.add('#${change.issue}: already closed, left alone');
      continue;
    }
    final have = {
      for (final l in (issue['labels'] as List).cast<Map<String, dynamic>>())
        l['name'] as String,
    };
    await _applyChange(gh, repo, change, have, vocabulary);
    log.add('#${change.issue}: ${change.add.isEmpty ? 'status cleared' : 'now ${change.add.single}'}'
        '${change.comment != null ? ', summary posted' : ''}');
  }
  return log;
}
