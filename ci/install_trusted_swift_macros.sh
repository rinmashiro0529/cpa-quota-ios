#!/usr/bin/env bash
set -euo pipefail

# Install only the reviewed target / revision pairs on the ephemeral runner.
# Never replace a pre-existing trust store with different contents.
security_dir="$HOME/Library/org.swift.swiftpm/security"
trust_file="$security_dir/macros.json"
mkdir -p "$security_dir"
if [[ -e "$trust_file" || -L "$trust_file" ]]; then
  if ! cmp -s ci/trusted-swift-macros.json "$trust_file"; then
    printf '%s\n' 'Existing Swift macro trust store does not match the reviewed allowlist.' >&2
    exit 1
  fi
else
  (umask 077; set -C; cat ci/trusted-swift-macros.json > "$trust_file")
fi
