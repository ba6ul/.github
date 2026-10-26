# Project config

Each repo can have one optional file, `.github/project.json`. It holds the
settings the shared tooling needs, and nothing else. If the file is missing,
the tooling still works with defaults: core labels only, no checks, no release
commands.

Add `"$schema": "https://raw.githubusercontent.com/ba6ul/.github/main/schema/project.schema.json"`
for editor validation. Settings are explicit; nothing is guessed from a repo's
name.

## Keys

| Key | Purpose | Default |
|---|---|---|
| `checks.analyze`, `checks.test` | Commands run from the repo root. Used by CI, release checks and the worktree tool, so they are written once. | none (CI skips) |
| `labels.optional` | Extra labels from `labels/vocabulary.json` to create in this repo. The core labels (`bug`, `feature`, `p1`-`p3`, the four status labels) are always used. | `[]` |
| `release` | Selects a release profile and its settings. Omit for projects that do not release. | no release commands |
| `setup`, `worktree` | Owned by the worktree tool (install step, worktree location, files to copy or discard, bypass variable, default branch, remote). Stored here so a repo has one config file, but not defined or validated by this repo. | none |

Labels that are not in the vocabulary (for example a repo's own `api` or `UI`)
are left alone. The sync never touches a label it does not know.

## Release profiles

| Profile | For | Allowed keys |
|---|---|---|
| `flutter-android` | Flutter Android apps | `versionFile`, `changelog`, `storeNotes`, `build` (`local` or `ci`), `publish` (`manual` or `ci-on-tag`), `docs` |
| `tag-only` | Everything else: a tag and a list of what changed, no artifact, no store | `changelog`, `docs` |

`tag-only` rejects `versionFile`, `storeNotes`, `build` and `publish`, so a
project that is not a Play Store app cannot pick up Play Store steps by accident.

`build` and `publish` describe how the project already works; they never change
it. `local` means the artifact is built on the developer's machine; `ci` means a
workflow builds it. `manual` means a person uploads it; `ci-on-tag` means a
workflow uploads it when a tag is pushed, which is why the tag step warns first.
Signing keys, store credentials and package ids are not config here: they stay
in the project and its CI secrets.

`docs` points at the project's own release document, where app-specific steps
belong.

## Relationship to the worktree tool

A worktree tool (one working folder per agent chat, with start, finish and a
guard against editing the main checkout) is being generalised separately. It
needs check commands, an install step, a worktree location and a list of
generated files to discard. Those are the same facts CI and release checks
need, so they live in this one file: `checks` is shared, `setup` and `worktree`
belong to the tool. Two config files with overlapping content would drift.

## Examples

See `examples/`: a Flutter Android app built locally, one built in CI, and a
scripts-only project. `examples/invalid-tag-only-with-build.json` is expected to
fail validation.
