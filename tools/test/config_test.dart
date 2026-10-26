import 'dart:io';

import 'package:repotools/repotools.dart';
import 'package:test/test.dart';

import 'fake_gh.dart';

void main() {
  final central = testCentral();
  final vocab = central.loadVocabulary();
  final schema = central.loadSchema();

  ConfigResult parse(String? s) =>
      parseProjectConfig(s, schema: schema, vocabulary: vocab);

  group('vocabulary', () {
    test('has unique names regardless of case and every alias is distinct', () {
      final names = vocab.labels.map((l) => l.name.toLowerCase()).toList();
      expect(names.toSet().length, names.length);
      for (final l in vocab.labels) {
        expect(names.contains(l.name.toLowerCase()), isTrue);
        for (final a in l.aliases) {
          expect(names.contains(a.toLowerCase()), isFalse, reason: '$a clashes');
        }
      }
    });

    test('finds labels case-insensitively', () {
      expect(vocab.find('Chore')?.name, 'chore');
      expect(vocab.find('nope'), isNull);
    });

    test('core set holds the lifecycle labels the tracker needs', () {
      final core = vocab.core.map((l) => l.name).toSet();
      expect(core, containsAll(['in progress', 'in review', 'to verify', 'blocked']));
      expect(core, containsAll(['bug', 'feature', 'p1', 'p2', 'p3']));
    });
  });

  group('project config', () {
    test('no file is valid and means defaults', () {
      final r = parse(null);
      expect(r.ok, isTrue);
      expect(r.config.checks, isEmpty);
      expect(r.config.release, isNull);
    });

    for (final name in [
      'flutter-android-local-build',
      'flutter-android-ci-build',
      'scripts-only',
    ]) {
      test('example $name is valid', () {
        final r = parse(File('../examples/$name.json').readAsStringSync());
        expect(r.errors, isEmpty);
      });
    }

    test('tag-only with build/publish is rejected', () {
      final r = parse(File('../examples/invalid-tag-only-with-build.json').readAsStringSync());
      expect(r.ok, isFalse);
    });

    test('release settings are read', () {
      final r = parse(File('../examples/flutter-android-local-build.json').readAsStringSync());
      expect(r.config.release?.profile, 'flutter-android');
      expect(r.config.release?.build, 'local');
      expect(r.config.release?.publish, 'manual');
      expect(r.config.checks['test'], 'flutter test');
    });

    test('unknown top-level key, bad JSON and unknown label name are errors', () {
      expect(parse('{"surprise": 1}').ok, isFalse);
      expect(parse('{not json').ok, isFalse);
      final r = parse('{"labels": {"optional": ["made-up"]}}');
      expect(r.errors.single, contains('made-up'));
    });

    test('worktree and setup pass through without being interpreted', () {
      final r = parse('{"setup": "flutter pub get", "worktree": {"anything": [1, 2]}}');
      expect(r.ok, isTrue);
    });

    test('wanted labels are core plus the listed optional ones', () {
      final r = parse('{"labels": {"optional": ["Chore", "not-urgent"]}}');
      final names = wantedLabels(vocab, r.config).map((l) => l.name);
      expect(names, containsAll(['chore', 'not-urgent', 'bug', 'to verify']));
      expect(names, isNot(contains('performance')));
    });
  });
}
