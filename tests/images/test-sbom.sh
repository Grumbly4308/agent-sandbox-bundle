#!/usr/bin/env bash
# images/agent/make-sbom.sh, run on this machine: the output is CycloneDX 1.5
# JSON naming the base image, Node, the Debian packages and the global npm
# packages, each with a version. Needs dpkg-query and npm, as the image has.
# Holds jq programs and dpkg format strings in single quotes, hence:
# shellcheck disable=SC2016
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

sbom="$root/images/agent/make-sbom.sh"
base="docker.io/library/node:22-bookworm-slim@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

check_not "make-sbom: refuses to run without its three arguments" bash "$sbom"

if ! command -v dpkg-query >/dev/null || ! command -v npm >/dev/null; then
  echo "SKIP make-sbom: this machine has no dpkg-query or no npm; the run needs both"
  finish
  exit 0
fi

out="$scratch/sbom.json"
if bash "$sbom" "$base" localhost/agent-sandbox/agent-claude node-2.0.0 >"$out" 2>"$scratch/sbom.err"; then
  pass "make-sbom: runs"
else
  fail "make-sbom: failed: $(cat "$scratch/sbom.err")"
fi
check "sbom: valid JSON" jq -e . "$out"
check "sbom: CycloneDX 1.5" jq -e '.bomFormat == "CycloneDX" and .specVersion == "1.5" and .version == 1' "$out"
check "sbom: describes the image" \
  jq -e '.metadata.component == {type: "container", name: "localhost/agent-sandbox/agent-claude", version: "node-2.0.0"}' "$out"
check "sbom: records the base image reference, digest included" \
  jq -e --arg b "$base" '.metadata.properties | any(.name == "agent-sandbox:base-image" and .value == $b)' "$out"
check "sbom: lists the base image as a component" \
  jq -e '.components | any(.type == "container" and .name == "docker.io/library/node:22-bookworm-slim" and (.version | startswith("sha256:")))' "$out"
check "sbom: lists Node with its version" \
  jq -e --arg v "$(node -p process.versions.node)" '.components | any(.name == "node" and .version == $v)' "$out"

# Every installed Debian package, with dpkg's version.
want_debs="$(dpkg-query -W -f '${Package}\t${Version}\t${db:Status-Abbrev}\n' | awk -F'\t' '$3 ~ /^ii/ {print $1 "@" $2}' | sort -u)"
got_debs="$(jq -r '.components[] | select((.purl // "") | startswith("pkg:deb/")) | .name + "@" + .version' "$out" | sort -u)"
if [ -n "$want_debs" ] && [ "$want_debs" = "$got_debs" ]; then
  pass "sbom: every Debian package with its version ($(printf '%s\n' "$want_debs" | wc -l))"
else
  fail "sbom: the Debian package list differs from dpkg-query"
fi

# Every global npm package, with the version in its package.json.
npm_root="$(npm root -g)"
missing=""
for pkg_json in "$npm_root"/*/package.json "$npm_root"/@*/*/package.json; do
  [ -f "$pkg_json" ] || continue
  name="$(jq -r .name "$pkg_json")"
  version="$(jq -r .version "$pkg_json")"
  if ! jq -e --arg n "$name" --arg v "$version" '.components | any(.name == $n and .version == $v and ((.purl // "") | startswith("pkg:npm/")))' "$out" >/dev/null; then
    missing="$missing $name@$version"
  fi
done
if [ -z "$missing" ]; then pass "sbom: every global npm package with its version"; else fail "sbom: missing npm packages:$missing"; fi
check "sbom: npm itself is listed" jq -e '.components | any(.name == "npm" and ((.purl // "") | startswith("pkg:npm/npm@")))' "$out"
check "sbom: every component has a name and a version" \
  jq -e '.components | all((.name | type == "string" and length > 0) and (.version | type == "string" and length > 0))' "$out"
check "sbom: scoped npm names are escaped in the package URL" \
  jq -e '[.components[] | select((.purl // "") | startswith("pkg:npm/@"))] | length == 0' "$out"

finish
