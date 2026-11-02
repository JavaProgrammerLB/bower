#!/bin/bash
# Fails when a macOS 26 availability check escapes LiquidGlass.swift, or when
# project.yml and project.pbxproj disagree on the deployment target.
set -euo pipefail

cd "$(dirname "$0")/.."

leaks=$(grep -R -n -F 'available(macOS 26' Bower | grep -v 'Bower/Views/LiquidGlass.swift' || true)
if [[ -n $leaks ]]; then
  echo "available(macOS 26 appears outside Bower/Views/LiquidGlass.swift:" >&2
  echo "$leaks" >&2
  exit 1
fi

option=$(awk '
  /^options:/ { in_options = 1 }
  in_options && /^[^ ]/ && !/^options:/ { in_options = 0 }
  in_options && /^  deploymentTarget:/ { in_dt = 1; next }
  in_dt && /^  [^ ]/ { in_dt = 0 }
  in_dt && /^    macOS:/ {
    value = $2
    gsub(/"/, "", value)
    print value
    exit
  }
' project.yml)

setting=$(awk '
  /^settings:/ { in_settings = 1 }
  in_settings && /^[^ ]/ && !/^settings:/ { in_settings = 0 }
  in_settings && /^  base:/ { in_base = 1; next }
  in_base && /^  [^ ]/ { in_base = 0 }
  in_base && /^    MACOSX_DEPLOYMENT_TARGET:/ {
    value = $2
    gsub(/"/, "", value)
    print value
    exit
  }
' project.yml)

pbx=()
while IFS= read -r value; do
  pbx+=("$value")
done < <(sed -n 's/^[[:space:]]*MACOSX_DEPLOYMENT_TARGET = \(.*\);/\1/p' Bower.xcodeproj/project.pbxproj)

if [[ -z ${option:-} || -z ${setting:-} || ${#pbx[@]} -lt 2 ]]; then
  echo "Could not read both project.yml deployment targets and the two project.pbxproj assignments." >&2
  exit 1
fi

same=$option
if [[ $setting != "$same" ]]; then
  echo "project.yml deployment targets disagree: deploymentTarget.macOS=$option MACOSX_DEPLOYMENT_TARGET=$setting" >&2
  exit 1
fi
for value in "${pbx[@]}"; do
  if [[ $value != "$same" ]]; then
    echo "Deployment targets disagree: project.yml=$same project.pbxproj=${pbx[*]}" >&2
    exit 1
  fi
done
