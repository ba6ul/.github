import 'dart:convert';
import 'dart:io';

import 'package:json_schema/json_schema.dart';

import 'central.dart';
import 'config.dart';
import 'gh.dart';
import 'vocabulary.dart';

enum FileState { add, identical, differs }

class FilePlan {
  const FilePlan(this.path, this.source, this.state, {this.note});

  /// Path inside the target repo.
  final String path;
  final File source;
  final FileState state;
  final String? note;
}

class SettingChange {
  const SettingChange(this.key, this.from, this.to);

  final String key;
  final Object? from;
  final Object to;
}

class BootstrapPlan {
  const BootstrapPlan({
    required this.repo,
    required this.private,
    required this.defaultBranch,
    required this.configPresent,
    required this.config,
    required this.files,
    required this.settings,
    required this.protection,
  });

  final String repo;
  final bool private;
  final String defaultBranch;
  final bool configPresent;
  final ConfigResult config;
  final List<FilePlan> files;
  final List<SettingChange> settings;
  final List<String> protection;

  List<FilePlan> get toAdd => files.where((f) => f.state == FileState.add).toList();
}

/// What we want merge settings to be: one PR becomes one commit, and merged
/// branches clean themselves up.
const desiredSettings = <String, Object>{
  'allow_squash_merge': true,
  'allow_merge_commit': false,
  'allow_rebase_merge': false,
  'delete_branch_on_merge': true,
};

String _normalize(String s) => s.replaceAll('\r\n', '\n');

Future<String?> repoFileText(Gh gh, String repo, String path) async {
  try {
    final json = await gh.api('repos/$repo/contents/$path');
    if (json is Map<String, dynamic> && json['content'] is String) {
      final b64 = (json['content'] as String).replaceAll('\n', '');
      return utf8.decode(base64.decode(b64));
    }
    return null;
  } on GhException catch (e) {
    if (e.status == 404) return null;
    rethrow;
  }
}

Future<List<String>> _protectionNotes(
  Gh gh,
  String repo,
  String branch,
  bool private,
) async {
  final notes = <String>[];
  notes.add(private
      ? 'private repo: whether branch protection is available depends on the account plan, '
          'which the API does not reveal; on the free plan it is refused for private repos'
      : 'public repo: branch protection is available');
  try {
    await gh.api('repos/$repo/branches/$branch/protection');
    notes.add('"$branch" already has protection rules; this tool will not change them');
  } on GhException catch (e) {
    if (e.status == 404) {
      notes.add('"$branch" has no protection rules');
    } else if (e.status == 403) {
      notes.add('branch protection is not available for this repo on the current plan');
    } else {
      notes.add('could not read protection rules (${e.status ?? 'error'})');
    }
  }
  try {
    final rulesets = await gh.api('repos/$repo/rulesets') as List;
    notes.add('rulesets: ${rulesets.length}');
  } on GhException {
    notes.add('rulesets: could not be read');
  }
  notes.add('opt-in and not applied by this version: requiring a PR and passing CI needs '
      'the CI check name from the shared workflow, which does not exist yet');
  return notes;
}

