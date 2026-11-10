#!/usr/bin/env bash
# Real TCP/socat + generated handler; systemd/nginx control is isolated in stubs.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./xrayebator
SOCAT_BIN=${SOCAT_BIN:-$(command -v socat || true)}
[[ -x "$SOCAT_BIN" ]] || { echo 'socat required (install socat or set SOCAT_BIN)' >&2; exit 1; }
work=$(mktemp -d)
cleanup() {
  if [[ -f "$work/pid" ]]; then kill "$(cat "$work/pid")" 2>/dev/null || true; fi
  [[ -z "${foreign:-}" ]] || kill "$foreign" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT
SUBHTTP_ENV_FILE="$work/xrayebator.env"
SUBHTTP_EXPECTED_UID=$(id -u)
SUBHTTP_UNIT_FILE="$work/xrayebator-sub.service"
NGINX_SITES_AVAILABLE="$work"
export SUBHTTP_ENV_FILE SUBHTTP_UNIT_FILE SOCAT_BIN
# Generate the actual handler without running privileged installation.
sed -n "/^  cat > \/usr\/local\/bin\/subhttp.sh << 'SUBHTTP_EOF'$/,/^SUBHTTP_EOF$/p" xrayebator | sed '1d;$d' > "$work/handler"
sed -i "s@/usr/local/bin/xrayebator@$PWD/xrayebator@g" "$work/handler"
chmod +x "$work/handler"
systemctl() {
  case "$1" in
    is-active) [[ -f "$work/pid" ]] && kill -0 "$(cat "$work/pid")" 2>/dev/null ;;
    show) if [[ -f "$work/pid" ]]; then cat "$work/pid"; else echo 0; fi ;;
    restart)
      if [[ -f "$work/pid" ]]; then kill "$(cat "$work/pid")" 2>/dev/null || true; fi
      local line args host port
      line=$(sed -n 's/^ExecStart=//p' "$SUBHTTP_UNIT_FILE")
      read -r -a args <<< "$line"
      host=$(sed -n 's/^Environment=SUBHTTP_HANDLER_HOST=//p' "$SUBHTTP_UNIT_FILE")
      port=$(sed -n 's/^Environment=SUBHTTP_HANDLER_PORT=//p' "$SUBHTTP_UNIT_FILE")
      [[ ! -f "$work/fail-start" || "$port" != 8081 ]] || return 1
      SUBHTTP_HANDLER_HOST="$host" SUBHTTP_HANDLER_PORT="$port" \
        "$SOCAT_BIN" "${args[1]}" "EXEC:$work/handler" 2>>"$work/socat.log" {subhttp_lock_fd}>&- &
      echo $! > "$work/pid"
      echo restart >> "$work/actions"
      sleep 0.15 ;;
    stop) if [[ -f "$work/pid" ]]; then kill "$(cat "$work/pid")" 2>/dev/null || true; rm "$work/pid"; fi ;;
    reload) [[ ! -f "$work/fail-reload" ]] || { rm "$work/fail-reload"; return 1; } ;;
    *) return 0 ;;
  esac
}
nginx() {
  [[ ! -f "$work/fail-nginx" ]] || ! grep -q ':8081;' "$work/xrayebator-sub"
}
_subhttp_load_config
_subhttp_render_unit | sed 's/TCP4-LISTEN/TCP-LISTEN/' > "$SUBHTTP_UNIT_FILE"
cat > "$work/xrayebator-sub" <<'SITE'
server { listen 8443 ssl; location / { proxy_pass http://127.0.0.1:8080; } }
SITE
_subhttp_apply
[[ $(_subscription_base_url) == http://127.0.0.1:8080 ]]
subhttp_config_command --port 8081
[[ $(_subscription_base_url) == http://127.0.0.1:8081 ]]
grep -q 'listen 8443 ssl' "$work/xrayebator-sub"
grep -q 'proxy_pass http://127.0.0.1:8081;' "$work/xrayebator-sub"
grep -q 'TCP4-LISTEN:8081,reuseaddr,fork,bind=127.0.0.1' "$SUBHTTP_UNIT_FILE"
# Repeat quickstart's actual ensure path: keep healthy handler, no restart.
_happ_sub_token_for_self_test() { :; }
# ensure helper uses production installed marker; exercise its transaction/probe path directly.
before=$(wc -l < "$work/actions")
_subhttp_apply; _subhttp_apply
[[ $(wc -l < "$work/actions") == "$before" ]]
subhttp_config_command --port 8080
for failure in fail-nginx fail-start fail-reload; do
  touch "$work/$failure"
  if subhttp_config_command --port 8081; then echo "accepted $failure"; exit 1; fi
  _subhttp_load_config
  [[ $SUBHTTP_PORT == 8080 ]]
  grep -q 'proxy_pass http://127.0.0.1:8080;' "$work/xrayebator-sub"
  grep -q 'TCP4-LISTEN:8080,' "$SUBHTTP_UNIT_FILE"
  _subhttp_probe
  rm -f "$work/$failure"
done
# Conflict: foreign listener must survive; quickstart fails before migrations/install.
"$SOCAT_BIN" TCP4-LISTEN:8081,reuseaddr,bind=127.0.0.1 - >/dev/null 2>&1 & foreign=$!
sleep 0.15
! subhttp_config_command --port 8081
kill -0 "$foreign"
# Manual edit + apply also rolls config back to the actual installed endpoint.
printf 'SUBHTTP_PORT=8081\n' > "$SUBHTTP_ENV_FILE"
! _subhttp_apply
_subhttp_load_config; [[ $SUBHTTP_PORT == 8080 ]]
printf 'SUBHTTP_PORT=8081\n' > "$SUBHTTP_ENV_FILE"
! quickstart_command --without-email
kill -0 "$foreign"
printf 'SUBHTTP_PORT=8080\n' > "$SUBHTTP_ENV_FILE"
_subhttp_load_config
_subhttp_probe
# Semantic unit check: no shell syntax, no optional EnvironmentFile defaults.
! grep -q 'EnvironmentFile\|\${\|\$SUBHTTP' "$SUBHTTP_UNIT_FILE"
kill "$foreign"; wait "$foreign" 2>/dev/null || true; foreign=""
# update path preserves an intentionally stopped service and never enables it.
systemctl stop xrayebator-sub.service
SUBHTTP_PRESERVE_STATE=1 _subhttp_apply
! systemctl is-active --quiet xrayebator-sub.service
# Non-default host and IPv6 are passed to xray's handler through Environment.
for host in 127.0.0.2 ::1; do
  printf 'SUBHTTP_HOST=%s\nSUBHTTP_PORT=8081\n' "$host" > "$SUBHTTP_ENV_FILE"
  _subhttp_apply
  _subhttp_load_config
  _subhttp_probe
done
# local bearer-token requests must never traverse configured HTTP proxies.
grep -Fq '_curl_secret_url "${SUBHTTP_LOCAL_BASE}/sub/${token}" --noproxy' xrayebator
grep -Fq '_curl_secret_url "$(_monitor_sub_local_base)/sub/${token}" --noproxy' xrayebator
echo 'PASS: real socat 8080/8081, generated handler, repeat apply, conflict/quickstart, nginx/start/reload rollback'
