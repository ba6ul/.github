import 'dart:io';

import 'package:json_schema/json_schema.dart';

import 'vocabulary.dart';

/// Where the shared definitions (vocabulary, schema, templates) live. By
/// default that is the checkout this tool runs from; `--central` overrides it.
class Central {
  Central(this.root);

  final Directory root;

  File get vocabularyFile => File('${root.path}/labels/vocabulary.json');
  File get schemaFile => File('${root.path}/schema/project.schema.json');
  File get issueTemplate => File('${root.path}/templates/issue.md');
  File get pullRequestTemplate => File('${root.path}/templates/pull_request_template.md');

  Vocabulary loadVocabulary() => Vocabulary.load(vocabularyFile);
  JsonSchema loadSchema() => JsonSchema.create(schemaFile.readAsStringSync());
}

/// `tools/bin/repotools.dart` and friends live two levels below the repo root.
Central locateCentral(String? override) {
  if (override != null) return Central(Directory(override));
  final script = File.fromUri(Platform.script);
  return Central(script.parent.parent.parent);
}
