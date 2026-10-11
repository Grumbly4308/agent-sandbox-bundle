#!/usr/bin/env bash
# The launcher's own parsing: sizes, durations, counts, subnets, URLs, the
# output filter. Sources ./sandbox to reach its functions; calls no Podman.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup
# shellcheck source-path=SCRIPTDIR source=../../sandbox
. "$REPO/sandbox"

# equals <description> <expected> <command...>
equals() {
  local what="$1" want="$2" got
  shift 2
  got="$("$@" 2>/dev/null)" || got="(failed)"
  if [ "$got" = "$want" ]; then pass "$what"; else fail "$what: got '$got', expected '$want'"; fi
}

# --- sizes -------------------------------------------------------------------
equals "4g is 4 GiB in bytes"   4294967296 parse_size --mem 4g
equals "512m is 512 MiB"        536870912  parse_size --mem 512m
equals "64k is 64 KiB"          65536      parse_size --mem 64k
for bad in 4 4G 4gb 0g -1g 1.5g 4x g '' ' 4g' '4g ' 08g '4g;id' 9999999g; do
  refuse "size '$bad' is rejected" parse_size --mem "$bad"
done
says "a rejected size says what to write" "512m, 4g" parse_size --mem 4gb

# --- durations ---------------------------------------------------------------
equals "4h is 14400 seconds"  14400  parse_duration --ttl 4h
equals "90m is 5400 seconds"  5400   parse_duration --ttl 90m
equals "2d is 172800 seconds" 172800 parse_duration --ttl 2d
equals "45s is 45 seconds"    45     parse_duration --ttl 45s
for bad in 4 4H 1w 0h -2h 1.5h '' h '4h30m' '4 h'; do
  refuse "duration '$bad' is rejected" parse_duration --ttl "$bad"
done
# A time limit is a duration or none (0 seconds: no limit).
equals "a time limit of none is 0"   0     parse_ttl --ttl none
equals "a time limit of 4h is 14400" 14400 parse_ttl --ttl 4h
for bad in 1w never '' unlimited; do
  refuse "time limit '$bad' is rejected" parse_ttl --ttl "$bad"
done

# --- counts ------------------------------------------------------------------
equals "512 is a count" 512 parse_count --pids 512
for bad in 0 -1 1.5 abc '' 0x10; do
  refuse "count '$bad' is rejected" parse_count --pids "$bad"
done

# --- subnets -----------------------------------------------------------------
check  "10.201.0.0/24 overlaps 10.0.0.0/8"        cidr_overlap 10.201.0.0/24 10.0.0.0/8
check  "10.201.3.0/24 overlaps 10.201.3.128/25"   cidr_overlap 10.201.3.0/24 10.201.3.128/25
check  "10.201.3.0/24 overlaps host 10.201.3.7"   cidr_overlap 10.201.3.0/24 10.201.3.7/32
check  "anything overlaps 0.0.0.0/0"              cidr_overlap 10.201.3.0/24 0.0.0.0/0
refuse "10.201.0.0/24 is clear of 10.201.1.0/24"  cidr_overlap 10.201.0.0/24 10.201.1.0/24
refuse "10.201.0.0/24 is clear of 192.168.0.0/16" cidr_overlap 10.201.0.0/24 192.168.0.0/16
equals "first free subnet when nothing is used"   10.201.0.0/24 pick_subnet 201 ""
equals "skips subnets in use"                     10.201.2.0/24 pick_subnet 201 "10.201.0.0/24 10.201.1.0/24 192.168.1.0/24"
equals "skips a wider block in use"               10.201.64.0/24 pick_subnet 201 "10.201.0.0/18"
equals "egress range is separate"                 10.202.0.0/24 pick_subnet 202 "10.201.0.0/24"
refuse "refuses when the whole range is taken"    pick_subnet 201 "10.0.0.0/8"

# --- repository addresses ----------------------------------------------------
equals "host of an scp-style address"  github.com    url_host git@github.com:you/project.git
equals "path of an scp-style address"  you/project   url_path git@github.com:you/project.git
equals "host of an https address"      gitlab.example.org url_host https://gitlab.example.org/group/sub/project.git
equals "path of an https address"      group/sub/project  url_path https://gitlab.example.org/group/sub/project.git
equals "host of ssh:// with a port"    git.example.org url_host ssh://git@git.example.org:2222/you/project.git
equals "path of ssh:// with a port"    you/project     url_path ssh://git@git.example.org:2222/you/project.git
equals "a local path has no host"      ""              url_host /home/you/project

