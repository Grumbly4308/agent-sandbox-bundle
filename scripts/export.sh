#!/usr/bin/env bash
# export.sh — the host-side half of `./sandbox export`.          [logical B27]
#
# Usage:
#   export.sh <bundle-file> <out-dir> <session> <base-commit> <branch> [origin-url]
#
# The launcher has already copied one git bundle (one file holding commits)
# out of the sandbox, cut off at the workspace size. This script turns that
# file into something you can read and push:
#
#   <out-dir>/<session>/repo.git        a bare repository this script created
#   <out-dir>/<session>/export.status   KEY=value lines that `push` and `pr` read
#
# Exit status: 0 = clean. 2 = exported, but a human has to look first
# (attribution could not be removed, a secret was found, gitleaks is missing,
# or history below the starting commit was rewritten). 1 = refused, nothing
# usable was written.
#
# Every byte of the bundle was chosen by the agent, so:
#   - git is only ever run on repositories this script created, with a wiped
#     environment and fixed settings (git_safe below). Closes reference
#     finding C1: the host no longer runs git in a directory whose
#     `.git/config` and hooks the agent wrote.
#   - no file is ever checked out. Everything below reads git objects, so a
#     symlink, a `.gitattributes` or a `.gitmodules` in the tree is only data
#     (the symlink gap in reference finding M4).
#   - the branch name, the starting commit and every path pattern come from
#     the host. No name is read out of the bundle and then used.
#   - everything printed goes through one filter that removes terminal
#     control characters.                                        [logical B32]
#
# Tools used: bash, env, git (2.32 or newer), awk, sed, grep, tr, cut, sort,
# comm, wc, cat, ls, mkdir, mktemp, mv, rm, dirname. Optional: jq (a per-entry summary of
# package.json and package-lock.json), gitleaks (the secret scan; without it
# the export is never marked as scanned).
#
# Environment:
#   SANDBOX_EXPORT_MAX_BYTES    refuse a bundle larger than this many bytes
#   SANDBOX_EXPORT_DIFF_LINES   lines of code diff printed per file (default 200)

set -euo pipefail

# Work on bytes, not on the characters of your locale: the text tools below
# must treat a byte the same way on every host, and git must print its
# messages in one language.
LC_ALL=C
export LC_ALL

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
POLICY_DIR=$SCRIPT_DIR/../policy

LINE_BYTES=2000          # longest line printed; the rest of a longer line is cut
COMMIT_LIST_MAX=500      # commits listed one by one; the rest are counted
BLOB_SUMMARY_MAX=33554432  # 32 MB: a lockfile or manifest larger than this is not summarised
HOST_LIST_MAX=100        # new download hosts listed per lockfile; the rest are counted

SCRATCH=""               # temporary directory, removed on every exit path
REPO=""                  # <out-dir>/<session>/repo.git
EMPTY_TREE=""            # the id of the tree with no files in it

# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------

say()     { printf '%s\n' "$*"; }
heading() { printf '\n==== %s ====\n' "$*"; }
die()     { printf 'export refused: %s\n' "$*" >&2; exit 1; }

# The one output filter.                                         [logical B32]
# Commit messages, file names and file contents are the agent's. Printed raw,
# they could repaint your screen, hide a line of the diff, or (OSC 52) write
# to your clipboard. Three steps:
#   cut  bounds the length of a line, so one endless line cannot stall the
#        steps after it;
#   tr   deletes NUL, ESC, carriage return, DEL and every other ASCII control
#        character except newline and tab;
#   awk  keeps well-formed UTF-8 as it is, deletes the "C1" control
#        characters (U+0080 to U+009F, where 0x9B acts like ESC [), and
#        replaces any byte that is not part of well-formed UTF-8 with `?`.
# shellcheck disable=SC2016  # an awk program: nothing in it is for the shell to expand
AWK_SANITIZE='
BEGIN {
  c = "[\200-\277]"
  utf8 = "[\302-\337]" c "|\340[\240-\277]" c "|[\341-\354\356\357]" c c "|\355[\200-\237]" c
  utf8 = utf8 "|\360[\220-\277]" c c "|[\361-\363]" c c c "|\364[\200-\217]" c c
}
{
  if ($0 ~ /[\200-\377]/) {
    # Fence every well-formed sequence with \001 ... \002 (tr has already
    # deleted those two bytes from the input), then walk the pieces: odd
    # pieces lie outside a fence, even pieces are one sequence each.
    gsub(utf8, "\001&\002")
    n = split($0, piece, /[\001\002]/)
    line = ""
    for (i = 1; i <= n; i++) {
      p = piece[i]
      if (i % 2) gsub(/[\200-\377]/, "?", p)
      else if (p ~ /^\302[\200-\237]$/) p = ""
      line = line p
    }
    $0 = line
  }
  if (length($0) >= w) $0 = $0 " [line cut at " w " bytes]"
  print
}'

sanitize() {
  cut -b "1-$LINE_BYTES" \
    | tr -d '\000-\010\013-\037\177' \
    | awk -v w="$LINE_BYTES" "$AWK_SANITIZE"
}

# A file name on one line: control characters, newline and tab included,
# become `?`, so a name cannot start a line of its own in the report.
printable() { printf '%s' "$1" | tr '\000-\037\177' '?'; }

# --------------------------------------------------------------------------
# git, with nothing inherited                                 [logical B27]
# --------------------------------------------------------------------------

# Each setting is passed to every git command on its command line, where it
# outranks any configuration file. gitleaks runs git itself, so the same list
# is handed to it through GIT_CONFIG_COUNT / GIT_CONFIG_KEY_n / _VALUE_n.
SAFE_SETTINGS=(
  "core.hooksPath=/dev/null"       # no hook can run: there is no hooks directory to look in
  "core.fsmonitor=false"           # never start a "file watcher" program named in a config
  "protocol.allow=never"           # no command here talks to a remote, so no transport is allowed
  "protocol.ext.allow=never"       # in particular not ext::, which runs a shell command
  "protocol.file.allow=never"      # and not local paths, which submodule tricks rely on
  "core.pager=cat"                 # never start a pager program
  "fetch.fsckObjects=true"         # check objects that arrive (see import_bundle: a bundle needs more)
  "transfer.fsckObjects=true"      # the same, for every direction
  "receive.fsckObjects=true"       # the same, for objects pushed into a repository
  "submodule.recurse=false"        # never follow a .gitmodules file
  "core.symlinks=false"            # if a file were ever written, a symlink would become a plain file
  "gc.auto=0"                      # no background housekeeping processes
  "credential.helper="             # no credential helper program, no stored passwords
  "core.attributesFile=/dev/null"  # no per-user attributes file
  "core.quotePath=false"           # print UTF-8 file names as they are; the output filter handles the rest
  "log.mailmap=false"              # a .mailmap in the tree must not rename the authors shown
  "color.ui=false"                 # no colour escape sequences
  "safe.bareRepository=all"        # let gitleaks' git open the bare repository this script made
)
GIT_SAFE_ARGS=()
GIT_SAFE_ENV=()
GITLEAKS_GIT_ENV=()

