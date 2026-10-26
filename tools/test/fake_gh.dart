import 'dart:io';

import 'package:repotools/repotools.dart';

/// Scripted GitHub: maps `METHOD path` to a response. Unknown calls fail loudly
/// so a test notices an unexpected request. Every call is recorded.
class FakeGh implements Gh {
  FakeGh(this.routes);

  final Map<String, Object?> routes;
  final calls = <String>[];

  @override
  Future<Object?> api(
    String path, {
    String method = 'GET',
    Map<String, Object?>? body,
    bool paginate = false,
  }) async {
    final key = '$method $path';
    calls.add(body == null ? key : '$key $body');
    if (!routes.containsKey(key)) {
      throw StateError('FakeGh: no route for "$key"');
    }
    final r = routes[key];
    if (r is GhException) throw r;
    return r;
  }

  Iterable<String> get writes =>
      calls.where((c) => !c.startsWith('GET '));
}

Map<String, Object?> ghLabel(String name, {String color = 'ededed', String? description}) =>
    {'name': name, 'color': color, 'description': description};

Central testCentral() => Central(Directory('..'));
