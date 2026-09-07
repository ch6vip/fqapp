#!/usr/bin/env bash
# A compiler fixture. It never invokes a compiler or accesses real app outputs.
set -euo pipefail
if [ "$1" = env ]; then
  case "$2" in
    GOHOSTOS) printf '%s\n' "$FQAPP_FAKE_HOST_OS" ;;
    GOHOSTARCH) printf '%s\n' "$FQAPP_FAKE_HOST_ARCH" ;;
    *) exit 2 ;;
  esac
  exit 0
fi
if [ "$1" != build ]; then exit 2; fi
kind=standalone
output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -buildmode=c-shared) kind=jni ;;
    -o) shift; output="$1" ;;
  esac
  shift
done
if command -v cygpath >/dev/null 2>&1; then output="$(cygpath -u "$output")"; fi
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$GOOS" "$GOARCH" "$CGO_ENABLED" "${CC:-}" "${CGO_CFLAGS:-}" >> "$FQAPP_FAKE_LOG"
if [ "${FQAPP_FAKE_FAILURE:-}" = "${kind}_empty" ]; then exit 0; fi
printf 'built %s' "$kind" > "$output"
if [ "$kind" = jni ]; then printf 'generated header' > "${output%.so}.h"; fi
if [ "${FQAPP_FAKE_FAILURE:-}" = "${kind}_fail" ]; then exit 9; fi
