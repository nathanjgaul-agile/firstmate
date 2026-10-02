#!/usr/bin/env bash
# Behavior tests for bin/fm-review-page.sh: notes validation, the rendered
# milestone review page (.agents/skills/ship-landing/assets/review-template.html,
# executed under a minimal DOM shim, clicking its real buttons), the answers it queues for the keyed-answer intake, and the PR
# summary. Serving is bin/fm-bearings-board.sh's `serve`, covered by its tests.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PAGE="$ROOT/bin/fm-review-page.sh"
TMP_ROOT=$(fm_test_tmproot fm-review-page)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

# A project whose feature/x branch changes two files, one carrying </script>.
PROJ="$TMP_ROOT/proj"
fm_git_init_commit "$PROJ"
printf 'a\n' > "$PROJ/a.txt"
git -C "$PROJ" add a.txt
git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit -qm base
git -C "$PROJ" checkout -qb feature/x
printf 'b\n' >> "$PROJ/a.txt"
printf '</script><b>x</b>\n' > "$PROJ/s.html"
git -C "$PROJ" add a.txt s.html
git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit -qm change
printf 'png-bytes' > "$TMP_ROOT/shot.png"

notes() {  # <jq-edit>: write the base notes with <jq-edit> applied
  jq -n "{
    schema: \"fm-review-notes.v1\", title: \"Milestone 1\", verdict_key: \"m1-review\",
    summary: [\"Adds b\"], reuse: [\"git diff\"], new: [\"review page\"],
    ci: \"local CI passed\", risks: [\"none\"],
    try_it: [{step: \"Open it\", before: \"shot.png\", after: \"shot.png\"}],
    key_diffs: [{file: \"a.txt\", note: \"why a\"}, {file: \"s.html\", note: \"why s\"}],
    decisions: [{key: \"m1-pick\", title: \"Pick one\",
      options: [{value: \"a\", label: \"A\"}, {value: \"b\", label: \"B\"}], recommend_value: \"a\"}]
  } | $1" > "$TMP_ROOT/notes.json"
}

render() {
  FM_HOME="$TMP_ROOT/home" "$PAGE" render "$PROJ" feature/x main "$TMP_ROOT/notes.json" 2>&1
}

cat > "$TMP_ROOT/shim.mjs" <<'JS'
import { readFileSync } from "node:fs";
const html = readFileSync(process.argv[2], "utf8");
class Node {
  constructor(tag) { this.tagName = tag; this.className = ""; this.children = []; this._text = "";
    this.handlers = {}; this.value = ""; this.attributes = {}; }
  get textContent() { return this.children.length ? this.children.map((c) => c.textContent).join("") : this._text; }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) { this.children.push(n); return n; }
  setAttribute(k, v) { this.attributes[k] = v; }
  addEventListener(ev, fn) { this.handlers[ev] = fn; }
  all() { return [this, ...this.children.flatMap((c) => c.all())]; }
}
const byId = new Map();
const data = new Node("script");
data.textContent = html.split('<script id="review-data" type="application/json">')[1].split("</script>")[0];
byId.set("review-data", data);
globalThis.document = {
  createElement: (t) => new Node(t),
  getElementById: (id) => { if (!byId.has(id)) byId.set(id, new Node("div")); return byId.get(id); },
};
const queued = [];
globalThis.window = { lavish: { queuePrompt: (text, opts) => queued.push({ text, tag: opts.tag, label: opts.text, data: opts.data }) } };
new Function(html.slice(html.lastIndexOf("<script>") + 8, html.lastIndexOf("</script>")))();
const node = (id) => byId.get(id);
const all = [...byId.values()].flatMap((n) => n.all());
const lines = (cls) => all.filter((n) => n.className.includes(cls)).map((n) => n.textContent);
node("rv-note").value = "ship it";
node("rv-approve").handlers.click();
const pick = node("rv-decisions").all().find((n) => n.tagName === "button" && n.textContent === "B");
pick.handlers.click();
process.stdout.write(JSON.stringify({
  title: node("rv-title").textContent,
  facts: node("rv-facts").textContent,
  keys: node("rv-keys").all().filter((n) => n.className === "rv-key").map((k) => k.textContent),
  added: lines("rv-add"),
  images: all.filter((n) => n.tagName === "img").map((n) => n.src),
  full: node("rv-full").textContent,
  queued,
}) + "\n");
JS

test_render_queues_keyed_answers() {
  local out page json
  notes .
  out=$(render) || fail "render failed: $out"
  page=${out#page: }
  assert_equals "$TMP_ROOT/home/.lavish/review-proj-feature-x.html" "$page" "the page path is not stable per project and feature"
  json=$(node "$TMP_ROOT/shim.mjs" "$page") || fail "the rendered page did not run"
  assert_equals "Milestone 1" "$(jq -r .title <<< "$json")" "title"
  assert_contains "$(jq -r .facts <<< "$json")" "2 files changed" "the diff size is missing"
  assert_contains "$(jq -r .facts <<< "$json")" "local CI passed" "the local CI result is missing"
  assert_contains "$(jq -r '.keys[0]' <<< "$json")" "why a" "a key diff lost its note"
  assert_contains "$(jq -r '.added | join("|")' <<< "$json")" '+</script><b>x</b>' "a diff carrying </script> did not render intact"
  assert_contains "$(jq -r '.images[0]' <<< "$json")" "data:image/png;base64," "the screenshot was not embedded"
  assert_contains "$(jq -r .full <<< "$json")" "diff --git a/s.html" "the full diff is missing"
  assert_equals '{"schema":"fm-bearings-answer.v1","question":"m1-review","selection":"approve","note":"ship it"}' \
    "$(jq -c '.queued[0].data' <<< "$json")" "Approve did not queue the verdict answer"
  assert_equals '{"schema":"fm-bearings-answer.v1","question":"m1-pick","selection":"b","note":""}' \
    "$(jq -c '.queued[1].data' <<< "$json")" "a decision button did not queue its answer"
  assert_equals "choice choice" "$(jq -r '[.queued[].tag] | join(" ")' <<< "$json")" "answers must be choice rows"
  pass "render: the page shows the diff, notes, screenshots, and CI, and queues keyed answers"
}

test_render_refuses_invalid_notes() {
  local edit out
  rm -rf "${TMP_ROOT:?}/home"
  for edit in 'del(.verdict_key)' '.key_diffs = [range(7) | {file: "a.txt", note: "n"}]' \
    '.decisions[0].options[0].value = "reconcile"' '.decisions[0].key = "m1-review"' \
    '.decisions[0].recommend_value = "z"' '.key_diffs[0].file = "missing.txt"' \
    '.try_it[0].before = "nope.png"'; do
    notes "$edit"
    out=$(render) && fail "render accepted invalid notes ($edit): $out"
    assert_absent "$TMP_ROOT/home/.lavish/review-proj-feature-x.html" "a refused render wrote a page ($edit)"
  done
  pass "render: invalid notes, unchanged key diffs, and missing screenshots refuse before writing"
}

test_summary_is_markdown() {
  local out
  notes .
  out=$("$PAGE" summary "$TMP_ROOT/notes.json") || fail "summary failed: $out"
  assert_contains "$out" "- Adds b" "summary bullets are missing"
  assert_contains "$out" "1. Open it" "try-it steps are missing"
  pass "summary: prints the notes as a PR description"
}

test_render_queues_keyed_answers
test_render_refuses_invalid_notes
test_summary_is_markdown
