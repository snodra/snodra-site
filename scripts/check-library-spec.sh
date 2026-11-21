#!/usr/bin/env bash
# Keeps the "Writing a library" pages (docs/library-authors/*.md) in step with hub.proto, the one source of truth.
#
# Fails when a page names a protocol message, field, enum value or rpc that hub.proto does not have, when the check
# would pass vacuously (hub.proto yields no names, or the pages name none), and when a frozen SQL schema file of
# docs/library-authors/sql/v1 is missing or does not have its pinned SHA-256. Links are checked by
# `mkdocs build --strict`, not here. The marking convention:
#
#   - `Message.field`, `Message.field.field` (followed through the field's message type), `Enum.VALUE` and `Hub.Rpc`
#     in an inline code span name the protocol, on every page. A oneof's name counts as a field of its message.
#   - An inline code span that is one UpperCamelCase identifier (`RegisterAck`) names a message, an enum or the service.
#   - A brace form, `Message{...}`, in an inline code span or on a line of a ```text block: the name is a message;
#     inside the braces, each comma-separated item `field = VALUE` names a field of it, and VALUE, when it is an
#     UPPER_CASE word, a value of the field's enum (an `error` field: of ErrorCode). In an inline span a bare
#     lower-case item (`ReplyEnd{parts}`) and a bare UPPER_CASE item (`Error{NO_HANDLER}`, an ErrorCode) are checked
#     too; in a ```text block they are not (diagrams write ids there, `ReplyPart{s, seq 1, ...}`).
#   - What escapes the check: other fenced blocks (proto, json, mermaid, ...) and HTML comments; brace items that span
#     lines; items of another shape (`<id>#1`, quoted text, `seq 1`); a bare `NO_HANDLER` outside braces; library paths
#     (`snodra_messaging::Config`); message type names (`snodra.events.Search`). Write `ErrorCode.NO_HANDLER` where the
#     protocol value is meant.
#
# hub.proto is read from $SNODRA_PROTO_SOURCE, else ../snodra-server/proto/hub.proto (a sibling checkout); when
# neither exists the script fails: it never passes without a proto.
#
# Usage: scripts/check-library-spec.sh [--list]
#   --list   also print every protocol name the pages use, with its verdict
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
list=false
if [ "${1:-}" = "--list" ]; then
  list=true
  shift
fi
dir="$root/docs/library-authors"
proto="${SNODRA_PROTO_SOURCE:-$root/../snodra-server/proto/hub.proto}"

if [ ! -f "$proto" ]; then
  echo "library spec: hub.proto not found at $proto (set SNODRA_PROTO_SOURCE)" >&2
  exit 1
fi

# The frozen V1 SQL schema files (docs/library-authors/sql/v1): their SHA-256 is the one
# docs/library-authors/message-store-add-ons.md states and both libraries pin. A missing file is a failure.
if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" | awk '{ print $1 }'; }
elif command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$1" | awk '{ print $1 }'; }
else
  echo "library spec: neither sha256sum nor shasum found" >&2
  exit 1
fi
for pinned in \
  "postgresql 0b2d179a18580092cd7622d11e46451a08b64fad7d6d585450a0919f9148ca6a" \
  "mysql f6e28f7c12c0e7db148b534c6ac9d04e5a375bd3b873d63a1c8080707af0cf31"; do
  dialect="${pinned%% *}"
  want="${pinned#* }"
  schema="$dir/sql/v1/$dialect/V1__snodra.sql"
  if [ ! -f "$schema" ]; then
    echo "library spec: frozen schema not found at $schema" >&2
    exit 1
  fi
  got="$(sha256 "$schema")"
  if [ "$got" != "$want" ]; then
    echo "library spec: $schema has SHA-256 $got, frozen V1 is $want" >&2
    exit 1
  fi