# --- session names -----------------------------------------------------------
name="$(new_session_name 'git@github.com:You/My_Project.git')"
if [[ "$name" =~ ^asb-my-project-[0-9a-f]{6}$ ]]; then pass "session name from a URL ($name)"; else fail "session name: $name"; fi
name="$(new_session_name '/tmp/../weird name!!/')"
if [[ "$name" =~ $SESSION_PATTERN ]]; then pass "session name from an odd path ($name)"; else fail "session name: $name"; fi
name="$(new_session_name '///')"
if [[ "$name" =~ ^asb-repo-[0-9a-f]{6}$ ]]; then pass "session name falls back to 'repo'"; else fail "session name: $name"; fi

# --- the output filter  [logical B32] -----------------------------------------
got="$(printf 'a\033[31mb\007c\rd\tE\xc2\x9b2Jf\n' | filter_control)"
want="$(printf 'a[31mbcd\tE2Jf')"
if [ "$got" = "$want" ]; then pass "control characters are removed, tab and newline kept"; else fail "filter_control gave: $(printf '%s' "$got" | od -c | head -3)"; fi
got="$(printf 'caf\xc3\xa9 \xe2\x9c\x93\n' | filter_control)"
if [ "$got" = "$(printf 'caf\xc3\xa9 \xe2\x9c\x93')" ]; then pass "ordinary UTF-8 text passes through"; else fail "filter_control damaged UTF-8"; fi

# --- tokens ------------------------------------------------------------------
check  "an API key looks like a token"       looks_like_token sk-ant-api03-Ab_c9-x
check  "a JWT looks like a token"            looks_like_token eyJhbGciOi.eyJzdWIi.c2ln_-
refuse "a quote is not part of a token"      looks_like_token 'abc"def'
refuse "a backslash is not part of a token"  looks_like_token 'abc\def'
refuse "a space is not part of a token"      looks_like_token 'abc def'
refuse "an empty string is not a token"      looks_like_token ''

# --- KEY=value files are read, never executed ---------------------------------
# shellcheck disable=SC2016  # the file must contain the literal text
printf '%s\n' 'A=1' 'B=two=parts' 'C=$(touch '"$T"'/executed)' 'A=3' > "$T/kv"
equals "the last value of a key wins"     3           kv_get "$T/kv" A
equals "a value keeps its equals signs"   two=parts   kv_get "$T/kv" B
kv_get "$T/kv" C >/dev/null
if [ -e "$T/executed" ]; then fail "a value was executed"; else pass "a value that looks like a command is only text"; fi
equals "a missing key is empty"           ""          kv_get "$T/kv" Z

# --- the agent's env file  [physical B15] --------------------------------------
printf '%s\n' '# comment' '' 'DISABLE_AUTOUPDATER=1' > "$T/env.good"
printf '%s\n' 'GOOD=1' 'ANTHROPIC_API_KEY' > "$T/env.bare"
check  "an env file of NAME=value lines is accepted" check_env_file "$T/env.good"
refuse "a bare NAME (copied in from the host) is refused" check_env_file "$T/env.bare"

# --- settings ----------------------------------------------------------------
rm -f "$T/config/settings"
equals "a default comes from the built-in table" 4g setting MEM
check  "the settings file is created on first use" test -f "$T/config/settings"
check  "it explains each setting" grep -q '^# Size of /tmp' "$T/config/settings"
printf 'MEM=8g\n' >> "$T/config/settings"
equals "your value wins over the default" 8g setting MEM


# --- KEY=value files ---------------------------------------------------------
# A value may end in `=` (a branch name, an address); it must come back whole.
printf '%s\n' 'BRANCH=fix=' 'ORIGIN_URL=https://git.example.test/x.git?a=' 'EMPTY=' > "$T/kv"
equals "a value ending in = is read back whole"       "fix="                                  kv_get "$T/kv" BRANCH
equals "a value with = inside and at the end is kept" "https://git.example.test/x.git?a="     kv_get "$T/kv" ORIGIN_URL
equals "an empty value is empty"                      ""                                      kv_get "$T/kv" EMPTY
equals "a missing key is empty"                       ""                                      kv_get "$T/kv" NOPE

finish
