#!/usr/bin/env bash
set -Eeuo pipefail

MODEL_DIR="${MODEL_DIR:-/workspace/models}"
MODEL_MANIFEST="${MODEL_MANIFEST:-/opt/h3/config/models.tsv}"
MODEL_RESERVE_BYTES="${MODEL_RESERVE_BYTES:-10000000000}"
MODEL_DOWNLOAD_CONCURRENCY="${MODEL_DOWNLOAD_CONCURRENCY:-4}"
VERIFY_DIR="${MODEL_VERIFY_DIR:-$MODEL_DIR/.verified}"

[[ -r "$MODEL_MANIFEST" ]] || { echo "ERROR: unreadable model manifest: $MODEL_MANIFEST" >&2; exit 20; }
[[ "$MODEL_DOWNLOAD_CONCURRENCY" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: invalid MODEL_DOWNLOAD_CONCURRENCY" >&2; exit 64; }
mkdir -p "$MODEL_DIR" "$VERIFY_DIR"

marker_path() {
  local relative_path="$1"
  printf '%s/%s.ok\n' "$VERIFY_DIR" "${relative_path//\//__}"
}

verify_fast() {
  local path="$1" expected_size="$2" expected_sha="$3" marker mtime
  [[ -f "$path" ]] || return 1
  [[ "$(stat -c '%s' "$path")" == "$expected_size" ]] || return 1
  marker="$(marker_path "${path#"$MODEL_DIR"/}")"
  [[ -r "$marker" ]] || return 1
  mtime="$(stat -c '%Y' "$path")"
  [[ "$(<"$marker")" == "$expected_sha $expected_size $mtime" ]]
}

verify_full() {
  local path="$1" expected_size="$2" expected_sha="$3" marker mtime
  [[ -f "$path" ]] || return 1
  [[ "$(stat -c '%s' "$path")" == "$expected_size" ]] || return 1
  printf '%s  %s\n' "$expected_sha" "$path" | sha256sum --check --status || return 1
  marker="$(marker_path "${path#"$MODEL_DIR"/}")"
  mtime="$(stat -c '%Y' "$path")"
  printf '%s %s %s\n' "$expected_sha" "$expected_size" "$mtime" > "$marker"
}

download_one() {
  local relative_path="$1" expected_size="$2" expected_sha="$3" url="$4"
  local target="$MODEL_DIR/$relative_path" part="$MODEL_DIR/$relative_path.part"
  local attempt rc actual_size
  mkdir -p "$(dirname "$target")"
  if verify_fast "$target" "$expected_size" "$expected_sha"; then
    echo "[models] ready: $relative_path"
    return 0
  fi
  if verify_full "$target" "$expected_size" "$expected_sha"; then
    echo "[models] verified existing: $relative_path"
    return 0
  fi
  rm -f -- "$(marker_path "$relative_path")"
  [[ ! -e "$target" ]] || rm -f -- "$target"
  if [[ -f "$part" && "$(stat -c '%s' "$part")" -gt "$expected_size" ]]; then rm -f -- "$part"; fi

  for attempt in 1 2 3 4 5; do
    echo "[models] downloading $relative_path (attempt $attempt/5)"
    set +e
    curl --fail --location --retry 8 --retry-all-errors --retry-delay 5 \
      --connect-timeout 30 --speed-limit 1024 --speed-time 180 \
      --continue-at - --output "$part" --silent --show-error "$url"
    rc=$?
    set -e
    if (( rc == 33 )); then rm -f -- "$part"; continue; fi
    if (( rc != 0 )); then echo "[models] curl failed ($rc); keeping partial file" >&2; sleep 5; continue; fi
    actual_size="$(stat -c '%s' "$part")"
    if [[ "$actual_size" != "$expected_size" ]]; then
      echo "[models] size mismatch for $relative_path: $actual_size" >&2
      (( actual_size > expected_size )) && rm -f -- "$part"
      sleep 5
      continue
    fi
    if printf '%s  %s\n' "$expected_sha" "$part" | sha256sum --check --status; then
      mv -f -- "$part" "$target"
      verify_full "$target" "$expected_size" "$expected_sha"
      echo "[models] verified: $relative_path"
      return 0
    fi
    echo "[models] SHA-256 mismatch for $relative_path" >&2
    rm -f -- "$part"
  done
  echo "ERROR: failed to obtain $relative_path" >&2
  return 1
}

if [[ "${1:-}" == "--one" ]]; then shift; download_one "$@"; exit; fi

missing_bytes=0
while IFS=$'\t' read -r relative_path expected_size expected_sha url; do
  [[ -z "${relative_path:-}" || "$relative_path" == \#* ]] && continue
  if ! verify_fast "$MODEL_DIR/$relative_path" "$expected_size" "$expected_sha"; then
    missing_bytes=$((missing_bytes + expected_size))
  fi
done < "$MODEL_MANIFEST"

free_bytes="$(df -PB1 "$MODEL_DIR" | awk 'NR == 2 { print $4 }')"
required_bytes=$((missing_bytes + MODEL_RESERVE_BYTES))
echo "[models] missing payload: $missing_bytes bytes; free: $free_bytes bytes"
(( free_bytes >= required_bytes )) || { echo "ERROR: need $required_bytes bytes free; found $free_bytes" >&2; exit 21; }

job_count=0
pids=()
failed=0
while IFS=$'\t' read -r relative_path expected_size expected_sha url; do
  [[ -z "${relative_path:-}" || "$relative_path" == \#* ]] && continue
  job_count=$((job_count + 1))
  if (( ${#pids[@]} >= MODEL_DOWNLOAD_CONCURRENCY )); then
    if ! wait "${pids[0]}"; then failed=1; fi
    pids=("${pids[@]:1}")
  fi
  "$0" --one "$relative_path" "$expected_size" "$expected_sha" "$url" \
    > >(sed -u "s|^|[$job_count] |") 2> >(sed -u "s|^|[$job_count] |" >&2) &
  pids+=("$!")
done < "$MODEL_MANIFEST"
for pid in "${pids[@]}"; do if ! wait "$pid"; then failed=1; fi; done
(( failed == 0 )) || { echo "ERROR: at least one model download failed" >&2; exit 22; }
echo "[models] all selected models are ready"
