# Workflow

How work moves from idea to done, in every repo that has adopted this setup.
The point is that the state of a project can be read at a glance.

## Lifecycle

| Event | Issue status |
|---|---|
| Issue opened | Ready (no status label) |
| Draft PR opened with `Refs #N` | `in progress` |
| PR marked ready for review | `in review` |
| PR merged | `to verify`, plus a short summary comment |
| PR closed without merging | Back to ready |
| You close the issue | Status labels removed |
| Stuck on something | `blocked`, set by hand, with a comment saying on what |

"Ready" is the absence of a status label, so there is nothing to maintain.
"Done" means closed, and only the owner closes: a merged PR proves something
was changed, not that it works.

## Rules

1. **`Refs #N`, never `Closes #N`.** GitHub closes an issue on merge when it
   sees a closing keyword; that is exactly what is not wanted here.
2. **Squash merge.** One PR becomes one commit, so issue, PR and commit line up.
3. **Issue-linked PRs rest before merging**, a few hours at minimum, then get a
   self-review. **Small changes without an issue** (a typo, a text tweak) merge
   as soon as their checks pass; the tracker ignores them.
4. **Never push to the default branch.** Everything goes through a PR.
5. **Ask before outward-facing actions**: creating or closing issues in bulk,
   pushing, merging, changing repo settings, tagging, publishing.
6. **No attribution lines** (`Co-Authored-By`, "Generated with ...") in commits,
   PRs or issues.
7. **Building, tagging, publishing and verifying a release are separate
   actions.** None of them happens implicitly, and publishing needs an explicit
   instruction every time.

## Writing issues

The first three sections must make sense to someone who has not read the code.

- **Title:** the symptom or the wish in plain words, not the function name.
- **Summary / Why it matters / What needs to happen:** one or two sentences each.
- **Done when:** a checklist someone else could verify.
- **Technical details:** collapsed. Evidence, `file:line`, approach.

The template is `templates/issue.md`.

## Pull request contract

The tracker builds its `to verify` comment from these headings, so they are a
contract, not decoration:

`What` · `Why` · `How` · `Verified by`

If a section is missing or empty, the comment says so instead of guessing.
`Verified by` should name concrete evidence: tests run, a device check,
screenshots. The template is `templates/pull_request_template.md`.

## Handoff

At the end of a session, post three lines on the issue or PR and repeat them in
chat:

- **Done:** what changed.
- **Left:** what remains.
- **Next:** the one thing to do next.

## What lives where

| Thing | Where |
|---|---|
| Label vocabulary | `labels/vocabulary.json` |
| Per-repo config and its schema | `.github/project.json` in each repo; `schema/project.schema.json` here (see `docs/project-config.md`) |
| Issue and PR templates | `templates/`, copied into a repo when it is adopted |
| Examples | `examples/` |

**Why templates are not at the root of this repo:** files in the root, `docs/`
or `.github/` of an account's `.github` repo become the default issue and PR
templates for *every* repo on the account that has none of its own, including
private ones. Keeping them under `templates/` means nothing changes in a repo
until it is adopted on purpose.
