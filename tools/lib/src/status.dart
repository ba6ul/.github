import 'gh.dart';
import 'tags.dart';

const _statusLabels = {'in progress', 'in review', 'to verify', 'blocked'};

class Item {
  const Item({
    required this.repo,
    required this.number,
    required this.title,
    required this.labels,
    required this.createdAt,
    required this.updatedAt,
    this.isDraft = false,
  });

  factory Item.fromJson(String repo, Map<String, dynamic> json) => Item(
        repo: repo,
        number: json['number'] as int,
        title: json['title'] as String,
        labels: {
          for (final l in (json['labels'] as List? ?? const []))
            ((l as Map)['name'] as String).toLowerCase(),
        },
        createdAt: DateTime.parse(json['created_at'] as String),
        updatedAt: DateTime.parse(json['updated_at'] as String),
        isDraft: (json['draft'] as bool?) ?? false,
      );

  final String repo;
  final int number;
  final String title;

  /// Lower-cased, so `Chore` and `chore` are the same.
  final Set<String> labels;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isDraft;

  String get ref => '$repo#$number';
  bool has(String label) => labels.contains(label);
  bool get parked => has('not-urgent');
  bool get hasStatus => labels.any(_statusLabels.contains);
}

class RepoStatus {
  RepoStatus(this.repo);

  final String repo;
  final toVerify = <Item>[];
  final blocked = <Item>[];
  final staleInReview = <Item>[];
  final urgent = <Item>[];
  final prsToMerge = <Item>[];
  final ready = <Item>[];
  SinceTag? sinceTag;

  bool get needsAttention =>
      toVerify.isNotEmpty ||
      blocked.isNotEmpty ||
      staleInReview.isNotEmpty ||
      urgent.isNotEmpty ||
      prsToMerge.isNotEmpty;

  bool get hasContent =>
      needsAttention || (sinceTag != null && sinceTag!.total > 0);
}

/// Sorts an open issue into at most one bucket. Pure.
///
/// Order of importance: to verify, blocked, stale in review, urgent (p1).
/// Parked (`not-urgent`) issues never appear: they were deliberately set aside.
void classify(RepoStatus s, Item i, {required DateTime now, required int staleDays}) {
  if (i.parked) return;
  if (i.has('to verify')) {
    s.toVerify.add(i);
  } else if (i.has('blocked')) {
    s.blocked.add(i);
  } else if (i.has('in review') &&
      now.difference(i.updatedAt).inDays >= staleDays) {
    s.staleInReview.add(i);
  } else if (i.has('p1')) {
    s.urgent.add(i);
  }
  if (!i.hasStatus) s.ready.add(i);
}

int _rank(Item i) {
  if (i.has('p1')) return 0;
  if (i.has('p2')) return 1;
  if (i.has('p3')) return 3;
  return 2; // unlabelled counts as normal: after p2, before p3
}

/// The one thing to pick up next: highest priority, bugs before other kinds,
/// then the oldest. Considers only ready (no status label), unparked issues.
Item? nextUp(Iterable<RepoStatus> all) {
  final candidates = [for (final s in all) ...s.ready];
  if (candidates.isEmpty) return null;
  candidates.sort((a, b) {
    final byRank = _rank(a).compareTo(_rank(b));
    if (byRank != 0) return byRank;
    final aBug = a.has('bug') ? 0 : 1;
    final bBug = b.has('bug') ? 0 : 1;
    if (aBug != bBug) return aBug.compareTo(bBug);
    return a.createdAt.compareTo(b.createdAt);
  });
  return candidates.first;
}

Future<RepoStatus> collectStatus(
  Gh gh,
  String repo,
  DateTime now, {
  int staleDays = 7,
}) async {
  final info = await gh.api('repos/$repo') as Map<String, dynamic>;
  final defaultBranch = info['default_branch'] as String;
  final raw = await gh.api('repos/$repo/issues?state=open&per_page=100',
      paginate: true) as List;

  final status = RepoStatus(repo);
  for (final entry in raw.cast<Map<String, dynamic>>()) {
    final item = Item.fromJson(repo, entry);
    if (entry.containsKey('pull_request')) {
      if (!item.isDraft) status.prsToMerge.add(item);
    } else {
      classify(status, item, now: now, staleDays: staleDays);
    }
  }
  status.sinceTag = await changesSinceLastTag(gh, repo, defaultBranch);
  return status;
}

String _age(DateTime t, DateTime now) {
  final d = now.difference(t).inDays;
  if (d >= 1) return '${d}d';
  final h = now.difference(t).inHours;
  return h >= 1 ? '${h}h' : 'just now';
}

String renderStatus(List<RepoStatus> all, DateTime now, {int maxChanges = 8}) {
  final b = StringBuffer();
  final shown = all.where((s) => s.hasContent).toList();
  if (shown.isEmpty) {
    b.writeln('Nothing needs attention (${all.length} repos checked).');
  }
  for (final s in shown) {
    b.writeln(s.repo);
    void group(String title, List<Item> items) {
      for (final i in items) {
        b.writeln('  $title  #${i.number} ${i.title}  (${_age(i.updatedAt, now)})');
      }
    }

    group('to verify', s.toVerify);
    group('blocked  ', s.blocked);
    group('stale review', s.staleInReview);
    group('urgent   ', s.urgent);
    group('PR to merge', s.prsToMerge);
    final t = s.sinceTag;
    if (t != null && t.total > 0) {
      b.writeln('  since ${t.tag}: ${t.total} commit(s) not in a release');
      for (final c in t.changes.reversed.take(maxChanges)) {
        b.writeln('    - ${c.subject}');
      }
      if (t.total > maxChanges) b.writeln('    - ... and ${t.total - maxChanges} more');
    }
  }
  final next = nextUp(all);
  if (next != null) {
    b.writeln('\nNext up: ${next.ref}  ${next.title}');
  }
  return b.toString();
}
