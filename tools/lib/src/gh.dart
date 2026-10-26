import 'dart:convert';
import 'dart:io';

/// A failed `gh api` call. [status] is the HTTP status when gh reported one.
class GhException implements Exception {
  GhException(this.message, {this.status});

  final String message;
  final int? status;

  @override
  String toString() =>
      'gh failed${status != null ? ' (HTTP $status)' : ''}: $message';
}

/// The only way the tool talks to GitHub. Tests substitute a fake.
abstract class Gh {
  /// Calls the REST API and returns the decoded JSON (a `Map`, a `List`, or
  /// null for an empty body). With [paginate], list pages are flattened.
  Future<Object?> api(
    String path, {
    String method = 'GET',
    Map<String, Object?>? body,
    bool paginate = false,
  });
}

/// Runs the installed `gh` CLI, so authentication is whatever `gh` already has
/// (a login locally, `GH_TOKEN` in Actions).
class ProcessGh implements Gh {
  @override
  Future<Object?> api(
    String path, {
    String method = 'GET',
    Map<String, Object?>? body,
    bool paginate = false,
  }) async {
    final args = [
      'api',
      '-X',
      method,
      path,
      if (paginate) ...['--paginate', '--slurp'],
      if (body != null) ...['--input', '-'],
    ];
    final process = await Process.start('gh', args);
    if (body != null) process.stdin.write(jsonEncode(body));
    await process.stdin.close();

    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    final code = await process.exitCode;
    final stdoutText = await out;
    final stderrText = await err;

    if (code != 0) {
      final status = RegExp(r'HTTP (\d{3})').firstMatch(stderrText)?.group(1) ??
          RegExp(r'"status":\s*"?(\d{3})').firstMatch(stdoutText)?.group(1);
      throw GhException(
        (stderrText.isNotEmpty ? stderrText : stdoutText).trim(),
        status: status == null ? null : int.parse(status),
      );
    }
    if (stdoutText.trim().isEmpty) return null;
    final decoded = jsonDecode(stdoutText);
    if (paginate && decoded is List) {
      return [for (final page in decoded) ...(page is List ? page : [page])];
    }
    return decoded;
  }
}
