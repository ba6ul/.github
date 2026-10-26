import 'gh.dart';
import 'vocabulary.dart';

class RepoLabel {
  const RepoLabel(this.name, this.color, this.description);

  factory RepoLabel.fromJson(Map<String, dynamic> json) => RepoLabel(
        json['name'] as String,
        (json['color'] as String).toLowerCase(),
        (json['description'] as String?) ?? '',
      );

  final String name;
  final String color;
  final String description;
}

enum LabelState {
  /// A label with this name exists (names compare case-insensitively).
  present,

  /// Not present, but an older name for it is. Creating the new name would
  /// leave two overlapping labels, so this needs a rename decision.
  aliasPresent,

  /// Neither exists; safe to create.
  missing,
}

class LabelItem {
  const LabelItem(this.want, this.state, {this.existing});

  final VocabLabel want;
  final LabelState state;

  /// The matching label for [LabelState.present], or the alias for
  /// [LabelState.aliasPresent].
  final RepoLabel? existing;

  /// Only meaningful for [LabelState.present]. Reported, never changed.
  bool get textDiffers =>
      state == LabelState.present &&
      existing != null &&
      (existing!.color != want.color || existing!.description != want.description);
}

class LabelPlan {
  const LabelPlan(this.items, this.leftAlone);

  final List<LabelItem> items;

  /// Names of repo labels outside this repo's wanted set: its own labels, or
  /// vocabulary labels it did not select. Never touched.
  final List<String> leftAlone;

  List<LabelItem> get missing =>
      items.where((i) => i.state == LabelState.missing).toList();
  List<LabelItem> get aliased =>
      items.where((i) => i.state == LabelState.aliasPresent).toList();
}

/// Compares the repo's labels with the wanted set. Pure: no I/O.
LabelPlan planLabels(List<RepoLabel> repo, List<VocabLabel> wanted) {
  RepoLabel? byName(String name) {
    final lower = name.toLowerCase();
    for (final l in repo) {
      if (l.name.toLowerCase() == lower) return l;
    }
    return null;
  }

  final known = <String>{};
  final items = <LabelItem>[];
  for (final want in wanted) {
    known.add(want.name.toLowerCase());
    final exact = byName(want.name);
    if (exact != null) {
      items.add(LabelItem(want, LabelState.present, existing: exact));
      continue;
    }
    RepoLabel? alias;
    for (final a in want.aliases) {
      alias = byName(a);
      if (alias != null) break;
    }
    if (alias != null) {
      known.add(alias.name.toLowerCase());
      items.add(LabelItem(want, LabelState.aliasPresent, existing: alias));
    } else {
      items.add(LabelItem(want, LabelState.missing));
    }
  }
  final leftAlone = [
    for (final l in repo)
      if (!known.contains(l.name.toLowerCase())) l.name,
  ]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return LabelPlan(items, leftAlone);
}

Future<List<RepoLabel>> fetchRepoLabels(Gh gh, String repo) async {
  final json = await gh.api('repos/$repo/labels?per_page=100', paginate: true);
  return [
    for (final l in json as List) RepoLabel.fromJson(l as Map<String, dynamic>),
  ];
}

/// Applies a plan. Creates missing labels only. With [renameAliases], also
/// renames an older name to the canonical one (GitHub keeps the label on every
/// issue that has it). Never recolours, re-describes or deletes anything.
/// Returns one line per change made.
Future<List<String>> applyLabels(
  Gh gh,
  String repo,
  LabelPlan plan, {
  bool renameAliases = false,
}) async {
  final done = <String>[];
  for (final item in plan.missing) {
    await gh.api('repos/$repo/labels', method: 'POST', body: {
      'name': item.want.name,
      'color': item.want.color,
      'description': item.want.description,
    });
    done.add('created "${item.want.name}"');
  }
  if (renameAliases) {
    for (final item in plan.aliased) {
      final old = item.existing!.name;
      await gh.api('repos/$repo/labels/${Uri.encodeComponent(old)}',
          method: 'PATCH', body: {'new_name': item.want.name});
      done.add('renamed "$old" to "${item.want.name}"');
    }
  }
  return done;
}

String renderLabelPlan(String repo, LabelPlan plan, {required bool renameRequested}) {
  final b = StringBuffer('Labels for $repo\n');
  final present = plan.items.where((i) => i.state == LabelState.present).toList();
  b.writeln('  already there: ${present.length}'
      '${present.isEmpty ? '' : ' (${present.map((i) => i.existing!.name).join(', ')})'}');
  for (final i in present.where((i) => i.textDiffers)) {
    b.writeln('  note: "${i.existing!.name}" has a different color or description '
        'than the vocabulary; left as it is');
  }
  for (final i in plan.aliased) {
    b.writeln('  needs a decision: "${i.existing!.name}" exists, vocabulary name is '
        '"${i.want.name}". ${renameRequested ? 'Would rename it' : 'Not created, to avoid a duplicate; rename with --rename-aliases'}');
  }
  for (final i in plan.missing) {
    b.writeln('  would create: "${i.want.name}" (${i.want.group})');
  }
  b.writeln(plan.leftAlone.isEmpty
      ? '  left alone: nothing else'
      : '  left alone (not in this repo\'s set): ${plan.leftAlone.join(', ')}');
  return b.toString();
}
