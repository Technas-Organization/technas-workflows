#!/usr/bin/env bash
# Verifies that every native .so packaged inside an Android App Bundle is
# aligned for 16 KB memory pages. Required by Google Play since Android 15
# and enforced for new uploads as a hard rejection (Play Console error:
# "Votre appli ne prend pas en charge les tailles de page de mémoire de 16 ko").
#
# Single source of truth — hosted in Technas-Organization/technas-workflows and
# invoked by the reusable deploy-flutter-android.yml workflow from the
# technas-workflows checkout. Apps do NOT vendor their own copy.
#
# Usage: check_aab_16kb_alignment.sh path/to/app-release.aab
#
# Exit codes:
#   0  every .so has LOAD alignment >= 0x4000 (16 KB) — safe to upload
#   1  at least one .so is misaligned — Play Console will reject the upload
#   2  bad usage / tooling missing
#
# Why this script exists
# ----------------------
# A pre-built .so coming from a Maven AAR (Jitsi React-Native bundle, etc.)
# can ship 4 KB-aligned ELF segments that no `cppFlags`/`ldflags` build
# tweak can fix on our side — the only path is to bump the offending
# dependency to a version that ships 16 KB-aligned binaries. Without this
# CI guard the regression is invisible until an artifact reaches the Play
# Console hours after the build is "green".
#
# Caught in production 2026-05-12 (BeautyGo client v51) on jitsi_meet_sdk
# 10.3.0 → fixed by bumping to 11.6.0. See:
#   .cursor/rules/android-aab-16kb-alignment.mdc
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 path/to/app-release.aab" >&2
  exit 2
fi

AAB="$1"
if [[ ! -f "$AAB" ]]; then
  echo "::error::AAB not found: $AAB" >&2
  exit 2
fi

for tool in unzip readelf; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "::error::missing required tool: $tool (install binutils + unzip)" >&2
    exit 2
  fi
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Extract every native .so from the bundle. We only care about the 64-bit
# ABIs (arm64-v8a, x86_64) — Play Store rejects the upload if any 64-bit
# .so is misaligned. 32-bit ABIs are not subject to the 16 KB rule.
( cd "$TMP" && unzip -q "$AAB" 'base/lib/arm64-v8a/*.so' 'base/lib/x86_64/*.so' 2>/dev/null ) || true

mapfile -t SO_FILES < <(find "$TMP" -type f -name '*.so' | sort)

if [[ ${#SO_FILES[@]} -eq 0 ]]; then
  echo "::warning::no 64-bit .so found inside $AAB — nothing to check"
  exit 0
fi

fail=0
checked=0
for so in "${SO_FILES[@]}"; do
  rel="${so#"$TMP/"}"
  # Take the alignment of the first PT_LOAD segment. ELF format guarantees
  # all LOAD segments share the same alignment, so the first one is
  # representative.
  align="$(readelf -lW "$so" 2>/dev/null \
            | awk '$1=="LOAD"{print $NF; exit}')"
  if [[ -z "$align" ]]; then
    echo "::warning::$rel — no LOAD segment found, skipping"
    continue
  fi
  checked=$((checked + 1))
  # 0x4000 = 16384 = 16 KB. 0x10000 = 64 KB also acceptable.
  case "$align" in
    0x4000|0x10000)
      ;;
    *)
      echo "::error::$rel has LOAD alignment $align (need >= 0x4000 / 16 KB)"
      fail=1
      ;;
  esac
done

if [[ $fail -ne 0 ]]; then
  echo ""
  echo "::error title=AAB 16 KB alignment guard tripped::At least one native .so inside $AAB is not 16 KB-aligned. Google Play would reject this upload."
  echo "Fix: identify the offending Maven AAR (usually Jitsi/React-Native bundles)"
  echo "     and bump it to a version whose .so ship 16 KB-aligned LOAD segments."
  echo "See .cursor/rules/android-aab-16kb-alignment.mdc for the playbook."
  exit 1
fi

echo "16 KB alignment OK: $checked native .so checked, all LOAD segments >= 0x4000."
