import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:repotools/repotools.dart';

Future<void> main(List<String> args) async {
  final runner = CommandRunner<int>(
    'repotools',
    'Label sync, repo adoption and status view. Read-only unless an --apply or '
        '--write flag is given.',
  )
    ..argParser.addOption('central',
        help: 'Path to the checkout holding labels/, schema/ and templates/. '
            'Defaults to the checkout this tool runs from.')
    ..addCommand(LabelsCommand())
    ..addCommand(BootstrapCommand())
    ..addCommand(StatusCommand())
    ..addCommand(TrackerCommand());

  try {
    exitCode = await runner.run(args) ?? 0;
  } on UsageException catch (e) {
    stderr.writeln(e);
    exitCode = 64;
  } on GhException catch (e) {
    stderr.writeln(e);
    exitCode = 1;
  }
}

Central _central(Command<int> c) =>
    locateCentral(c.globalResults?['central'] as String?);

String _repoArg(Command<int> c) {
  final repo = c.argResults?['repo'] as String?;
  if (repo == null || !repo.contains('/')) {
    c.usageException('--repo owner/name is required');
  }
  return repo;
}

class LabelsCommand extends Command<int> {
  LabelsCommand() {
    argParser
      ..addOption('repo', help: 'owner/name')
      ..addFlag('apply', help: 'Create the missing labels (create-only).')
      ..addFlag('rename-aliases',
          help: 'With --apply, also rename older names (for example '
              '"enhancement") to the vocabulary name.');
  }

  @override
  String get name => 'labels';
  @override
  String get description =>
      'Compare a repo\'s labels with the vocabulary. Dry run unless --apply.';

  @override
  Future<int> run() async {
    final repo = _repoArg(this);
    final apply = argResults!['apply'] as bool;
    final rename = argResults!['rename-aliases'] as bool;
    final central = _central(this);
    final vocab = central.loadVocabulary();
    final gh = ProcessGh();

    final config = await fetchConfig(gh, repo, central.loadSchema(), vocab);
    if (!config.ok) {
      stderr.writeln('$repo: .github/project.json is invalid:');
      for (final e in config.errors) {
        stderr.writeln('  - $e');
      }
      return 2;
    }
    final plan = planLabels(
      await fetchRepoLabels(gh, repo),
      wantedLabels(vocab, config.config),
    );
    stdout.write(renderLabelPlan(repo, plan, renameRequested: rename));
    if (!apply) {
      stdout.writeln('\nDry run. Nothing was changed.');
      return 0;
    }
    final done = await applyLabels(gh, repo, plan, renameAliases: rename);
    stdout.writeln(done.isEmpty ? '\nNothing to change.' : '\nDone:');
    for (final line in done) {
      stdout.writeln('  - $line');
    }
    return 0;
  }
}

class BootstrapCommand extends Command<int> {
  BootstrapCommand() {
    argParser
      ..addOption('repo', help: 'owner/name')
      ..addOption('write',
          valueHelp: 'path',
          help: 'Write the files that would be added into this local clone '
              '(never overwrites). Commit them through a normal PR.')
      ..addOption('workflow-ref',
          defaultsTo: 'v1',
          help: 'Version of the shared workflows the written callers point at. '
              'Use a branch name to test before a tag exists.')
      ..addFlag('apply-settings',
          help: 'Set squash-only merging and delete-branch-on-merge.');
  }

  @override
  String get name => 'bootstrap';
  @override
  String get description =>
      'Show what adopting a repo would add or change. Dry run unless a flag says otherwise.';

