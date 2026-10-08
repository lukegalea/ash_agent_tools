#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 ash_agent_tools contributors <https://github.com/lukegalea/ash_agent_tools>
#
# SPDX-License-Identifier: MIT

# Trust the ai-sdlc platform CA inside the devenv image, without sudo.
#
# The Coder app-devcontainer template stages the platform CA bundle into the
# checkout as .sdlc-ca-bundle.crt (git-excluded). The usual install,
# `sudo update-ca-certificates`, cannot work here: Nix store paths cannot be
# setuid, and the image has no update-ca-certificates. The image instead
# keeps its trust bundle as a regular file that the container user owns
# ($SDLC_CA_BUNDLE, /etc/ssl/sdlc/ca-bundle.crt). The standard paths
# (/etc/ssl/certs/ca-certificates.crt, /etc/ssl/cert.pem) are symlinks to it,
# and SSL_CERT_FILE, NIX_SSL_CERT_FILE, CURL_CA_BUNDLE and GIT_SSL_CAINFO
# point at it. This script rewrites it as the Mozilla bundle plus the staged
# bundle.
#
# Outside a Coder workspace nothing is staged: the script waits 30 s, keeps
# the Mozilla bundle and exits 0.
set -euo pipefail

staged="${SDLC_CA_STAGED:-.sdlc-ca-bundle.crt}"
bundle="${SDLC_CA_BUNDLE:-/etc/ssl/sdlc/ca-bundle.crt}"
base="${SDLC_CA_BASE:-}"

# The template's stage script and the container build race; wait for it.
for _ in $(seq 1 "${SDLC_CA_WAIT:-15}"); do
  [ -f "$staged" ] && break
  sleep 2
done

if [ ! -f "$staged" ]; then
  echo "install-ca: no $staged staged; keeping the default trust bundle"
  exit 0
fi

if [ ! -w "$(dirname "$bundle")" ]; then
  echo "install-ca: $(dirname "$bundle") is not writable; is this the devenv image?" >&2
  exit 1
fi

tmp="$bundle.new"
{
  [ -n "$base" ] && [ -f "$base" ] && cat "$base"
  echo
  cat "$staged"
} > "$tmp"
mv -f "$tmp" "$bundle"

echo "install-ca: $bundle now holds $(grep -c 'BEGIN CERTIFICATE' "$bundle") certificates"
