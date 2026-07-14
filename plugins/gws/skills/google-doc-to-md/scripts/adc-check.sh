#!/usr/bin/env bash
# Fast ADC (gcloud Application Default Credentials) preflight check.
# Exit 0 if ADC creds are present and usable, exit 1 with an actionable
# message (pointing at references/adc-setup.md) otherwise.
#
# Usage: adc-check.sh
# Silent on success (exit 0). Prints a one-line reason to stderr on failure.
set -euo pipefail

if ! command -v gcloud >/dev/null 2>&1; then
  echo "ADC not available: gcloud CLI not found. See references/adc-setup.md to set up ADC, or skip to the connector rung." >&2
  exit 1
fi

if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
  echo "ADC not available: no Application Default Credentials configured (or they're expired/missing scopes). See references/adc-setup.md to set up ADC, or skip to the connector rung." >&2
  exit 1
fi

exit 0