  @override
  Future<int> run() async {
    final repo = _repoArg(this);
    final central = _central(this);
    final gh = ProcessGh();
    final plan = await planBootstrap(
      gh,
      repo,
      central,
      central.loadVocabulary(),
      central.loadSchema(),
      workflowRef: argResults!['workflow-ref'] as String,
    );
    stdout.write(renderBootstrap(plan));

    final write = argResults!['write'] as String?;
    final applySettingsFlag = argResults!['apply-settings'] as bool;
    if (write == null && !applySettingsFlag) {
      stdout.writeln('\nDry run. Nothing was changed.');
      return plan.config.ok || !plan.configPresent ? 0 : 2;
    }
    if (write != null) {
      final written = writeFiles(plan, Directory(write));
      stdout.writeln('\nWrote ${written.length} file(s) to $write:');
      for (final f in written) {
        stdout.writeln('  - $f');
      }
    }
    if (applySettingsFlag) {
      await applySettings(gh, plan);
      stdout.writeln('\nSettings updated: '
          '${plan.settings.isEmpty ? 'nothing to change' : plan.settings.map((s) => s.key).join(', ')}');
    }
    return 0;
  }
}

class TrackerCommand extends Command<int> {
  TrackerCommand() {
    argParser
      ..addOption('repo', help: 'owner/name (default: \$GITHUB_REPOSITORY)')
      ..addOption('event-name', help: 'Default: \$GITHUB_EVENT_NAME')
      ..addOption('event-path', help: 'Event payload JSON. Default: \$GITHUB_EVENT_PATH')
      ..addFlag('dry-run', help: 'Read from GitHub but only print what would be written.');
  }

  @override
  String get name => 'tracker';
  @override
  String get description =>
      'Move the issues a pull request references through in progress, in review and to verify. Run by the shared workflow.';

  @override
  Future<int> run() async {
    final env = Platform.environment;
    final repo = (argResults!['repo'] as String?) ?? env['GITHUB_REPOSITORY'];
    final eventName = (argResults!['event-name'] as String?) ?? env['GITHUB_EVENT_NAME'];
    final eventPath = (argResults!['event-path'] as String?) ?? env['GITHUB_EVENT_PATH'];
    if (repo == null || eventName == null || eventPath == null) {
      usageException('repo, event name and event path are required '
          '(flags or GITHUB_* environment variables)');
    }
    final payload = jsonDecode(File(eventPath).readAsStringSync()) as Map<String, dynamic>;
    final dryRun = argResults!['dry-run'] as bool;
    final Gh gh = dryRun ? ReadOnlyGh(ProcessGh(), stdout.writeln) : ProcessGh();

    final log = await runTracker(
      gh: gh,
      repo: repo,
      eventName: eventName,
      payload: payload,
      vocabulary: _central(this).loadVocabulary(),
    );
    log.forEach(stdout.writeln);
    return 0;
  }
}

class StatusCommand extends Command<int> {
  StatusCommand() {
    argParser
      ..addMultiOption('repos',
          help: 'owner/name list. Default: your own non-fork, non-archived '
              'repos that have open issues or PRs.')
      ..addOption('stale-days',
          defaultsTo: '7', help: 'Days before an "in review" issue counts as stale.');
  }

  @override
  String get name => 'status';
  @override
  String get description =>
      'Show only what needs attention across repos, what changed since the last release tag, and what to pick up next. Read-only.';

  @override
  Future<int> run() async {
    final gh = ProcessGh();
    final staleDays = int.parse(argResults!['stale-days'] as String);
    var repos = (argResults!['repos'] as List<String>);
    if (repos.isEmpty) {
      final mine = await gh.api(
        'user/repos?affiliation=owner&per_page=100',
        paginate: true,
      ) as List;
      repos = [
        for (final r in mine.cast<Map<String, dynamic>>())
          if (r['fork'] != true &&
              r['archived'] != true &&
              (r['open_issues_count'] as int) > 0)
            r['full_name'] as String,
      ];
    }
    final now = DateTime.now().toUtc();
    final all = <RepoStatus>[];
    for (final repo in repos) {
      try {
        all.add(await collectStatus(gh, repo, now, staleDays: staleDays));
      } on GhException catch (e) {
        stderr.writeln('$repo: skipped ($e)');
      }
    }
    stdout.write(renderStatus(all, now));
    return 0;
  }
}
