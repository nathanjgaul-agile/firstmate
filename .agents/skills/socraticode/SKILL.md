---
name: socraticode
description: >-
  Agent-only procedure for using the SocratiCode codebase-intelligence MCP server on projects where it is enabled.
  Use before answering an orientation, dependency, blast-radius, or call-flow question about an enabled project, and before marking a project enabled or briefing a worker for one.
  Owns the enablement check, the mandatory explicit-projectPath rule that prevents redundant indexing, and the main-checkout blind spot.
user-invocable: false
metadata:
  internal: true
---

# socraticode

SocratiCode is a local MCP server that answers structural questions about an indexed codebase: semantic plus keyword search, a polyglot dependency graph, symbol-level impact analysis and call flow, and searchable context artifacts.
It runs entirely against local Docker-hosted Qdrant and Ollama, needs no API keys, and sends nothing off the machine.
Its value to this fleet is economic: one structural query replaces a grep-and-read sweep, which is the cheapest available reduction in tokens spent per orientation question.

This skill is the single owner of when and how firstmate and its supervisors use that server.
The worker-facing usage contract that reaches a crewmate is owned by `bin/fm-brief.sh`'s `--socraticode` section, because a crewmate working in a project worktree cannot load this skill.

## The main-checkout blind spot

SocratiCode indexes the main checkouts under `projects/`.
It does not index per-task worktrees, and it is not branch-aware.

So it answers "how does this codebase work" and "what would I break".
It does **not** see a worker's uncommitted or branch-local changes.
An agent that reads a SocratiCode result as a view of its own diff will be wrong.
Never use it to check what a worker changed; read the worktree for that.

A shared index does not soften this.
Even where several worktrees deliberately share one index, that is still one index, not a per-branch one.

## Always pass an explicit projectPath

Every SocratiCode tool that reads a codebase takes a `projectPath`; `codebase_list_projects`, `codebase_about`, and `codebase_health` take no parameters at all, because they describe the server rather than a project.
Always pass the absolute path of the indexed main checkout, exactly as `codebase_list_projects` prints it.

This rule is mandatory, and it is a spend control rather than a style preference.
SocratiCode derives a project's identity from its path unless a project id is configured, and no project id is configured in this fleet today.
Omitting `projectPath` resolves to the current working directory, which for any worker is a disposable task worktree.
Both a worktree path and an omitted path report `No index found` and instruct the caller to run `codebase_index`.
Following that instruction would embed the whole repository again, per worktree, for a checkout that is discarded at teardown.

Three rules follow, and none has an exception:

- Never call a project-scoped SocratiCode tool without `projectPath`, and never pass a worktree path.
- Never run `codebase_index`, `codebase_update`, `codebase_watch`, `codebase_prune`, `codebase_remove`, `codebase_stop`, `codebase_graph_build`, `codebase_graph_remove`, `codebase_context_index`, or `codebase_context_remove`.
  Indexing is the captain's decision and the enabled projects already run a file watcher.
  That ban is about indexing the codebase: `codebase_context_search` self-indexes only the project's own declared context artifacts on first use, and stays available.
  A `No index found` reply means the path was wrong or the project is not enabled, never that you should index it.
- Never call `codebase_graph_visualize` with `mode: "interactive"`; its default `mode: "mermaid"` returns the diagram as text and stays available.
  This is a second and separate reason a tool is off limits, not part of the indexing ban: a worker runs unattended, so it must never take an action that surfaces on someone else's screen or writes a file outside its own worktree.
  Interactive mode does both - it writes a self-contained HTML page and, with `open` defaulting to true, opens it in the captain's browser - and `open: false` still writes the file, so it is not an allowed variant.
  Apply that principle, rather than this one tool name, when a later SocratiCode release adds another tool.

## Confirming a project is enabled

Enablement has three states, and only the third is proof.

1. **Declared.** `data/projects.md` carries a `+socraticode` token in the project's existing bracket annotation, beside its delivery mode.
   Read it with `bin/fm-socraticode.sh <project>`, which also prints the one legal `projectPath`.
2. **Resolvable.** That path exists as a clone in this home.
   The script reports this.
3. **Live.** `codebase_list_projects` lists that exact absolute path.
   Only this settles it, and only an agent with the MCP server attached can check it.

The declared marker can drift from the live index, so never rely on step 1 alone.
Check steps 1 and 2 with the script, then confirm step 3 with one `codebase_list_projects` call before your first real query.

