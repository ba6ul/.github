# Shared workflows

Two pieces, both called from a few lines in each adopted repo. `repotools
bootstrap` writes the callers from `templates/workflows/`.

| Piece | What it does | Kind |
|---|---|---|
| `actions/tracker` | Moves the issues a PR names on a `Refs` line through `in progress`, `in review`, `to verify`; posts the merge summary; clears status when the issue is closed. Never closes an issue. | Composite action, used as a step |
| `.github/workflows/ci.yml` | Runs `checks.analyze` and `checks.test` from the repo's `.github/project.json`, after installing `checks.toolchain`. Check name: `ci / checks`. | Reusable workflow |

## Things that are easy to get wrong

- **Permissions.** New repos give the workflow token read-only access, and an explicit
  `permissions:` block sets everything it does not list to `none`. The tracker caller
  needs `contents: read`, `checks: read`, `issues: write`, `pull-requests: write`.
  Without `checks: read` the merge summary says the checks "could not be read".
- **Why the tracker is an action, not a reusable workflow.** A reusable workflow cannot
  find out which version of itself was called, so it could not fetch matching tooling.
  A composite action is downloaded whole at the version the caller names.
- **Dart is installed by the action itself** (pinned, checksum-verified), because
  `dart-lang/setup-dart` cannot be nested inside a composite action.
- **PR events use GitHub's cached merge of the PR with the base branch.** After
  changing a workflow file on the base branch, an already-open PR keeps using the old
  one until the PR branch gets a new commit.
- **Versions.** Callers reference `@v1`. Until that tag exists, use
  `repotools bootstrap --workflow-ref <branch>`.
- **Cost.** Runs on Ubuntu; on private repos Windows minutes count double. The tracker
  takes about 20 seconds per event.
