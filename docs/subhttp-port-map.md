# Subscription HTTP handler port map

Scope: internal socat handler, independent from the public subscription HTTPS
listener (usually 8443). Inventory made before implementation with
`rg -n '8080|SUBHTTP|xrayebator-sub|subhttp'` across the repository.

| Location (function or component) | Original use | Resolution |
| --- | --- | --- |
| `xrayebator`, global `SUBHTTP_LOCAL_BASE` | monitor default only | computed by common data-only config parser |
| `_subscription_base_url`, `_subscription_is_local_only` | fallback 8080, port-based local detection | common endpoint; local detection uses host, not port |
| `install_subscription_server` | generated socat unit bound to 127.0.0.1:8080 | validated literal unit renderer; preserve existing unit until transactional apply |
| `_subscription_restart_service`, `_subscription_ensure_handler_running` | restart and hardcoded socket check | common apply transaction and HTTP 404 probe |
| `_subscription_local_self_test`, HAPP self-test diagnostics | curl and diagnostics at 8080 | configured loopback endpoint |
| `install_subscription_domain_tls`, `install_subscription_ip_tls` | nginx `proxy_pass` | configured loopback endpoint |
| `_dns01_nginx_vhost_pure` | DNS-01 nginx template | configured loopback endpoint |
| `install_subscription_local_only`, subscription menu | marker, tunnel hint and URL | configured endpoint; public TLS port untouched |
| `quickstart_command` | nginx template, fallback/error text and readiness | early conflict detection; configured upstream and readiness |
| `happ_setup_command` | service restart and profile URL | early preflight plus same transaction and canonical URL |
| `inspect_command` | indirect profile URL | canonical URL plus `subhttp_host`/`subhttp_port` fields |
| `_monitor_sub_local_base`, `monitor_check_command` | configurable monitor-only URL, fixed diagnostic text | common configuration and endpoint |
| `install.sh` | optional subscription setup; UFW default service list includes 8080 | initialize safe env via manager; firewall list retained for VPN compatibility, handler bind always loopback |
| `update.sh` | replaced manager, retained old unit | apply existing subscription configuration after manager update; stop update on failure |
| generated `subhttp.sh` | uses canonical base URL for HAPP routing | receives validated public endpoint values via unit Environment, without reading root-only file |
| Electron `src/main/core/deployer.ts`, `ipc-handlers.ts` | 8080 comments; executable SSH curl uses server-provided URL | no executable handler port hardcode; comments now generic |
| Electron `ServerSettings.tsx` | 8080 in VPN port presets | unrelated VPN port; retained |
| `gui-legacy` | consumes CLI subscription URL | no handler port hardcode found |
| `install.sh` UFW list, manager firewall and VPN port menu | 8080 as generic VPN service choice | unrelated to handler binding; retained |
| documentation and old tests | examples for default endpoint | defaults remain valid; new configuration and transaction coverage added |

## Implementation and validation plan

1. Reproduce the missing configuration behavior with failing tests.
2. Parse only unquoted `SUBHTTP_HOST=value`/`SUBHTTP_PORT=value`; reject code,
   invalid ports, duplicates, symlinks and unsafe ownership/mode. Default to
   127.0.0.1:8080 if the file is missing. Permit only numeric IPv4 loopback or ::1.
3. Render systemd and nginx from the same endpoint. Use literal socat arguments,
   not shell expansion in ExecStart. Keep root-only config out of xray's access.
4. Detect foreign listeners, including wildcard listeners. Reuse only this unit's
   MainPID, avoiding false conflict on repeated quickstart.
5. Lock port changes, back up unit/nginx, validate nginx, restart and probe actual
   HTTP, then reload nginx. Restore prior endpoint/unit/nginx on any failure.
6. Run configuration tests, real TCP/socat tests with isolated systemctl/nginx
   controls, the full shell validation suite and generated unit checks.

No VPS deployment, BeAdmin changes or external HTTPS port changes are part of this work.
