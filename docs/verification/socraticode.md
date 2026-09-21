# SocratiCode integration verification

Repeatable evidence for the SocratiCode capability integration.
Current behavior and the decision procedure are owned by the agent-only [`socraticode` skill](../../.agents/skills/socraticode/SKILL.md), the registry annotation by the header of [`../../bin/fm-project-mode.sh`](../../bin/fm-project-mode.sh), the enablement read by the header of [`../../bin/fm-socraticode.sh`](../../bin/fm-socraticode.sh), and the worker-facing brief text by the header of [`../../bin/fm-brief.sh`](../../bin/fm-brief.sh); this page records evidence only.

Date: 2026-09-21.
Host: macOS (Darwin 25.6.0).
Server: `socraticode@latest` over `npx`, registered at user scope in `~/.claude.json` with `SOCRATICODE_LINKED_PROJECTS` and `SOCRATICODE_AUTO_RESUME_PROJECTS` set and **no** `SOCRATICODE_PROJECT_ID`, and no `.socraticode.json` in either indexed clone.
Observed from a crewmate launched through the ordinary `bin/fm-spawn.sh` path into a pooled worktree at `/Users/nathan.gaul/.treehouse/firstmate-7bab20/1/firstmate`.

## The server is reachable from an ordinary spawned worker

No per-task MCP wiring exists or is needed: a worker launched by the normal spawn path inherits the user-scope registration and can call the server from inside its own worktree.
`codebase_list_projects` returned both indexed main checkouts, `/Users/nathan.gaul/Tools/firstmate/projects/jcat` (2961 files, code graph 2110 files / 2537 edges) and `/Users/nathan.gaul/Tools/firstmate/projects/jcat-author` (1432 files, code graph 797 files / 2729 edges).

## Project identity is path-derived, and that is the whole reason for the projectPath rule

These three `codebase_status` calls, made in one session from the worktree above, are what the safety rules in the skill and in every enabled brief rest on.

With the indexed main checkout as `projectPath`, the call succeeds from inside an unrelated worktree:

```
projectPath: /Users/nathan.gaul/Tools/firstmate/projects/jcat
-> Collection: codebase_ed59cd0796be   Status: green   Indexed chunks: 22803
   File watcher: active (watched by another process)
```

With a genuine git worktree of that same indexed repository, the project is unrecognized and the caller is invited to index it:

```
projectPath: /Users/nathan.gaul/.treehouse/jcat-ea62ed/2/jcat
-> No index found for project: /Users/nathan.gaul/.treehouse/jcat-ea62ed/2/jcat
   Run codebase_index to create one.
```

With `projectPath` omitted, resolution falls back to the working directory and produces the same invitation:

```
(no projectPath)
-> No index found for project: /Users/nathan.gaul/.treehouse/firstmate-7bab20/1/firstmate
   Run codebase_index to create one.
```

Accepting either invitation would embed a full repository into a checkout that is deleted at teardown, per worktree, which is why passing the indexed main checkout's absolute path is mandatory and the indexing tools are off limits.
The collection name is a path hash, consistent with identity being derived from the path while no project id is configured.

A committed `projectId` in a project's own `.socraticode.json` is the only mechanism that would let a project's worktrees share one index, because the `SOCRATICODE_PROJECT_ID` environment variable holds a single value and a multi-project home would collapse every project into one collection.
That is a change to a project repository and is not made here.
It would not lift the blind spot either: a shared index is still one index rather than a per-branch one.

## Enabled and not-enabled projects are distinguishable

Against this home's real registry line for `jcat`, which carries no marker, and the same line with the marker added:

```console
$ FM_HOME=/Users/nathan.gaul/Tools/firstmate bin/fm-socraticode.sh jcat; echo "rc=$?"
project: jcat
registry: not-marked
projectPath: -
clone: present
verify: not enabled here; use ordinary search and read tools
rc=3

$ # same line with "+socraticode" added to its existing bracket annotation
$ bin/fm-socraticode.sh jcat; echo "rc=$?"
project: jcat
registry: enabled
projectPath: <home>/projects/jcat
clone: present
verify: codebase_list_projects must list the projectPath above before you rely on it
rc=0

$ bin/fm-project-mode.sh jcat
no-mistakes off
```

The delivery posture is unchanged by the marker, which is the additive-annotation guarantee.
The printed `projectPath` is the same absolute path `codebase_list_projects` reports, so the caller's confirmation step is a direct string comparison.

## Colocated regression coverage

```console
$ bash tests/fm-socraticode.test.sh | tail -1
ok - fm-socraticode: unregistered projects and usage errors fail closed
$ bash tests/fm-brief.test.sh | grep socraticode
ok - fm-brief.sh: --socraticode carries the path rule and the blind spot to ship and scout
ok - fm-brief.sh: --socraticode is absent unless asked for and refuses unusable input
```

`tests/fm-socraticode.test.sh` pins the additive, posture-neutral marker across every annotation shape, the raw `--annotation` read and its refusal to answer for an unregistered project, and the four enablement states (enabled and cloned, not marked, marked without a clone, unregistered) as distinct exit codes.
`tests/fm-brief.test.sh` pins that ship and scout briefs carry the exact `projectPath`, the prohibition on omitting it, the forbidden indexing tools, and the blind-spot warning, that a brief without the flag never mentions the server, and that a relative path, a secondmate charter, and a missing value are each refused without writing a brief.

Neither suite asserts the live index, which is server state rather than a repository fact; the observations above are the record for it and should be re-taken after a SocratiCode upgrade.
