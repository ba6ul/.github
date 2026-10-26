import 'gh.dart';

/// A release tag such as `v0.10.0` or `v2.0.32+58` (version, then optional
/// build number).
class ReleaseTag implements Comparable<ReleaseTag> {
  const ReleaseTag(this.name, this.major, this.minor, this.patch, this.build);

  final String name;
  final int major;
  final int minor;
  final int patch;
  final int? build;

  @override
  int compareTo(ReleaseTag other) {
    for (final pair in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
      (build ?? -1, other.build ?? -1),
    ]) {
      if (pair.$1 != pair.$2) return pair.$1.compareTo(pair.$2);
    }
    return 0;
  }
}

final _tagPattern = RegExp(r'^v(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?$');

/// Null when [name] is not a release-style tag. Numbers compare as numbers, so
/// `v0.10.0` is newer than `v0.9.0`.
ReleaseTag? parseTag(String name) {
  final m = _tagPattern.firstMatch(name);
  if (m == null) return null;
  return ReleaseTag(
    name,
    int.parse(m.group(1)!),
    int.parse(m.group(2)!),
    int.parse(m.group(3)!),
    m.group(4) == null ? null : int.parse(m.group(4)!),
  );
}

ReleaseTag? latestTag(Iterable<String> names) {
  ReleaseTag? best;
  for (final n in names) {
    final t = parseTag(n);
    if (t != null && (best == null || t.compareTo(best) > 0)) best = t;
  }
  return best;
}

class Change {
  const Change(this.sha, this.subject, this.pr);

  final String sha;
  final String subject;

  /// The PR number when the subject carries one (`(#12)` from a squash merge,
  /// or `Merge pull request #12`).
  final int? pr;
}

final _squashPr = RegExp(r'\(#(\d+)\)\s*$');
final _mergePr = RegExp(r'^Merge pull request #(\d+)');

Change changeFromCommit(String sha, String message) {
  final subject = message.split('\n').first.trim();
  final m = _squashPr.firstMatch(subject) ?? _mergePr.firstMatch(subject);
  return Change(sha, subject, m == null ? null : int.parse(m.group(1)!));
}

class SinceTag {
  const SinceTag(this.tag, this.total, this.changes);

  final String tag;
  final int total;

  /// May hold fewer than [total]: the compare API returns at most 250 commits.
  final List<Change> changes;
}

/// What landed on [defaultBranch] after the repo's latest release tag, or null
/// when the repo has no release-style tags. Read-only.
Future<SinceTag?> changesSinceLastTag(Gh gh, String repo, String defaultBranch) async {
  final Object? refs;
  try {
    refs = await gh.api('repos/$repo/git/matching-refs/tags/v', paginate: true);
  } on GhException {
    return null;
  }
  final names = [
    for (final r in (refs as List? ?? const []))
      ((r as Map)['ref'] as String).replaceFirst('refs/tags/', ''),
  ];
  final tag = latestTag(names);
  if (tag == null) return null;

  final cmp = await gh.api(
    'repos/$repo/compare/${Uri.encodeComponent(tag.name)}...${Uri.encodeComponent(defaultBranch)}',
  ) as Map<String, dynamic>;
  final commits = [
    for (final c in (cmp['commits'] as List))
      changeFromCommit(
        (c as Map)['sha'] as String,
        (c['commit'] as Map)['message'] as String,
      ),
  ];
  return SinceTag(tag.name, (cmp['ahead_by'] as int?) ?? commits.length, commits);
}
