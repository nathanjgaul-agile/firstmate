#!/usr/bin/env bash
# Strip the per-home +socraticode capability marker from a data/projects.md
# registry line that is about to cross a home boundary.
#
# The marker asserts that THIS home's own clone, at THIS absolute path, has
# itself been indexed (AGENTS.md section 13), so it never inherits: a line
# copied into another home's registry with the token still on it claims
# coverage for a clone nothing has ever indexed. Both the local seeder
# (bin/fm-home-seed.sh) and the remote one (bin/fm-remote-home-seed.sh) copy
# such lines, so the strip lives here once rather than at each of them.
#
# bin/fm-project-mode.sh owns the annotation format and remains its one parser.
# This helper reads a line the same way that parser and every registry selector
# here read it - whitespace-separated fields, "-" then the project name, then a
# bracketed annotation run beginning at field 3 and ending at the first field
# that closes it - so a line those accept cannot slip past this one. A line that
# does not carry the token is reproduced unchanged; only a line the strip
# actually edits is rebuilt from its fields.
fm_registry_strip_socraticode() { # registry line on stdin, stripped line on stdout
  awk '
    {
      if ($1 != "-" || $3 !~ /^\[/) { print; next }
      closed = 0
      end = NF
      for (i = 3; i <= NF; i++) if ($i ~ /\]$/) { end = i; closed = 1; break }
      annotation = ""
      for (i = 3; i <= end; i++) annotation = annotation (annotation == "" ? "" : " ") $i
      gsub(/^\[|\]$/, "", annotation)
      count = split(annotation, token, " ")
      kept = ""
      dropped = 0
      for (i = 1; i <= count; i++) {
        if (token[i] == "+socraticode") { dropped = 1; continue }
        kept = kept (kept == "" ? "" : " ") token[i]
      }
      if (!dropped) { print; next }
      out = $1 " " $2
      if (kept != "") out = out " [" kept (closed ? "]" : "")
      for (i = end + 1; i <= NF; i++) out = out " " $i
      print out
    }
  '
}
