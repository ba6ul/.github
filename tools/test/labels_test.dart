import 'package:repotools/repotools.dart';
import 'package:test/test.dart';

import 'fake_gh.dart';

void main() {
  final vocab = testCentral().loadVocabulary();
  final wanted = [
    vocab.find('bug')!,
    vocab.find('feature')!,
    vocab.find('chore')!,
    vocab.find('p1')!,
  ];

  RepoLabel repoLabel(String n, {String color = 'ededed', String d = ''}) =>
      RepoLabel(n, color, d);

  group('planLabels', () {
    test('matches existing names case-insensitively (Chore is chore)', () {
      final plan = planLabels([repoLabel('Chore')], wanted);
      expect(plan.items.firstWhere((i) => i.want.name == 'chore').state, LabelState.present);
    });

    test('an older name is flagged, not recreated', () {
      final plan = planLabels([repoLabel('enhancement')], wanted);
      final feature = plan.items.firstWhere((i) => i.want.name == 'feature');
      expect(feature.state, LabelState.aliasPresent);
      expect(feature.existing!.name, 'enhancement');
      expect(plan.missing.map((i) => i.want.name), isNot(contains('feature')));
    });

    test('missing labels are listed; unknown labels are left alone and counted', () {
      final plan = planLabels([repoLabel('bug'), repoLabel('api'), repoLabel('UI')], wanted);
      expect(plan.missing.map((i) => i.want.name), unorderedEquals(['feature', 'chore', 'p1']));
      expect(plan.leftAlone, ['api', 'UI']);
    });

    test('a different color or description is reported, never a reason to change', () {
      final plan = planLabels(
        [repoLabel('p1', color: '123456', d: 'Launch blocker, written by hand')],
        wanted,
      );
      final p1 = plan.items.firstWhere((i) => i.want.name == 'p1');
      expect(p1.state, LabelState.present);
      expect(p1.textDiffers, isTrue);
    });
  });

  group('applyLabels', () {
    test('creates only the missing labels and writes nothing else', () async {
      final gh = FakeGh({'POST repos/o/r/labels': {}});
      final plan = planLabels([repoLabel('bug'), repoLabel('enhancement')], wanted);
      final done = await applyLabels(gh, 'o/r', plan);
      expect(done, ['created "chore"', 'created "p1"']);
      expect(gh.writes.length, 2);
      expect(gh.writes.every((w) => w.startsWith('POST repos/o/r/labels')), isTrue);
    });

    test('never renames unless asked', () async {
      final gh = FakeGh({});
      final plan = planLabels([repoLabel('bug'), repoLabel('enhancement'), repoLabel('chore'), repoLabel('p1')], wanted);
      expect(await applyLabels(gh, 'o/r', plan), isEmpty);
      expect(gh.calls, isEmpty);
    });

    test('renames an older name only with the flag, via PATCH, nothing deleted', () async {
      final gh = FakeGh({'PATCH repos/o/r/labels/enhancement': {}});
      final plan = planLabels([repoLabel('bug'), repoLabel('enhancement'), repoLabel('chore'), repoLabel('p1')], wanted);
      final done = await applyLabels(gh, 'o/r', plan, renameAliases: true);
      expect(done, ['renamed "enhancement" to "feature"']);
      expect(gh.calls.any((c) => c.startsWith('DELETE')), isFalse);
    });

    test('encodes label names with spaces in the rename path', () async {
      final tracker = [vocab.find('feature')!];
      final gh = FakeGh({'PATCH repos/o/r/labels/new%20thing': {}});
      final custom = LabelPlan([
        LabelItem(tracker.single, LabelState.aliasPresent, existing: repoLabel('new thing')),
      ], const []);
      await applyLabels(gh, 'o/r', custom, renameAliases: true);
      expect(gh.calls.single, startsWith('PATCH repos/o/r/labels/new%20thing'));
    });
  });
}
