#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./xrayebator
nginx_bin=${NGINX_BIN:-$(command -v nginx || true)}
[[ -x "$nginx_bin" ]] || { echo 'SKIP: nginx binary unavailable'; exit 0; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
SUBHTTP_ENV_FILE="$work/config.env"
SUBHTTP_EXPECTED_UID=$(id -u)
mkdir -p "$work/certs"
openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=subscription.example \
  -keyout "$work/certs/privkey.pem" -out "$work/certs/fullchain.pem" -days 1 >/dev/null 2>&1
cat > "$work/nginx.conf" <<CONF
pid $work/nginx.pid;
error_log $work/error.log;
events {}
http {
 access_log off;
 client_body_temp_path $work/body;
 proxy_temp_path $work/proxy;
 fastcgi_temp_path $work/fastcgi;
 uwsgi_temp_path $work/uwsgi;
 scgi_temp_path $work/scgi;
 include $work/vhost.conf;
}
CONF
for host in 127.0.0.1 ::1; do
  for port in 8080 8081; do
    printf 'SUBHTTP_HOST=%s\nSUBHTTP_PORT=%s\n' "$host" "$port" > "$SUBHTTP_ENV_FILE"
    chmod 600 "$SUBHTTP_ENV_FILE"
    _dns01_nginx_vhost_pure subscription.example 8443 "$work/certs" > "$work/vhost.conf"
    _subhttp_load_config
    grep -Fq "proxy_pass $SUBHTTP_LOCAL_BASE;" "$work/vhost.conf"
    grep -Fq 'listen 8443 ssl http2;' "$work/vhost.conf"
    "$nginx_bin" -t -p "$work" -c "$work/nginx.conf" > "$work/check.log" 2>&1 || { cat "$work/check.log"; exit 1; }
  done
done
echo 'PASS: nginx -t for IPv4/IPv6 on 8080/8081, HTTPS remains 8443'
