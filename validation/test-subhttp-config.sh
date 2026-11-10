#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./xrayebator
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
SUBHTTP_ENV_FILE="$work/xrayebator.env"
SUBHTTP_EXPECTED_UID=$(id -u)
_subhttp_load_config
[[ $SUBHTTP_HOST == 127.0.0.1 && $SUBHTTP_PORT == 8080 ]]
for port in 8080 8081; do
  printf 'SUBHTTP_HOST=127.0.0.1\nSUBHTTP_PORT=%s\n' "$port" > "$SUBHTTP_ENV_FILE"
  chmod 600 "$SUBHTTP_ENV_FILE"
  _subhttp_load_config
  [[ $SUBHTTP_LOCAL_BASE == "http://127.0.0.1:$port" ]]
done
for value in 0 65536 08081 '$(touch /tmp/subhttp-injection)' '8081;false' ''; do
  printf 'SUBHTTP_PORT=%s\n' "$value" > "$SUBHTTP_ENV_FILE"
  if _subhttp_load_config 2>/dev/null; then echo "accepted invalid port: $value"; exit 1; fi
done
printf 'SUBHTTP_HOST=0.0.0.0\n' > "$SUBHTTP_ENV_FILE"
! _subhttp_load_config 2>/dev/null
printf 'SUBHTTP_PORT=8081\n' > "$SUBHTTP_ENV_FILE"
chmod 666 "$SUBHTTP_ENV_FILE"
! _subhttp_load_config 2>/dev/null
chmod 600 "$SUBHTTP_ENV_FILE"
mv "$SUBHTTP_ENV_FILE" "$work/real"
ln -s "$work/real" "$SUBHTTP_ENV_FILE"
! _subhttp_load_config 2>/dev/null
rm "$SUBHTTP_ENV_FILE"
echo 'PASS: defaults, 8080/8081, invalid values, permissions, symlinks'
