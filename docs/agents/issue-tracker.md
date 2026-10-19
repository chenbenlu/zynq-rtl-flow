# Issue tracker: GitHub

Issues and specs live as GitHub issues. Use the `gh` CLI for every operation;
inside a clone it infers the repo from `git remote -v`.

## Issues

| Operation | Command |
|---|---|
| Create | `gh issue create --title "..." --body "..."` (heredoc for multi-line bodies) |
| Read | `gh issue view <number> --comments`, filtering comments with `jq`; also fetch labels |
| List | `gh issue list --state open --json number,title,body,labels,comments --jq '[.[] \| {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'` with `--label` / `--state` filters |
| Comment | `gh issue comment <number> --body "..."` |
| Label | `gh issue edit <number> --add-label "..."` / `--remove-label "..."` |
| Close | `gh issue close <number> --comment "..."` |

When a skill says **"publish to the issue tracker"**, create a GitHub issue.
When it says **"fetch the relevant ticket"**, run `gh issue view <number> --comments`.

## Pull requests as a triage surface

**PRs as a request surface: no.** _(Set to `yes` if this repo treats external PRs as feature requests; `/triage` reads this flag.)_

When `yes`, PRs go through the same labels and states as issues, with the `gh pr` equivalents:

- **Read**: `gh pr view <number> --comments`; `gh pr diff <number>` for the diff.
- **List external PRs**: `gh pr list --state open --json number,title,body,labels,author,authorAssociation,comments`,
  keeping only `authorAssociation` of `CONTRIBUTOR`, `FIRST_TIME_CONTRIBUTOR` or `NONE`
  (drop `OWNER`/`MEMBER`/`COLLABORATOR`).
- **Comment / label / close**: `gh pr comment`, `gh pr edit --add-label`/`--remove-label`, `gh pr close`.

Issues and PRs share one number space, so a bare `#42` may be either: try
`gh pr view 42`, fall back to `gh issue view 42`.

## Wayfinding operations

Used by `/wayfinder`. The **map** is one issue; its **child** issues are the tickets.

- **Map**: an issue labelled `wayfinder:map` whose body holds Notes / Decisions-so-far / Fog.
  `gh issue create --label wayfinder:map`.
- **Child ticket**: linked to the map as a GitHub sub-issue (`gh api` on the
  sub-issues endpoint). Without sub-issues, add the child to a task list in the map
  body and put `Part of #<map>` at the top of the child body. Labels:
  `wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`). A claimed ticket is
  assigned to the driving dev.
- **Blocking**: GitHub's **native issue dependencies** — canonical and UI-visible.
  Add an edge with
  `gh api --method POST repos/<owner>/<repo>/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>`,
  where `<blocker-db-id>` is the blocker's numeric **database id**
  (`gh api repos/<owner>/<repo>/issues/<n> --jq .id`), _not_ the `#number` or
  `node_id`. `issue_dependencies_summary.blocked_by` counts open blockers only — the
  live gate. Without dependencies, put a `Blocked by: #<n>, #<n>` line at the top of
  the child body. A ticket is unblocked when every blocker is closed.
- **Frontier query**: list the map's open children (`gh issue list --state open`,
  scoped to the map's sub-issues / task list); drop any with an open blocker
  (`issue_dependencies_summary.blocked_by > 0`, or an open issue in the `Blocked by`
  line) or an assignee; first in map order wins.
- **Claim**: `gh issue edit <n> --add-assignee @me` — the session's first write.
- **Resolve**: `gh issue comment <n> --body "<answer>"`, then `gh issue close <n>`,
  then append a context pointer (gist + link) to the map's Decisions-so-far.
