#!/bin/bash
set -euo pipefail

# Only run in remote (Claude Code on the web) environments
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# Install PowerShell 7 for parsing and linting .ps1 scripts
if ! command -v pwsh &>/dev/null; then
  echo "Installing PowerShell 7..."
  apt-get update -qq 2>/dev/null || true
  apt-get install -y -qq wget apt-transport-https software-properties-common >/dev/null 2>&1

  # Download and register Microsoft package repository (detect Ubuntu vs Debian)
  . /etc/os-release
  if [ "$ID" = "ubuntu" ]; then
    REPO_URL="https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb"
  else
    REPO_URL="https://packages.microsoft.com/config/debian/${VERSION_ID}/packages-microsoft-prod.deb"
  fi

  wget -q "$REPO_URL" -O /tmp/packages-microsoft-prod.deb
  dpkg -i /tmp/packages-microsoft-prod.deb >/dev/null 2>&1
  rm -f /tmp/packages-microsoft-prod.deb

  apt-get update -qq 2>/dev/null || true
  apt-get install -y -qq powershell >/dev/null 2>&1
  echo "PowerShell 7 installed: $(pwsh --version)"
else
  echo "PowerShell 7 already installed: $(pwsh --version)"
fi

echo "Session start hook completed successfully."