setup_git() {
  local kv i=0
  for kv in "${SAFE_SETTINGS[@]}"; do
    GIT_SAFE_ARGS+=(-c "$kv")
    GITLEAKS_GIT_ENV+=("GIT_CONFIG_KEY_$i=${kv%%=*}" "GIT_CONFIG_VALUE_$i=${kv#*=}")
    i=$((i + 1))
  done
  GITLEAKS_GIT_ENV+=("GIT_CONFIG_COUNT=$i")
  # `env -i` starts from an empty environment, so no GIT_DIR, GIT_WORK_TREE,
  # GIT_SSH_COMMAND, GIT_EXTERNAL_DIFF or GIT_CONFIG_* of the caller survives.
  GIT_SAFE_ENV=(
    "PATH=$PATH"                   # to find git
    "HOME=$SCRATCH/home"           # an empty directory: no ~/.gitconfig, no ~/.config/git
    "LC_ALL=C"                     # messages in one language
    "GIT_CONFIG_NOSYSTEM=1"        # ignore /etc/gitconfig
    "GIT_CONFIG_GLOBAL=/dev/null"  # ignore the per-user configuration
    "GIT_TERMINAL_PROMPT=0"        # never ask for a password
    "GIT_ATTR_NOSYSTEM=1"          # ignore /etc/gitattributes
  )
}

# The only way this script runs git.
git_safe() {
  env -i "${GIT_SAFE_ENV[@]}" git "${GIT_SAFE_ARGS[@]}" --no-pager "$@"
}

# git on the clean repository. --git-dir names it outright, so git never
# searches the current directory or its parents for a repository.
g() { git_safe --git-dir="$REPO" "$@"; }

# Every diff. `.gitattributes` in the agent's tree could mark a lockfile as
# binary ("Binary files differ") or name a program to convert it. Three
# things stop that:
#   - the repository is bare and its HEAD points at no commit while this
#     script works, so git has no tree to read attributes from (git 2.39
#     reads none in a bare repository; some later versions read HEAD's);
#   - GIT_ATTR_SOURCE names the empty tree, for git 2.40 and later (older
#     versions ignore the variable);
#   - --text prints every file as text, --no-textconv and --no-ext-diff run
#     no converter and no external diff program.
# Renames are not detected, so a moved file shows as one removed and one
# added in full, and each changed path is listed under its own name.
diff_safe() {
  g diff --no-color --no-ext-diff --no-textconv --text --no-renames "$@"
}

# --------------------------------------------------------------------------
# Arguments
# --------------------------------------------------------------------------

usage() {
  say "usage: export.sh <bundle-file> <out-dir> <session> <base-commit> <branch> [origin-url]" >&2
}

# The session and branch names end up in paths and in git arguments, so only
# characters that are safe in both are accepted.
check_session() {
  case $1 in
    '' | *[!A-Za-z0-9._-]* | .* | -* | *..*) die "the session name is not valid" ;;
  esac
  [ "${#1}" -le 128 ] || die "the session name is too long"
}

check_branch() {
  case $1 in
    '' | *[!A-Za-z0-9._/-]* | -* | /* | */ | .* | *. | *..* | *//* | */.* | */-* | *.lock | *.lock/*)
      die "the branch name is not valid" ;;
  esac
  [ "${#1}" -le 200 ] || die "the branch name is too long"
  git_safe check-ref-format "refs/heads/$1" || die "the branch name is not valid"
}

check_commit() {
  case $1 in
    '' | *[!0-9a-f]*) die "the base commit must be 40 or 64 lower-case hex digits" ;;
  esac
  case ${#1} in
    40 | 64) ;;
    *) die "the base commit must be 40 or 64 lower-case hex digits" ;;
  esac
}

check_number() {
  case $2 in
    '' | *[!0-9]*) die "$1 must be a whole number" ;;
  esac
}

# --------------------------------------------------------------------------
# policy/runs-later.txt
# --------------------------------------------------------------------------

KIND_IDS=()
KIND_TITLES=()
PATTERN_KINDS=()
PATTERNS=()

trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

load_patterns() {
  local file=$POLICY_DIR/runs-later.txt line kind=""
  [ -r "$file" ] || die "policy/runs-later.txt is missing"
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(trim "${line%%#*}")
    [ -n "$line" ] || continue
    case $line in
      \[*\]*)
        kind=${line#\[}
        kind=${kind%%\]*}
        KIND_IDS+=("$kind")
        KIND_TITLES+=("$(trim "${line#*\]}")")
        ;;
      *)
        [ -n "$kind" ] || die "policy/runs-later.txt: a pattern comes before the first [group]"
        case $line in
          *[!A-Za-z0-9._*/-]* | /* | */ | -*) die "policy/runs-later.txt: bad pattern: $line" ;;
        esac
        PATTERN_KINDS+=("$kind")
        PATTERNS+=("$line")
        ;;
    esac
  done <"$file"
  [ "${#PATTERNS[@]}" -gt 0 ] || die "policy/runs-later.txt has no patterns"
}

