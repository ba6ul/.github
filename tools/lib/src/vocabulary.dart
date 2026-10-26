import 'dart:convert';
import 'dart:io';

/// One label in `labels/vocabulary.json`.
class VocabLabel {
  const VocabLabel({
    required this.name,
    required this.group,
    required this.tier,
    required this.color,
    required this.description,
    required this.aliases,
  });

  factory VocabLabel.fromJson(Map<String, dynamic> json) => VocabLabel(
        name: json['name'] as String,
        group: json['group'] as String,
        tier: json['tier'] as String,
        color: json['color'] as String,
        description: json['description'] as String,
        aliases: [for (final a in json['aliases'] as List) a as String],
      );

  final String name;
  final String group;

  /// `core` labels are used in every adopted repo; `optional` ones only when
  /// the repo lists them in `labels.optional`.
  final String tier;
  final String color;
  final String description;

  /// Other names this label is known by in older repos (for example
  /// `enhancement` for `feature`). Used to avoid creating a duplicate; never
  /// renamed without an explicit flag.
  final List<String> aliases;

  bool get isCore => tier == 'core';
}

class Vocabulary {
  Vocabulary(this.labels);

  factory Vocabulary.fromJson(Map<String, dynamic> json) => Vocabulary([
        for (final l in json['labels'] as List)
          VocabLabel.fromJson(l as Map<String, dynamic>),
      ]);

  factory Vocabulary.load(File file) =>
      Vocabulary.fromJson(jsonDecode(file.readAsStringSync()) as Map<String, dynamic>);

  final List<VocabLabel> labels;

  List<VocabLabel> get core => labels.where((l) => l.isCore).toList();

  /// Case-insensitive, because GitHub treats `Chore` and `chore` as one label.
  VocabLabel? find(String name) {
    final lower = name.toLowerCase();
    for (final l in labels) {
      if (l.name.toLowerCase() == lower) return l;
    }
    return null;
  }
}
