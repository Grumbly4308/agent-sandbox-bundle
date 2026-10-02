#!/usr/bin/env bash
# make-sbom.sh <base-image> <image-name> <image-version>
#
# Print, on standard output, a list of everything installed in this image: an
# SBOM ("software bill of materials"). The image build runs it once and
# stores the result as /usr/share/sandbox/sbom.json, so you can answer "which
# version of X was in the sandbox that day?" long after the session is gone.
#
# What it lists:
#   * the base image reference, digest included (from images/PINS)
#   * Node.js itself, which comes with the base image and is no package
#   * every Debian package, with the version dpkg reports
#   * every npm package installed globally, with its version, including the
#     ones nested inside another (the agent CLI's platform package is)
#
# Format: CycloneDX 1.5 JSON, kept minimal, so standard SBOM tools can read
# it. No external tool is used: dpkg-query and Node's standard library only.
#
# A list, not a guarantee: it records what was installed, not that any of it
# is trustworthy. A compromised upstream at a pinned version is still
# compromised.
set -euo pipefail

[ "$#" -eq 3 ] || { echo "usage: make-sbom.sh <base-image> <image-name> <image-version>" >&2; exit 2; }

# Node reads the program from standard input (the here-document) and the
# three arguments after `-`.
exec node - "$@" <<'NODE'
'use strict';
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const [baseImage, imageName, imageVersion] = process.argv.slice(2);
const components = [];

// The base image. Its name and digest are the whole identity.
components.push({
  type: 'container',
  name: baseImage.split('@')[0],
  version: baseImage.includes('@') ? baseImage.split('@')[1] : 'unpinned',
  description: 'base image (images/PINS)',
});

// Node.js: shipped by the base image under /usr/local, known to neither dpkg
// nor npm.
components.push({
  type: 'application',
  name: 'node',
  version: process.versions.node,
  purl: `pkg:generic/node@${process.versions.node}`,
});

// Debian packages. One line per package: name, version, architecture.
const dpkg = execFileSync(
  'dpkg-query',
  ['-W', '-f', '${Package}\t${Version}\t${Architecture}\t${db:Status-Abbrev}\n'],
  { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 },
);
for (const line of dpkg.split('\n')) {
  const [name, version, arch, status] = line.split('\t');
  // "ii" = installed. Anything else is a leftover configuration record.
  if (!name || !version || !status || !status.startsWith('ii')) continue;
  components.push({
    type: 'library',
    name,
    version,
    purl: `pkg:deb/debian/${encodeURIComponent(name)}@${encodeURIComponent(version)}?arch=${arch}`,
  });
}

// Global npm packages. `npm root -g` is where they live; walk it by hand so
// nested node_modules directories are included.
const npmRoot = execFileSync('npm', ['root', '-g'], { encoding: 'utf8' }).trim();
function walk(modulesDir) {
  let entries;
  try {
    entries = fs.readdirSync(modulesDir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    if (!entry.isDirectory() || entry.name.startsWith('.')) continue;
    const dir = path.join(modulesDir, entry.name);
    if (entry.name.startsWith('@')) {
      walk(dir); // a scope directory: packages are one level down
      continue;
    }
    try {
      const pkg = JSON.parse(fs.readFileSync(path.join(dir, 'package.json'), 'utf8'));
      if (pkg.name && pkg.version) {
        const purlName = pkg.name.startsWith('@')
          ? `%40${pkg.name.slice(1)}`
          : pkg.name;
        components.push({
          type: 'library',
          name: pkg.name,
          version: pkg.version,
          purl: `pkg:npm/${purlName}@${pkg.version}`,
          properties: [{ name: 'agent-sandbox:path', value: dir }],
        });
      }
    } catch {
      // A directory without a readable package.json is not a package.
    }
    walk(path.join(dir, 'node_modules'));
  }
}
walk(npmRoot);

const sbom = {
  bomFormat: 'CycloneDX',
  specVersion: '1.5',
  version: 1,
  metadata: {
    timestamp: new Date().toISOString(),
    component: { type: 'container', name: imageName, version: imageVersion },
    properties: [{ name: 'agent-sandbox:base-image', value: baseImage }],
  },
  components,
};
process.stdout.write(`${JSON.stringify(sbom, null, 2)}\n`);
NODE
