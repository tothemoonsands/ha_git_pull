#!/usr/bin/env bash
set -euo pipefail

WORK_DIR="${1:-$(mktemp -d)}"
mkdir -p "$WORK_DIR"

echo "Using work dir: $WORK_DIR"

KEY_FILE="$WORK_DIR/original_ed25519"
ssh-keygen -q -t ed25519 -N "" -f "$KEY_FILE" <<< y >/dev/null 2>&1 || true

if [ ! -f "$KEY_FILE" ]; then
  echo "Failed to generate test key"
  exit 1
fi

write_current_style() {
  local raw="$1"
  local out="$2"
  : > "$out"
  while IFS= read -r line; do
    echo "$line" >> "$out"
  done <<< "$raw"
  chmod 600 "$out"
}

normalize_key() {
  local raw="$1"
  local cleaned
  local begin_marker
  local end_marker
  local body
  local compact_body
  local wrapped_body

  raw="${raw//$'\r'/}"
  cleaned="$(printf '%s' "$raw" | sed -E 's/(-----BEGIN [A-Z0-9 ]+ PRIVATE KEY-----)/\n\1\n/g; s/(-----END [A-Z0-9 ]+ PRIVATE KEY-----)/\n\1\n/g')"
  begin_marker="$(printf '%s\n' "$cleaned" | grep -m1 -E '^-----BEGIN [A-Z0-9 ]+ PRIVATE KEY-----$' || true)"
  end_marker="$(printf '%s\n' "$cleaned" | grep -m1 -E '^-----END [A-Z0-9 ]+ PRIVATE KEY-----$' || true)"
  if [ -z "$begin_marker" ] || [ -z "$end_marker" ]; then
    return 1
  fi

  body="$(printf '%s\n' "$cleaned" | awk '
    /^-----BEGIN [A-Z0-9 ]+ PRIVATE KEY-----$/ { in_body=1; next }
    /^-----END [A-Z0-9 ]+ PRIVATE KEY-----$/ { in_body=0; next }
    in_body { print }
  ')"
  compact_body="$(printf '%s' "$body" | tr -d ' \t\n')"
  [ -n "$compact_body" ] || return 1
  printf '%s' "$compact_body" | grep -Eq '^[A-Za-z0-9+/=]+$' || return 1
  wrapped_body="$(printf '%s' "$compact_body" | fold -w 70)"
  printf '%s\n%s\n%s\n' "$begin_marker" "$wrapped_body" "$end_marker"
}

write_fixed_style() {
  local raw="$1"
  local out="$2"
  if ! normalize_key "$raw" > "$out"; then
    return 1
  fi
  chmod 600 "$out"
}

validate_key() {
  local file="$1"
  if ssh-keygen -y -f "$file" >/dev/null 2>&1; then
    echo "valid"
  else
    echo "invalid"
  fi
}

show_case() {
  local name="$1"
  local raw="$2"
  local current_file="$WORK_DIR/${name}.current"
  local fixed_file="$WORK_DIR/${name}.fixed"

  write_current_style "$raw" "$current_file"
  current_status="$(validate_key "$current_file")"

  fixed_status="invalid"
  if write_fixed_style "$raw" "$fixed_file"; then
    fixed_status="$(validate_key "$fixed_file")"
  fi

  echo "Case ${name}: current=${current_status}, fixed=${fixed_status}"
}

RAW_KEY="$(cat "$KEY_FILE")"
FOLDED_KEY="$(tr '\n' ' ' < "$KEY_FILE")"
EMPTY_KEY=""

show_case "list_lines" "$RAW_KEY"
show_case "folded_scalar" "$FOLDED_KEY"
show_case "empty_key" "$EMPTY_KEY"

echo
echo "Known_hosts persistence simulation:"
RUNTIME_A="$WORK_DIR/runtime_a/.ssh"
RUNTIME_B="$WORK_DIR/runtime_b/.ssh"
PERSIST="$WORK_DIR/data/ssh"
mkdir -p "$RUNTIME_A" "$RUNTIME_B" "$PERSIST"
echo "github.com ssh-ed25519 TESTKEY" > "$RUNTIME_A/known_hosts"
cp "$RUNTIME_A/known_hosts" "$PERSIST/known_hosts"
rm -rf "$RUNTIME_A"
mkdir -p "$RUNTIME_B"
ln -sf "$PERSIST/known_hosts" "$RUNTIME_B/known_hosts"
if grep -q '^github.com ' "$RUNTIME_B/known_hosts"; then
  echo "Persistent known_hosts survives restart simulation: yes"
else
  echo "Persistent known_hosts survives restart simulation: no"
fi

echo
echo "Note: HTTPS PAT flow requires real remote credentials to fully validate."