/// Read-only: works out what adopting [repo] would add or change.
Future<BootstrapPlan> planBootstrap(
  Gh gh,
  String repo,
  Central central,
  Vocabulary vocabulary,
  JsonSchema schema,
) async {
  final info = await gh.api('repos/$repo') as Map<String, dynamic>;
  final defaultBranch = info['default_branch'] as String;
  final private = info['private'] as bool;

  final configText = await repoFileText(gh, repo, '.github/project.json');
  final config = parseProjectConfig(configText, schema: schema, vocabulary: vocabulary);

  // Adding a template to a folder that already has templates changes the
  // picker people see, so say so rather than silently adding to it.
  var existingTemplates = <String>[];
  try {
    final dir = await gh.api('repos/$repo/contents/.github/ISSUE_TEMPLATE');
    if (dir is List) {
      existingTemplates = [for (final f in dir) (f as Map)['name'] as String];
    }
  } on GhException catch (e) {
    if (e.status != 404) rethrow;
  }

  final files = <FilePlan>[];
  Future<void> consider(String path, File source, {String? note}) async {
    final existing = await repoFileText(gh, repo, path);
    if (existing == null) {
      files.add(FilePlan(path, source, FileState.add, note: note));
    } else if (_normalize(existing) == _normalize(source.readAsStringSync())) {
      files.add(FilePlan(path, source, FileState.identical));
    } else {
      files.add(FilePlan(path, source, FileState.differs,
          note: 'exists with different content; not overwritten'));
    }
  }

  await consider(
    '.github/ISSUE_TEMPLATE/issue.md',
    central.issueTemplate,
    note: existingTemplates.isEmpty
        ? null
        : 'the repo already has issue templates (${existingTemplates.join(', ')}); '
            'this would be added to the template picker',
  );
  await consider('.github/pull_request_template.md', central.pullRequestTemplate);

  final settings = [
    for (final e in desiredSettings.entries)
      if (info[e.key] != e.value) SettingChange(e.key, info[e.key], e.value),
  ];

  return BootstrapPlan(
    repo: repo,
    private: private,
    defaultBranch: defaultBranch,
    configPresent: configText != null,
    config: config,
    files: files,
    settings: settings,
    protection: await _protectionNotes(gh, repo, defaultBranch, private),
  );
}

/// Writes the files marked [FileState.add] into a local clone. Never
/// overwrites. Network-free: the result is committed through a normal PR.
List<String> writeFiles(BootstrapPlan plan, Directory clone) {
  final written = <String>[];
  for (final f in plan.toAdd) {
    final target = File('${clone.path}/${f.path}');
    target.parent.createSync(recursive: true);
    target.writeAsStringSync(f.source.readAsStringSync());
    written.add(f.path);
  }
  return written;
}

/// Applies only the merge settings that differ. Separate, explicit step.
Future<void> applySettings(Gh gh, BootstrapPlan plan) async {
  if (plan.settings.isEmpty) return;
  await gh.api('repos/${plan.repo}', method: 'PATCH', body: {
    for (final s in plan.settings) s.key: s.to,
  });
}

String renderBootstrap(BootstrapPlan p) {
  final b = StringBuffer('Adopting ${p.repo} (${p.private ? 'private' : 'public'}, '
      'default branch ${p.defaultBranch})\n\n');

  b.writeln('Config (.github/project.json)');
  if (!p.configPresent) {
    b.writeln('  none; defaults apply (core labels, no checks, no release commands). Not created.');
  } else if (p.config.ok) {
    b.writeln('  present and valid');
  } else {
    b.writeln('  present but INVALID:');
    for (final e in p.config.errors) {
      b.writeln('    - $e');
    }
  }

  b.writeln('\nFiles');
  for (final f in p.files) {
    final verb = switch (f.state) {
      FileState.add => 'would add',
      FileState.identical => 'already identical',
      FileState.differs => 'differs',
    };
    b.writeln('  $verb: ${f.path}${f.note == null ? '' : ' - ${f.note}'}');
  }
  b.writeln('  (workflow callers are added once the shared workflows exist)');

  b.writeln('\nRepository settings (opt-in with --apply-settings)');
  if (p.settings.isEmpty) {
    b.writeln('  already as wanted');
  }
  for (final s in p.settings) {
    b.writeln('  would change ${s.key}: ${s.from} -> ${s.to}');
  }

  b.writeln('\nBranch protection');
  for (final n in p.protection) {
    b.writeln('  - $n');
  }
  return b.toString();
}

/// Reads and validates a repo's `.github/project.json` (absent is valid).
Future<ConfigResult> fetchConfig(
  Gh gh,
  String repo,
  JsonSchema schema,
  Vocabulary vocabulary,
) async =>
    parseProjectConfig(
      await repoFileText(gh, repo, '.github/project.json'),
      schema: schema,
      vocabulary: vocabulary,
    );
