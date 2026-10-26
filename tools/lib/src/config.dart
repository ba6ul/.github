import 'dart:convert';

import 'package:json_schema/json_schema.dart';

import 'vocabulary.dart';

class ReleaseConfig {
  const ReleaseConfig({
    required this.profile,
    this.versionFile,
    this.changelog,
    this.storeNotes,
    this.build,
    this.publish,
    this.docs,
  });

  factory ReleaseConfig.fromJson(Map<String, dynamic> json) => ReleaseConfig(
        profile: json['profile'] as String,
        versionFile: json['versionFile'] as String?,
        changelog: json['changelog'] as String?,
        storeNotes: json['storeNotes'] as String?,
        build: json['build'] as String?,
        publish: json['publish'] as String?,
        docs: json['docs'] as String?,
      );

  final String profile;
  final String? versionFile;
  final String? changelog;
  final String? storeNotes;
  final String? build;
  final String? publish;
  final String? docs;
}

/// A repo's `.github/project.json`. Every field is optional; a repo without
/// the file behaves like [ProjectConfig.empty].
class ProjectConfig {
  const ProjectConfig({
    this.checks = const {},
    this.optionalLabels = const [],
    this.release,
  });

  static const empty = ProjectConfig();

  final Map<String, String> checks;
  final List<String> optionalLabels;
  final ReleaseConfig? release;
}

class ConfigResult {
  const ConfigResult(this.config, this.errors);

  final ProjectConfig config;
  final List<String> errors;

  bool get ok => errors.isEmpty;
}

/// Parses and validates a config file's text. [source] null means the repo has
/// no config file, which is valid. Validation uses the shared JSON schema, so
/// the rules live in one place; label names are checked against [vocabulary]
/// here because the schema deliberately does not duplicate them.
ConfigResult parseProjectConfig(
  String? source, {
  required JsonSchema schema,
  required Vocabulary vocabulary,
}) {
  if (source == null) return const ConfigResult(ProjectConfig.empty, []);

  final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException catch (e) {
    return ConfigResult(ProjectConfig.empty, ['not valid JSON: ${e.message}']);
  }

  final errors = [
    for (final e in schema.validate(decoded).errors)
      '${e.instancePath.isEmpty ? '/' : e.instancePath}: ${e.message}',
  ];
  if (errors.isNotEmpty || decoded is! Map<String, dynamic>) {
    return ConfigResult(ProjectConfig.empty, errors);
  }

  final optional = [
    for (final n in ((decoded['labels'] as Map?)?['optional'] as List? ?? const []))
      n as String,
  ];
  for (final n in optional) {
    if (vocabulary.find(n) == null) {
      errors.add('/labels/optional: "$n" is not in the label vocabulary');
    }
  }

  final checks = <String, String>{
    for (final e in ((decoded['checks'] as Map?) ?? const {}).entries)
      e.key as String: e.value as String,
  };
  final release = decoded['release'];
  return ConfigResult(
    ProjectConfig(
      checks: checks,
      optionalLabels: optional,
      release: release is Map<String, dynamic> ? ReleaseConfig.fromJson(release) : null,
    ),
    errors,
  );
}

/// The labels a repo should have: all core labels plus its listed optional ones.
List<VocabLabel> wantedLabels(Vocabulary vocabulary, ProjectConfig config) => [
      ...vocabulary.core,
      for (final n in config.optionalLabels)
        if (vocabulary.find(n) case final l? when !l.isCore) l,
    ];