# Fill SPECS with git pathspecs: the patterns of one group ($1 = group id),
# or with $1 = "exclude", everything that matches no pattern at all.
# glob: `*` stops at `/`, `**` does not. icase: ignore case. The leading
# `**/` makes a pattern match in every directory.
SPECS=()
build_specs() {
  local i
  SPECS=()
  for ((i = 0; i < ${#PATTERNS[@]}; i++)); do
    if [ "$1" = exclude ]; then
      SPECS+=(":(exclude,glob,icase)**/${PATTERNS[$i]}")
    elif [ "${PATTERN_KINDS[$i]}" = "$1" ]; then
      SPECS+=(":(glob,icase)**/${PATTERNS[$i]}")
    fi
  done
}

# --------------------------------------------------------------------------
# Bundle in, clean repository out
# --------------------------------------------------------------------------

# Sets TIP. Leaves $REPO as a bare repository holding the bundle's objects
# and one branch.
import_bundle() {
  local bundle=$1 branch=$2 format=$3 sha name found=""

  # A scratch repository of our own to verify in: `git bundle verify` needs
  # one, and it must not be a repository anyone cares about.
  git_safe init --quiet --bare --template= "--object-format=$format" "$SCRATCH/verify.git" \
    || die "git could not create a scratch repository"
  EMPTY_TREE=$(git_safe --git-dir="$SCRATCH/verify.git" hash-object -t tree /dev/null)
  GIT_SAFE_ENV+=("GIT_ATTR_SOURCE=$EMPTY_TREE")   # see diff_safe

  if ! git_safe --git-dir="$SCRATCH/verify.git" bundle verify --quiet -- "$bundle" >"$SCRATCH/verify.log" 2>&1; then
    cat "$SCRATCH/verify.log" >&2
    die "the bundle is damaged, or is not complete on its own"
  fi

  # The names in the bundle are the agent's. They are compared with the one
  # name the host chose and otherwise never used.
  git_safe bundle list-heads -- "$bundle" >"$SCRATCH/heads" 2>/dev/null \
    || die "the bundle's list of branches cannot be read"
  while read -r sha name; do
    if [ "$name" = "refs/heads/$branch" ]; then found=$sha; fi
  done <"$SCRATCH/heads"
  [ -n "$found" ] || die "the bundle does not contain the branch $branch"
  case $found in
    *[!0-9a-f]*) die "the bundle names a commit that is not a commit id" ;;
  esac
  [ "${#found}" -eq "${#EMPTY_TREE}" ] || die "the bundle names a commit that is not a commit id"

  # From here until the branch is in place the repository is unfinished;
  # cleanup removes it if we stop in between.
  printf '%s\n' "$REPO" >"$SCRATCH/unfinished"
  git_safe init --quiet --bare --template= "--object-format=$format" "$REPO" \
    || die "git could not create $REPO"
  # HEAD names a branch that does not exist until the very end. See diff_safe.
  g symbolic-ref HEAD "refs/heads/$branch.unborn"

  # Unpack the objects. This is the step `git fetch <bundle>` performs
  # inside; it is called directly because fetching from a file needs the
  # "file" transport, which is switched off above. It writes no branch.
  if ! g bundle unbundle "$bundle" "refs/heads/$branch" >/dev/null 2>"$SCRATCH/unbundle.log"; then
    cat "$SCRATCH/unbundle.log" >&2
    die "the bundle could not be unpacked"
  fi

  # Check every object, and that nothing the branch needs is missing. git
  # 2.39 does NOT apply fetch.fsckObjects to a bundle, so this is the check.
  # --strict also refuses what git only warns about: a file named `.git`, a
  # NUL byte that would hide the rest of a commit message, a `.gitmodules`
  # that is a symlink.
  if ! g fsck --strict --no-dangling --no-progress "$found" >"$SCRATCH/fsck.log" 2>&1; then
    awk 'NR <= 40' "$SCRATCH/fsck.log" >&2
    die "the bundle contains objects git considers malformed or unsafe (git fsck --strict)"
  fi
  [ "$(g cat-file -t "$found")" = commit ] || die "the branch $branch does not point at a commit"

  # The one branch, under the name the host chose, written by the host.
  g update-ref "refs/heads/$branch" "$found"
  rm -f "$SCRATCH/unfinished"
  TIP=$found
}

# --------------------------------------------------------------------------
# Attribution
# --------------------------------------------------------------------------

# What counts as AI attribution in a commit message. Shared by the scan and
# by the rewrite, so they cannot disagree.
#   - a Co-Authored-By trailer (with its continuation lines) that names an AI
#   - a line that starts "Generated with" or "Generated by", or says
#     "generated with/by <an AI>" anywhere
#   - a line containing the robot emoji (U+1F916)
#   - an "on behalf of <an AI>" line
#   - any other trailer that carries a known AI commit address
AWK_AI_NAMES='
function ai_name(v) {
  v = " " v " "
  if (v ~ /claude|anthropic|openai|codex|gpt|copilot|cursor|opencode|gemini|windsurf|codeium/) return 1
  if (v ~ /[^a-z](ai|bot|aider|llm)[^a-z]/) return 1
  return 0
}
function ai_address(v) {
  if (v ~ /(noreply|no-reply)@(anthropic|openai|cursor)\.com/) return 1
  if (v ~ /noreply@opencode\.ai|cursoragent@cursor\.com/) return 1
  if (v ~ /(\[bot\]|copilot)@users\.noreply\.github\.com/) return 1
  return 0
}'

# The calling program defines emit(line, drop): feed() calls it once for every
# line, with drop = 1 when the line is attribution.
AWK_ATTRIBUTION=$AWK_AI_NAMES'
function is_coauthor(line,    t) {
  t = tolower(line)
  sub(/^[^a-z0-9]+/, "", t)
  return t ~ /^co-authored-by[ \t]*:/
}
function attribution(line, more,    l, t, v) {
  if (index(line, "\360\237\244\226")) return 1
  l = tolower(line)
  t = l
  sub(/^[^a-z0-9]+/, "", t)
  if (t ~ /^co-authored-by[ \t]*:/) {
    v = t " " more
    sub(/^co-authored-by[ \t]*:/, "", v)
    return ai_name(v) || ai_address(v)
  }
  if ((t " ") ~ /^generated (with|by)[^a-z]/) return 1
  if (match(l, /generated (with|by) /) && ai_name(substr(l, RSTART + RLENGTH))) return 1
  if (match(l, /on behalf of /) && ai_name(substr(l, RSTART + RLENGTH))) return 1
  if (t ~ /^[a-z][a-z-]*[ \t]*:/ && ai_address(t)) return 1
  return 0
}
function feed(line) {
  if (holding) {
    if (line ~ /^[ \t]+[^ \t\r]/) {
      held[++nheld] = line
      more = more " " tolower(line)
      return
    }
    release()
  }
  if (is_coauthor(line)) {
    holding = 1
    nheld = 1
    held[1] = line
    more = ""
    return
  }
  emit(line, attribution(line, ""))
}
function release(    i, d) {
  if (!holding) return
  holding = 0
  d = attribution(held[1], more)
  for (i = 1; i <= nheld; i++) emit(held[i], d)
}'

# Scan: count attribution lines in everything on stdin. The input is the raw
# text of many commits, headers included, and every line is treated alike:
# a scan that skipped "headers" could be told by a commit message where the
# next header starts.
# shellcheck disable=SC2016  # an awk program: nothing in it is for the shell to expand
AWK_ATTRIBUTION_COUNT='
function emit(line, drop) { if (drop) hits++ }
{ feed($0) }
END { release(); print hits + 0 }'

# Rewrite: one raw commit in, the same commit out with attribution lines
# removed from the message, parents replaced (remap = "old=new old=new"),
# and any signature dropped, because it signs the old text. Exit status 10
# means lines were removed, 0 means the message is unchanged.
# shellcheck disable=SC2016  # an awk program: nothing in it is for the shell to expand
AWK_ATTRIBUTION_REWRITE='
function blank(s) { return s ~ /^[ \t\r]*$/ }
function emit(line, drop) {
  if (drop) { dropped++; gap = 1; return }
  if (blank(line)) {
    if (gap && (lastblank || !kept)) return
    lastblank = 1
  } else {
    lastblank = 0
    gap = 0
  }
  out[++kept] = line
}
BEGIN {
  n = split(remap, pair, " ")
  for (i = 1; i <= n; i++) { split(pair[i], kv, "="); newparent[kv[1]] = kv[2] }
}
!body {
  if ($0 == "") { body = 1; print; next }
  if (insig && $0 ~ /^ /) next
  insig = 0
  if ($0 ~ /^gpgsig/) { insig = 1; next }
  if ($0 ~ /^parent [0-9a-f]+$/ && (substr($0, 8) in newparent)) $0 = "parent " newparent[substr($0, 8)]
  print
  next
}
{ feed($0) }
END {
  release()
  if (dropped) while (kept > 0 && blank(out[kept])) kept--
  for (i = 1; i <= kept; i++) print out[i]
  exit (dropped ? 10 : 0)
}'

# An author or committer that is an AI commit identity. A message can be
# cleaned; an identity cannot be replaced here, because this script does not
# know whose it should be. So this only reports.
# shellcheck disable=SC2016  # an awk program: nothing in it is for the shell to expand
AWK_AI_IDENTITY='
{
  s = tolower($0)
  sub(/^[0-9a-f]+\t/, "", s)
  if (ai_address(s) || s ~ /\[bot\] </ || index(s, "\360\237\244\226")) print substr($0, 1, 12)
}'

count_attribution() {
  g rev-list "$1" | g cat-file --batch | awk "$AWK_ATTRIBUTION $AWK_ATTRIBUTION_COUNT"
}

# Sets ATTRIBUTION; moves the branch, TIP and RANGE when commits are rewritten.
# Closes the gap in the reference, which only searched for attribution and
# left it in place.
strip_attribution() {
  local branch=$1 hits sha parents p new remap rc changed=0 old_tip=$TIP identities

  heading "Attribution"
  ATTRIBUTION=clean
  hits=$(count_attribution "$RANGE")

  if [ "$hits" -gt 0 ]; then
    # Rebuild the commits, oldest first. A commit gets a new id when its
    # message changes or when a parent got a new id. Tree, author, committer
    # and dates are copied byte for byte.
    # (The list is read on descriptor 3, here and in the loops further down,
    # so that no command inside a loop can swallow part of it from stdin.)
    mkdir "$SCRATCH/map"
    g rev-list --topo-order --reverse --parents "$RANGE" >"$SCRATCH/order"
    while read -r sha parents <&3; do
      remap=""
      for p in $parents; do
        if [ -f "$SCRATCH/map/$p" ]; then
          read -r new <"$SCRATCH/map/$p"
          remap="$remap $p=$new"
        fi
      done
      g cat-file commit "$sha" >"$SCRATCH/commit.in"
      rc=0
      awk -v remap="$remap" "$AWK_ATTRIBUTION $AWK_ATTRIBUTION_REWRITE" \
        "$SCRATCH/commit.in" >"$SCRATCH/commit.out" || rc=$?
      case $rc in
        0) if [ -z "$remap" ]; then continue; fi ;;
        10) changed=$((changed + 1)) ;;
        *) die "could not rewrite commit $sha" ;;
      esac
      new=$(g hash-object -t commit -w --stdin <"$SCRATCH/commit.out")
      printf '%s\n' "$new" >"$SCRATCH/map/$sha"
      if [ "$rc" -eq 10 ]; then
        say "  attribution removed from ${sha:0:12}, which is now ${new:0:12}"
      fi
    done 3<"$SCRATCH/order"

    if [ -f "$SCRATCH/map/$TIP" ]; then
      read -r new <"$SCRATCH/map/$TIP"
      [ "$(g rev-parse "$new^{tree}")" = "$(g rev-parse "$TIP^{tree}")" ] \
        || die "internal error: rewriting commit messages changed the files"
      g update-ref "refs/heads/$branch" "$new" "$TIP"
      TIP=$new
      if [ "$HISTORY" = intact ]; then RANGE="$BASE..$TIP"; else RANGE=$TIP; fi
      ATTRIBUTION=stripped
      say "AI attribution was removed from $changed commit(s). Commit ids changed:"
      say "  tip $old_tip -> $TIP"
    fi

    # Look again. Anything still there is something this script does not
    # know how to remove.
    hits=$(count_attribution "$RANGE")
    if [ "$hits" -gt 0 ]; then
      ATTRIBUTION=refused
      say "REFUSED: $hits line(s) of AI attribution are still in the commits and could not be removed."
    fi
  fi

  identities=$(g log --format='%H%x09%an <%ae>%x09%cn <%ce>' "$RANGE" \
    | awk "$AWK_AI_NAMES $AWK_AI_IDENTITY")
  if [ -n "$identities" ]; then
    ATTRIBUTION=refused
    say "REFUSED: these commits name an AI as author or committer. That cannot be"
    say "fixed here; set the author yourself (git commit --amend --reset-author, or a rebase):"
    say "$identities" | awk 'NR <= 50 { print "  " $0 }'
  fi

  case $ATTRIBUTION in
    clean) say "No AI attribution in the commit messages." ;;
    refused) say "push and pr will refuse this export." ;;
  esac
}

