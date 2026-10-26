# repotools

Label sync, repo adoption and a status view. Dart; needs only the Dart SDK (not
Flutter), so it runs the same on Windows and Ubuntu. Talks to GitHub through the
installed `gh` CLI, so it uses whatever login `gh` already has.

Everything is a dry run unless a flag says otherwise. From this folder:

```
dart pub get
dart run bin/repotools.dart labels    --repo owner/name [--apply [--rename-aliases]]
dart run bin/repotools.dart bootstrap --repo owner/name [--write <local clone>] [--apply-settings]
dart run bin/repotools.dart status    [--repos a/b,c/d] [--stale-days 7]
```

| Command | Does | Never does |
|---|---|---|
| `labels` | Compares a repo's labels with the vocabulary plus the repo's `.github/project.json`. `--apply` creates missing labels. | Recolour, re-describe or delete a label. Rename an older name (for example `enhancement`) unless `--rename-aliases` is given with `--apply`. |
| `bootstrap` | Shows the files, merge settings and branch-protection facts for adopting a repo. `--write` copies missing files into a local clone for a normal PR. `--apply-settings` sets squash-only merging and delete-branch-on-merge. | Overwrite a file. Change or create branch protection (not part of this version). Push to the repo. |
| `status` | Lists only what needs attention: `to verify`, `blocked`, stale `in review`, `p1`, open non-draft PRs; what landed since the latest release tag; and one suggested next issue. `not-urgent` items are ignored. | Write anything. |

Tests: `dart test` (uses a scripted fake of GitHub, so no network or login).