done
pages=()
for page in "$dir"/*.md; do
  [ -f "$page" ] && pages+=("$page")
done
if [ "${#pages[@]}" -eq 0 ]; then
  echo "library spec: no protocol names found: no pages in $dir" >&2
  exit 1
fi

# The names hub.proto defines, one per line:
#   M <message>   E <enum>   S <service>
#   F <message>.<field> <type>   V <enum>.<VALUE>   R <service>.<rpc>
names="$(mktemp)"
trap 'rm -f "$names"' EXIT
awk '
  function push(kind, name) { depth++; kinds[depth] = kind; owners[depth] = name }
  function pop() { if (depth > 0) depth-- }
  # The message a field belongs to: the innermost message (a oneof sits inside one).
  function message() { for (i = depth; i > 0; i--) if (kinds[i] == "message") return owners[i]; return "" }
  {
    line = $0
    sub(/\/\/.*/, "", line)
    if (line ~ /^[ \t]*$/) next
    if (match(line, /^[ \t]*(message|enum|service|oneof)[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
      split(substr(line, RSTART, RLENGTH), parts, /[ \t]+/)
      n = 0; for (p in parts) n++
      kind = ""; name = ""
      for (p = 1; p <= n; p++) if (parts[p] != "") { if (kind == "") kind = parts[p]; else if (name == "") name = parts[p] }
      if (kind == "message") print "M", name
      else if (kind == "enum") print "E", name
      else if (kind == "service") print "S", name
      else if (kind == "oneof") print "F", message() "." name, "oneof"
      push(kind, name)
      rest = substr(line, RSTART + RLENGTH)
      if (rest ~ /\}/) pop()
      next
    }
    if (line ~ /^[ \t]*\}/) { pop(); next }
    if (depth == 0) next
    kind = kinds[depth]
    if (line ~ /^[ \t]*(reserved|option)[ \t]/) next
    if (kind == "service" && match(line, /rpc[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
      rpc = substr(line, RSTART, RLENGTH); sub(/rpc[ \t]+/, "", rpc)
      print "R", owners[depth] "." rpc
      next
    }
    if (kind == "enum" && match(line, /^[ \t]*[A-Z_][A-Z0-9_]*[ \t]*=/)) {
      value = substr(line, RSTART, RLENGTH); gsub(/[ \t=]/, "", value)
      print "V", owners[depth] "." value
      next
    }
    if ((kind == "message" || kind == "oneof") && match(line, /[A-Za-z_][A-Za-z0-9_]*[ \t]*=[ \t]*[0-9]+/)) {
      field = substr(line, RSTART, RLENGTH); sub(/[ \t]*=.*/, "", field)
      type = substr(line, 1, RSTART - 1)
      gsub(/^[ \t]+|[ \t]+$/, "", type)
      sub(/^repeated[ \t]+/, "", type)
      if (type ~ /^map</) type = "map"
      print "F", message() "." field, type
    }
  }
' "$proto" > "$names"

awk -v listing="$list" -v pagesdir="$dir" -v namesfile="$names" '
  function problem(text) { problems++; print FILENAME ":" FNR ": " text }
  function verdict(name, ok) {
    used++
    if (listing == "true") print (ok ? "ok      " : "MISSING ") name
    if (!ok) problem("`" name "` is not in hub.proto")
  }
  # A dotted reference: Message.field[.field...], Enum.VALUE or Service.Rpc.
  function dotted(span,    parts, n, owner, i, key) {
    n = split(span, parts, ".")
    owner = parts[1]
    if (owner in enums) { verdict(span, n == 2 && ((owner "." parts[2]) in values)); return }
    if (owner in services) { verdict(span, n == 2 && ((owner "." parts[2]) in rpcs)); return }
    if (!(owner in messages)) { verdict(span, 0); return }
    for (i = 2; i <= n; i++) {
      key = owner "." parts[i]
      if (!(key in fields)) { verdict(span, 0); return }
      if (i < n) {
        owner = fields[key]
        if (!(owner in messages)) { verdict(span, 0); return }
      }
    }
    verdict(span, 1)
  }
  # VALUE given to field `key` of a message: a value of the field enum, of ErrorCode for an Error field.
  function value_of(key, value,    type) {
    type = fields[key]
    if (type == "Error") type = "ErrorCode"
    if (type in enums) verdict(type "." value, (type "." value) in values)
  }
  # A brace form Name{items}: the name, then the items (see the header of this script). strict: an inline span.
  function braces(form, strict,    name, body, items, n, i, item, key, value) {
    name = form; sub(/\{.*$/, "", name)
    body = form; sub(/^[^{]*\{/, "", body); sub(/\}.*$/, "", body)
    verdict(name, (name in messages))
    if (!(name in messages)) return
    n = split(body, items, ",")
    for (i = 1; i <= n; i++) {
      item = items[i]
      gsub(/^[ \t]+|[ \t]+$/, "", item)
      if (match(item, /^[a-z][a-z0-9_]*[ \t]*=/)) {
        key = substr(item, 1, RLENGTH); sub(/[ \t]*=$/, "", key)
        value = substr(item, RLENGTH + 1); gsub(/^[ \t]+/, "", value); sub(/[^A-Z0-9_].*$/, "", value)
        verdict(name "." key, (name "." key) in fields)
        if (value ~ /^[A-Z][A-Z0-9_]*$/ && ((name "." key) in fields)) value_of(name "." key, value)
      } else if (strict && item ~ /^[a-z][a-z0-9_]*$/) {
        verdict(name "." item, (name "." item) in fields)
      } else if (strict && item ~ /^[A-Z][A-Z0-9_]+$/ && name == "Error") {
        verdict("ErrorCode." item, ("ErrorCode." item) in values)
      }
    }
  }
  BEGIN {
    while ((getline line < namesfile) > 0) {
      split(line, f, " ")
      if (f[1] == "M") messages[f[2]] = 1
      else if (f[1] == "E") enums[f[2]] = 1
      else if (f[1] == "S") services[f[2]] = 1
      else if (f[1] == "F") fields[f[2]] = f[3]
      else if (f[1] == "V") values[f[2]] = 1
      else if (f[1] == "R") rpcs[f[2]] = 1
      defined++
    }
    close(namesfile)
    if (defined == 0) { print "library spec: no protocol names read from the proto: nothing to check against"; failed = 1; exit 1 }
  }
  FNR == 1 {
    fenced = 0; textblock = 0; commented = 0
    pagecount++
  }
  {
    line = $0
    if (line ~ /^[ \t]*(```|~~~)/) {
      if (fenced) { fenced = 0; textblock = 0 } else { fenced = 1; textblock = (line ~ /^[ \t]*```text[ \t]*$/) }
      next
    }
    if (fenced) {
      if (textblock) {
        text = line
        while (match(text, /[A-Z][A-Za-z0-9]*[a-z][A-Za-z0-9]*\{[^}]*\}/)) {
          form = substr(text, RSTART, RLENGTH); text = substr(text, RSTART + RLENGTH)
          braces(form, 0)
        }
      }
      next
    }
    if (commented) { if (line ~ /-->/) { commented = 0; sub(/^.*-->/, "", line) } else next }
    while (match(line, /<!--/)) {
      head = substr(line, 1, RSTART - 1); tail = substr(line, RSTART + 4)
      if (match(tail, /-->/)) line = head substr(tail, RSTART + 3)
      else { line = head; commented = 1 }
    }
    text = line
    while (match(text, /`[^`]+`/)) {
      span = substr(text, RSTART + 1, RLENGTH - 2)
      text = substr(text, RSTART + RLENGTH)
      gsub(/^ +| +$/, "", span)
      if (span ~ /^[A-Z][A-Za-z0-9]*(\.[A-Za-z_][A-Za-z0-9_]*)+$/) dotted(span)
      else if (span ~ /^[A-Z][A-Za-z0-9]*[a-z][A-Za-z0-9]*\{.*\}$/) braces(span, 1)
      else if (span ~ /^[A-Z][A-Za-z0-9]*[a-z][A-Za-z0-9]*$/)
        verdict(span, (span in messages) || (span in enums) || (span in services))
    }
  }
  END {
    if (failed) exit 1
    if (used == 0) { print "library spec: no protocol names found in the pages of " pagesdir ": nothing was checked"; exit 1 }
    if (problems > 0) {
      print "library spec: " problems " problem(s) in " pagesdir
      exit 1
    }
    print "library spec: " pagecount " pages, " used " protocol names check out"
  }
' "${pages[@]}"