# --------------------------------------------------------------------------
# The report
# --------------------------------------------------------------------------

print_commits() {
  local total
  total=$(g rev-list --count "$RANGE")
  heading "Commits ($total)"
  if [ "$total" -eq 0 ]; then
    say "No new commits on this branch."
    return 0
  fi
  g log --no-color --no-decorate --date=short "--max-count=$COMMIT_LIST_MAX" \
    --format='%h  %ad  %an  %s' "$RANGE"
  if [ "$total" -gt "$COMMIT_LIST_MAX" ]; then
    say "[... $((total - COMMIT_LIST_MAX)) older commits not listed]"
  fi
}

# The code diff: everything that matches no runs-later pattern. At most
# DIFF_LINES lines per file, so that no file can push the section after it
# out of sight. A real "diff --git" line starts in column one; lines of file
# content never do (they start with a space, `+` or `-`), so content cannot
# fake the start of a file.
print_code_diff() {
  heading "Code diff (first $DIFF_LINES lines of each file)"
  say "Files that run later are not in this diff. They have their own section below."
  build_specs exclude
  diff_safe "$BASE_TREE" "$TIP_TREE" -- "${SPECS[@]}" \
    | cut -b "1-$LINE_BYTES" \
    | awk -v n="$DIFF_LINES" '
        function notice() {
          if (hidden) print "[... " hidden " more lines of this file not shown; SANDBOX_EXPORT_DIFF_LINES sets the limit]"
          hidden = 0
        }
        /^diff --git / { notice(); shown = 0; files++ }
        { if (shown < n) { print; shown++ } else hidden++ }
        END { notice(); if (!files) print "(no changes outside the runs-later files)" }'
}