When the states disagree, say so plainly and continue with ordinary tools.
Report the disagreement as a concrete fact - which project, which path, declared enabled but not listed live, or listed live but not marked in the registry - and let the captain decide whether to index or to correct the marker.
Never silently fall back, and never index to close the gap yourself.

Once all three states agree, pass the capability on rather than keeping it to yourself: scaffold the worker's brief with `bin/fm-brief.sh ... --socraticode <projectPath>`, using the exact path you just confirmed.
A crewmate cannot load this skill, so a brief scaffolded without that flag leaves the server attached but unused, which is the spend this capability exists to avoid.

## Which tool answers which question

Reach for SocratiCode first for these, on an enabled project:

- Orientation, "where does X happen", "how does this codebase do Y": `codebase_search`.
- What a file imports and what imports it: `codebase_graph_query`.
- Blast radius before a rename, refactor, or delete: `codebase_impact`.
- A single function or class, with its callers and callees: `codebase_symbol`; `codebase_symbols` to discover what exists first.
- Execution flow forward from an entry point: `codebase_flow`.
- Schemas, API specs, and infra configs registered as context artifacts: `codebase_context_search`.

Keep using ordinary tools for an exact literal string, a file you already know, anything outside an enabled project, and anything about the working tree's own changes.
A result's cited paths are rooted in the indexed main checkout, so map any cited path back to the same relative path in the tree you are actually working in before you read or edit it.

## Secondmate coverage

The marker is per-home, and it is never inherited.
Marking a project `+socraticode` in a home's registry asserts that that home's own clone, at that home's own absolute path, has itself been indexed.
A secondmate home does not inherit the captain's coverage: its clone is an independent checkout at a different absolute path, and SocratiCode derives project identity from the path, so the captain's index says nothing about it.

A secondmate whose home is on this machine reaches the same local server through the user-scope MCP registration, so it may carry the marker - but only once its own `projects/<name>` path has itself been indexed and `codebase_list_projects` lists that path.
Until then its registry must not carry the token, including when the project's registry line was copied in from the main home during seeding; strike the token there rather than leaving a claim that home's own clone does not back.

A remotely placed secondmate cannot be covered at all.
Its host has no registration, its clones are different absolute paths, and the index lives on the captain's machine, so no local indexing there is even reachable.
Never mark a project enabled in a remote secondmate home's registry, and never instruct a remote home to query a server it cannot reach.
When work routes to a remote home, treat SocratiCode as unavailable there and say so rather than assuming coverage.

## Enabling a project, and what stays out of scope

Marking a project `+socraticode` records that it is already indexed.
It does not index anything, and this fleet never indexes a project the captain has not chosen to enable.

To mark one, confirm first that `codebase_list_projects` lists this home's own `projects/<name>` absolute path, and never mark a project whose own path is not listed.
Then add `+socraticode` as an additional token inside the project's existing bracket annotation in `data/projects.md`, creating `[+socraticode]` only where the line carries no bracket at all.
Never write it in place of the mode token, and never add a second bracket.

The leading `+` is what keeps the two readings apart, because the delivery gate and this capability share one bracket annotation and one parser.
A marker written without it is read as a mode token instead: `bin/fm-project-mode.sh` warns `unknown mode` and falls through to `no-mistakes` with yolo off, silently discarding that project's registered delivery posture and its merge authority.
`data/` is gitignored runtime state, so this marking is necessarily an operational edit made in each home; no commit can carry the token.

Three improvements are deliberately not built:

- Indexing a project automatically at project-add time.
  Indexing cost and the Docker stack are the captain's call.
- Sharing one index across a project's worktrees.
  A committed `projectId` in the project's own `.socraticode.json` is the only mechanism that gives each project a stable identity that all of its worktrees inherit; a single `SOCRATICODE_PROJECT_ID` environment variable cannot, because one value would collapse every project in a multi-project home into one collection.
  That is a change to a project repository, so it needs the captain's word.
  The explicit-`projectPath` rule above already removes the redundant-indexing risk without it.
- Branch-aware indexing.
  It is an alternative to a configured project id rather than an addition, since an explicit id is treated as a stable identity and never suffixed, and it would not lift the blind spot for uncommitted work.

Wiring SocratiCode into the no-mistakes pipeline's own internal agent is also out of scope: that agent is launched by no-mistakes rather than by firstmate.