# Write the content of a tree entry to a file, for a summary. Prints nothing
# and returns 0 when the content is there; returns 1 with a reason on stdout
# when it should not be summarised.
entry_to_file() {
  local mode=$1 sha=$2 file=$3 size
  : >"$file"
  case $mode in
    000000) return 0 ;;
    100644 | 100755) ;;
    120000) say "is a symlink, listed under symlinks below"; return 1 ;;
    *) say "is not a file"; return 1 ;;
  esac
  size=$(g cat-file -s "$sha")
  if [ "$size" -gt "$BLOB_SUMMARY_MAX" ]; then
    say "is $size bytes, too large to summarise here"
    return 1
  fi
  g cat-file blob "$sha" >"$file"
}

# Every host that appears in a URL in the file, one per line, sorted.
url_hosts() {
  { grep -aoE '[A-Za-z][A-Za-z0-9+.-]*://[^][/[:space:]"<>()#?,;]+' "$1" || true; } \
    | sed -e 's|^[^:]*://||' -e 's|^[^@]*@||' \
    | tr '[:upper:]' '[:lower:]' \
    | sort -u
}

# shellcheck disable=SC2016  # a jq program: nothing in it is for the shell to expand
JQ_NPM_LOCK='
def flat($prefix):
  ((.dependencies? // {}) | if type == "object" then to_entries else [] end)[]
  | ($prefix + "node_modules/" + .key) as $k
  | {key: $k, value: (.value | if type == "object" then del(.dependencies) else {} end)},
    (.value | if type == "object" then flat($k + "/") else empty end);
def entries:
  if type != "object" then {}
  elif (.packages | type) == "object" then (.packages | with_entries(select(.value | type == "object")))
  else ([flat("")] | from_entries) end;
($old[0] | entries) as $o | ($new[0] | entries) as $n
| [$n | keys[] | select(. as $k | $o | has($k) | not)] as $added
| [$o | keys[] | select(. as $k | $n | has($k) | not)] as $removed
| [$n | keys[] | select(. as $k | ($o | has($k)) and $o[$k] != $n[$k])] as $changed
| "entries: \($added | length) added, \($removed | length) removed, \($changed | length) changed",
  ($changed[]
    | select(. as $k | $o[$k].version == $n[$k].version
        and ($o[$k].resolved != $n[$k].resolved or $o[$k].integrity != $n[$k].integrity))
    | "SAME VERSION, DIFFERENT DOWNLOAD URL OR CHECKSUM: \(tojson)"),
  (($added + $changed)[]
    | select(. as $k | $n[$k].hasInstallScript == true and $o[$k].hasInstallScript != true)
    | "new entry that runs an install script: \(tojson) \($n[.].version | tojson)")'

# shellcheck disable=SC2016  # a jq program: nothing in it is for the shell to expand
JQ_PACKAGE_JSON='
def section($k): (.[$k]? // {}) | if type == "object" then . else {} end;
("scripts", "dependencies", "devDependencies", "optionalDependencies", "peerDependencies", "overrides", "resolutions") as $k
| ($old[0] | section($k)) as $o | ($new[0] | section($k)) as $n
| $n | to_entries[]
| if (.key as $e | $o | has($e) | not) then "added    \($k) \(.key | tojson): \(.value | tojson)"
  elif $o[.key] != .value then "changed  \($k) \(.key | tojson): \(.value | tojson)  (was \($o[.key] | tojson))"
  else empty end'

# Run a jq summary over the old and new copy of a file; say so when the file
# cannot be parsed.
jq_summary() {
  local program=$1 old=$2 new=$3
  if ! command -v jq >/dev/null 2>&1; then
    say "      (jq is not installed: no per-entry summary. Read this file's diff yourself.)"
    return 0
  fi
  if ! jq -n -r --slurpfile old "$old" --slurpfile new "$new" "$program" >"$SCRATCH/jq.out" 2>/dev/null; then
    say "      NOT VALID JSON, before or after: cannot be summarised. Read it yourself."
    return 0
  fi
  if [ -s "$SCRATCH/jq.out" ]; then
    sed 's/^/      /' "$SCRATCH/jq.out"
  else
    say "      (no entries added or changed)"
  fi
}

# A lockfile is thousands of lines nobody reads. Print what matters instead.
summarise_lockfile() {
  local m1=$1 m2=$2 s1=$3 s2=$4 path=$5 old=$SCRATCH/lock.old new=$SCRATCH/lock.new why name counts total

  if ! why=$(entry_to_file "$m1" "$s1" "$old"); then
    say "      before: $why"
  fi
  if ! why=$(entry_to_file "$m2" "$s2" "$new"); then
    say "      now: $why"
    return 0
  fi

  counts=$(diff_safe -U0 "$BASE_TREE" "$TIP_TREE" -- ":(literal)$path" | awk '
    /^diff --git / { hunk = 0; next }
    /^@@/ { hunk = 1; next }
    hunk && /^\+/ { added++ }
    hunk && /^-/ { removed++ }
    END { printf "%d added, %d removed", added, removed }')
  say "      lines: $counts"

  name=$(printf '%s' "${path##*/}" | tr '[:upper:]' '[:lower:]')
  case $name in
    package-lock.json | npm-shrinkwrap.json) jq_summary "$JQ_NPM_LOCK" "$old" "$new" ;;
  esac

  url_hosts "$old" >"$SCRATCH/hosts.old"
  url_hosts "$new" >"$SCRATCH/hosts.new"
  comm -13 "$SCRATCH/hosts.old" "$SCRATCH/hosts.new" >"$SCRATCH/hosts.added"
  if [ -s "$SCRATCH/hosts.added" ]; then
    say "      NEW HOSTS in download URLs:"
    awk -v max="$HOST_LIST_MAX" 'NR <= max { print "        " $0 }' "$SCRATCH/hosts.added"
    total=$(wc -l <"$SCRATCH/hosts.added")
    total=$((total))
    if [ "$total" -gt "$HOST_LIST_MAX" ]; then
      say "        [... and $((total - HOST_LIST_MAX)) more]"
    fi
  else
    say "      no new hosts in download URLs"
  fi
}

summarise_package_json() {
  local m1=$1 m2=$2 s1=$3 s2=$4 old=$SCRATCH/manifest.old new=$SCRATCH/manifest.new why
  entry_to_file "$m1" "$s1" "$old" >/dev/null || true
  if ! why=$(entry_to_file "$m2" "$s2" "$new"); then
    say "      now: $why"
    return 0
  fi
  if [ "$m2" = 000000 ]; then return 0; fi
  jq_summary "$JQ_PACKAGE_JSON" "$old" "$new"
}

# The web address a submodule would be cloned from, according to the
# .gitmodules file in the exported tree. git parses that file as data: it is
# read from the object store and nothing in it is acted on.
submodule_url() {
  local path=$1 record key name NL='
'
  g config --blob "$TIP:.gitmodules" -z --get-regexp '^submodule\..*\.path$' \
    >"$SCRATCH/gitmodules" 2>/dev/null || true
  # (git config -z prints each entry as: key, newline, value, NUL)
  while IFS= read -r -d '' record; do
    key=${record%%"$NL"*}
    if [ "${record#*"$NL"}" = "$path" ]; then
      name=${key#submodule.}
      name=${name%.path}
      g config --blob "$TIP:.gitmodules" --get "submodule.$name.url" 2>/dev/null || true
      return 0
    fi
  done <"$SCRATCH/gitmodules"
}

RUNS_LATER_SUMMARY=()
RUNS_LATER_TOTAL=0

print_runs_later() {
  local k id title count meta path m1 m2 s1 s2 st name size target url links=0

  heading "RUNS LATER — read this first"
  say "Nothing in the sandbox ran these for you. They run on your machine, in CI, or in"
  say "the next agent session, after you merge. Reading them is the only barrier."

  for ((k = 0; k < ${#KIND_IDS[@]}; k++)); do
    id=${KIND_IDS[$k]}
    title=${KIND_TITLES[$k]}
    build_specs "$id"
    if [ "${#SPECS[@]}" -eq 0 ]; then continue; fi
    diff_safe --raw -z --no-abbrev "$BASE_TREE" "$TIP_TREE" -- "${SPECS[@]}" >"$SCRATCH/raw"
    # Each changed path is two NUL-ended fields: its modes and ids, its name.
    count=$(tr -dc '\000' <"$SCRATCH/raw" | wc -c)
    count=$((count / 2))
    if [ "$count" -eq 0 ]; then continue; fi
    RUNS_LATER_SUMMARY+=("$count  $title")
    RUNS_LATER_TOTAL=$((RUNS_LATER_TOTAL + count))

    printf '\n%s: %d changed\n' "$title" "$count"
    while IFS= read -r -d '' meta <&3 && IFS= read -r -d '' path <&3; do
      read -r m1 m2 s1 s2 st <<<"$meta"
      m1=${m1#:}
      say "  $st  $(printable "$path")"
      if [ "$id" = lockfiles ]; then
        summarise_lockfile "$m1" "$m2" "$s1" "$s2" "$path"
      else
        name=$(printf '%s' "${path##*/}" | tr '[:upper:]' '[:lower:]')
        if [ "$name" = package.json ]; then
          summarise_package_json "$m1" "$m2" "$s1" "$s2"
        fi
      fi
    done 3<"$SCRATCH/raw"

    if [ "$id" = lockfiles ]; then
      say "  (lockfile lines are not printed. To read them: git --git-dir=$REPO diff $BASE_TREE $TIP_TREE -- <path>)"
    else
      say ""
      diff_safe "$BASE_TREE" "$TIP_TREE" -- "${SPECS[@]}" | cut -b "1-$LINE_BYTES"
    fi
  done

  # Symlinks and submodules, wherever they are. A symlink is a pointer to
  # another path, possibly outside the repository; a submodule is another
  # repository git will clone from a URL. Export follows neither.
  diff_safe --raw -z --no-abbrev "$BASE_TREE" "$TIP_TREE" >"$SCRATCH/raw"
  : >"$SCRATCH/links"
  while IFS= read -r -d '' meta <&3 && IFS= read -r -d '' path <&3; do
    read -r m1 m2 s1 s2 st <<<"$meta"
    case $m2 in
      120000)
        size=$(g cat-file -s "$s2")
        if [ "$size" -le 4096 ]; then
          target=$(g cat-file blob "$s2" | tr '\000-\037\177' '?')
        else
          target="(a target $size bytes long, not shown)"
        fi
        say "  $st  symlink    $(printable "$path") -> $target" >>"$SCRATCH/links"
        links=$((links + 1))
        ;;
      160000)
        url=$(submodule_url "$path" | tr '\000-\037\177' '?')
        say "  $st  submodule  $(printable "$path") at commit $s2, from ${url:-(no URL in .gitmodules)}" >>"$SCRATCH/links"
        links=$((links + 1))
        ;;
    esac
  done 3<"$SCRATCH/raw"
  if [ "$links" -gt 0 ]; then
    RUNS_LATER_SUMMARY+=("$links  Symlinks and submodules")
    RUNS_LATER_TOTAL=$((RUNS_LATER_TOTAL + links))
    printf '\nSymlinks and submodules: %d added or changed\n' "$links"
    cat "$SCRATCH/links"
    say "  (export followed none of them: no file was checked out and no submodule was fetched)"
  fi

  if [ "$RUNS_LATER_TOTAL" -eq 0 ]; then
    say ""
    say "No changed path matches a runs-later pattern, and no symlink or submodule changed."
  fi
  say ""
  say "This list is made from the path patterns in policy/runs-later.txt; any source file can run later too."
}

# --------------------------------------------------------------------------
# Secret scan
# --------------------------------------------------------------------------

# Sets SCAN. gitleaks reads the commits through git, in the clean repository,
# with the shipped configuration and with every way for the tree to silence
# it switched off (reference finding L4). There is deliberately no fallback
# when gitleaks is missing: a grep here could be mistaken for a scan.
# gitleaks_has_ignore_flags <version>: true when this gitleaks takes
# --ignore-gitleaks-allow and --gitleaks-ignore-path, which arrived in 8.18.
# When the version cannot be read (Debian's package prints no number), the
# help text is asked instead.
gitleaks_has_ignore_flags() {
  local version="$1" major minor rest help
  major=${version%%.*}
  rest=${version#*.}
  minor=${rest%%.*}
  case "$major.$minor" in
    *[!0-9.]* | .* | *.)
      help=$(env -i "PATH=$PATH" gitleaks detect --help 2>&1) || true
      [[ "$help" == *--ignore-gitleaks-allow* && "$help" == *--gitleaks-ignore-path* ]]
      ;;
    *)
      [ "$major" -gt 8 ] || { [ "$major" -eq 8 ] && [ "$minor" -ge 18 ]; }
      ;;
  esac
}

secret_scan() {
  local version major minor rest rc=0
  local flags=() args=()

  heading "Secret scan"
  SCAN=not-run
  if ! command -v gitleaks >/dev/null 2>&1; then
    say "gitleaks is not installed, so NO secret scan was run."
    say "push and pr will refuse this export. Install gitleaks and run export again."
    return 0
  fi

  version=$(env -i "PATH=$PATH" gitleaks version 2>/dev/null | awk 'NR == 1 { print $NF }') || version=""
  version=${version#v}
  case "$version" in *[!0-9.]*) version="" ;; esac   # Debian's build prints a sentence, not a number
  # Without the two flags below, a `gitleaks:allow` comment or a
  # .gitleaksignore the agent wrote could quiet the scan, so an older
  # gitleaks is not run at all (Debian 13 ships 8.16).
  if ! gitleaks_has_ignore_flags "$version"; then
    say "gitleaks ${version:-(unknown version)} is too old: it cannot be told to ignore gitleaks:allow comments and .gitleaksignore files, so NO secret scan was run."
    say "push and pr will refuse this export. Install gitleaks 8.18 or newer (github.com/gitleaks/gitleaks/releases) and run export again."
    return 0
  fi

  flags=(
    --config "$POLICY_DIR/gitleaks.toml"                # our rules, not a .gitleaks.toml from the tree
    --ignore-gitleaks-allow                             # `gitleaks:allow` comments in the code do not count
    --gitleaks-ignore-path "$SCRATCH/gitleaksignore"    # an empty file of ours, not a .gitleaksignore from the tree
    --no-banner                                         # no logo
    --redact                                            # never print the secret it found
    --verbose                                           # do print where it found it
    "--log-opts=$RANGE"                                 # only the commits being exported
  )

  # gitleaks 8.19 renamed `detect --source <repo>` to `git <repo>`.
  major=${version%%.*}
  rest=${version#*.}
  minor=${rest%%.*}
  args=(detect --source "$REPO" "${flags[@]}")
  case "$major.$minor" in
    *[!0-9.]* | .* | *.) ;;
    *)
      if [ "$major" -gt 8 ] || { [ "$major" -eq 8 ] && [ "$minor" -ge 19 ]; }; then
        args=(git "${flags[@]}" "$REPO")
      fi
      ;;
  esac

  say "Running gitleaks ${version:-(unknown version)} over the exported commits ..."
  : >"$SCRATCH/gitleaksignore"
  mkdir -p "$SCRATCH/empty"
  # Run from an empty directory of ours, with git's environment locked down
  # the same way as in git_safe.
  (cd "$SCRATCH/empty" && env -i "${GIT_SAFE_ENV[@]}" "${GITLEAKS_GIT_ENV[@]}" gitleaks "${args[@]}") || rc=$?
  if [ "$rc" -eq 0 ]; then
    SCAN=passed
    say "gitleaks found no secrets."
  else
    SCAN=failed
    say "gitleaks exited with status $rc: it found a secret, or it could not run. Read its output above."
    say "push and pr will refuse this export."
  fi
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

main() {
  if [ $# -lt 5 ] || [ $# -gt 6 ]; then
    usage
    exit 1
  fi
  local bundle=$1 out_dir=$2 session=$3 branch=$5 origin_url=${6:-}
  local session_dir marker status size format i
  BASE=$4
  DIFF_LINES=${SANDBOX_EXPORT_DIFF_LINES:-200}

  setup_git
  mkdir "$SCRATCH/home"

  check_session "$session"
  check_commit "$BASE"
  check_branch "$branch"
  check_number SANDBOX_EXPORT_DIFF_LINES "$DIFF_LINES"
  [ "$DIFF_LINES" -ge 1 ] || die "SANDBOX_EXPORT_DIFF_LINES must be at least 1"
  case $origin_url in
    *[[:cntrl:]]*) die "the origin URL contains control characters" ;;
  esac
  [ -n "$out_dir" ] || die "the output directory is empty"
  case $bundle in /*) ;; *) bundle=$PWD/$bundle ;; esac
  case $out_dir in /*) ;; *) out_dir=$PWD/$out_dir ;; esac
  if [ ! -f "$bundle" ] || [ ! -r "$bundle" ]; then die "the bundle file cannot be read"; fi
  [ -r "$POLICY_DIR/gitleaks.toml" ] || die "policy/gitleaks.toml is missing"
  load_patterns

  # The launcher stopped reading at the workspace size; this is the same
  # limit seen from the other side, for a caller that passes it on.
  size=$(wc -c <"$bundle")
  size=$((size))
  if [ -n "${SANDBOX_EXPORT_MAX_BYTES:-}" ]; then
    check_number SANDBOX_EXPORT_MAX_BYTES "$SANDBOX_EXPORT_MAX_BYTES"
    [ "$size" -le "$SANDBOX_EXPORT_MAX_BYTES" ] \
      || die "the bundle is $size bytes, more than the limit of $SANDBOX_EXPORT_MAX_BYTES"
  fi
  [ "$size" -gt 0 ] || die "the bundle is empty"

  # The output directory. An existing one is reused only if this script made
  # it (it left a marker file there) or if it is empty; anything else might
  # be a directory of yours with the same name.
  session_dir=$out_dir/$session
  marker=$session_dir/.agent-sandbox-export
  status=$session_dir/export.status
  REPO=$session_dir/repo.git
  if [ -e "$session_dir" ] || [ -L "$session_dir" ]; then
    if [ ! -d "$session_dir" ] || [ -L "$session_dir" ]; then
      die "$session_dir exists and is not a directory"
    fi
    if [ ! -f "$marker" ] || [ -L "$marker" ]; then
      [ -z "$(ls -A "$session_dir")" ] \
        || die "$session_dir exists and was not made by export; move it away or choose another --out"
    fi
  else
    mkdir -p "$out_dir"
    (umask 077 && mkdir "$session_dir")
  fi
  printf 'made by agent-sandbox export for session %s\n' "$session" >"$marker"
  # A result from an earlier export must not outlive a failed one.
  rm -f "$status" "$status.tmp"
  rm -rf "$REPO"

  case ${#BASE} in 64) format=sha256 ;; *) format=sha1 ;; esac

  heading "agent-sandbox export: $session"
  say "bundle: $size bytes    branch: $branch    started from: $BASE"

  import_bundle "$bundle" "$branch" "$format"

  # What changed is measured from the commit the host recorded at `run`,
  # never from one the bundle names.
  HISTORY=intact
  if g cat-file -e "$BASE^{commit}" 2>/dev/null && g merge-base --is-ancestor "$BASE" "$TIP" 2>/dev/null; then
    RANGE="$BASE..$TIP"
    BASE_TREE=$(g rev-parse "$BASE^{tree}")
  else
    HISTORY=rewritten
    RANGE=$TIP
    BASE_TREE=$EMPTY_TREE
    say ""
    say "!!!! HISTORY WAS REWRITTEN !!!!"
    say "The commit this session started from ($BASE) is not an ancestor"
    say "of the exported branch. Commits you already had may have been changed. Everything"
    say "below is therefore compared with an EMPTY repository: every file is shown as new,"
    say "every commit is listed and scanned, and nothing is assumed to be unchanged."
  fi

  strip_attribution "$branch"
  TIP_TREE=$(g rev-parse "$TIP^{tree}")

  print_commits
  print_code_diff
  print_runs_later
  secret_scan

  # From now on HEAD names the exported branch, so the repository can be
  # looked at and cloned in the ordinary way.
  g symbolic-ref HEAD "refs/heads/$branch"

  {
    printf 'SCAN=%s\n' "$SCAN"
    printf 'ATTRIBUTION=%s\n' "$ATTRIBUTION"
    printf 'TIP=%s\n' "$TIP"
    printf 'BRANCH=%s\n' "$branch"
    printf 'ORIGIN_URL=%s\n' "$origin_url"
    printf 'BASE_COMMIT=%s\n' "$BASE"
    printf 'HISTORY=%s\n' "$HISTORY"
  } >"$status.tmp"
  mv "$status.tmp" "$status"

  heading "Summary"
  if [ "$RUNS_LATER_TOTAL" -gt 0 ]; then
    say "RUNS LATER — $RUNS_LATER_TOTAL path(s) to read before anything else (details above):"
    for ((i = 0; i < ${#RUNS_LATER_SUMMARY[@]}; i++)); do
      say "  ${RUNS_LATER_SUMMARY[$i]}"
    done
  else
    say "RUNS LATER — no changed path matches a pattern. Any source file can still run later."
  fi
  say "history:      $HISTORY"
  say "attribution:  $ATTRIBUTION"
  say "secret scan:  $SCAN"
  say "tip:          $TIP"
  say "repository:   $REPO"
  say "status file:  $status"

  if [ "$SCAN" = passed ] && [ "$ATTRIBUTION" != refused ] && [ "$HISTORY" = intact ]; then
    say "Clean. Read the diff, then: ./sandbox push"
    echo 0 >"$SCRATCH/result"
  else
    say "NEEDS A HUMAN: see the lines above that are not 'intact', 'clean', 'stripped' or 'passed'."
    echo 2 >"$SCRATCH/result"
  fi
}

# Remove the scratch directory on every way out, and with it a clean
# repository that was started but not finished.
# shellcheck disable=SC2317  # reached through the EXIT trap below
cleanup() {
  local unfinished
  if [ -n "$SCRATCH" ] && [ -d "$SCRATCH" ]; then
    if [ -f "$SCRATCH/unfinished" ] && read -r unfinished <"$SCRATCH/unfinished" && [ -n "$unfinished" ]; then
      rm -rf "$unfinished"
    fi
    rm -rf "$SCRATCH"
  fi
}

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/agent-sandbox-export.XXXXXX")
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Everything main prints, on either stream, goes through the output filter.
# main runs in a subshell so that the filter sees all of it. Only a main that
# reached its end decides between 0 and 2; a refusal, or a tool that failed
# on the way, is always 1, whatever status that tool happened to return.
set +e
(
  set -e
  main "$@"
) 2>&1 | sanitize
main_status=${PIPESTATUS[0]}
set -e
if [ "$main_status" -eq 0 ] && [ -f "$SCRATCH/result" ]; then
  read -r result <"$SCRATCH/result"
  exit "$result"
fi
if [ "$main_status" -ne 1 ]; then
  say "export failed: a step ended with status $main_status. Nothing was marked as exported."
fi
exit 1
