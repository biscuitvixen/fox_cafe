#!/usr/bin/env bash
# Edge security smoke test. Black-box: fetches the live site and asserts the
# security posture that config-linting cannot see - CSP actually emitted and
# strict, security headers present, gated hosts not publicly served, asset
# host CORS scoped and isolated. `caddy validate` passed while the CSP was
# silently broken; this is the check that catches that class of regression.
#
# Exits non-zero if any assertion fails. If SECURITY_PUSH_URL is set (see
# README.md) it reports up/down to an Uptime Kuma push monitor, mirroring
# backup/backup.sh. Kuma must be the loopback URL (127.0.0.1:3001); the public
# kuma.bluefox.cafe 302s to auth and curl would read that as success.
#
# Usage: security-check.sh [domain]        (default: bluefox.cafe)
set -u

DOMAIN="${1:-bluefox.cafe}"
FAILS=0
FIRST_FAIL=""

pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILS=$((FAILS + 1)); [ -z "$FIRST_FAIL" ] && FIRST_FAIL="$1"; return 0; }
assert() { if [ "$1" -eq 0 ]; then pass "$2"; else fail "$2"; fi; }

# -m: hard timeout. No -L: we assert on the redirect itself, never follow it.
hdrs() { curl -fsS -m 15 -D - -o /dev/null "$@" 2>/dev/null; }
code() { curl -sS  -m 15 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null; }

report() {
    [ -n "${SECURITY_PUSH_URL:-}" ] || return 0
    if [ "$FAILS" -eq 0 ]; then
        curl -fsS -m 10 -o /dev/null "${SECURITY_PUSH_URL}?status=up&msg=OK" 2>/dev/null || true
    else
        msg=$(printf '%s' "${FIRST_FAIL} (+$((FAILS - 1)) more)" | sed 's/ /%20/g')
        curl -fsS -m 10 -o /dev/null "${SECURITY_PUSH_URL}?status=down&msg=${msg}" 2>/dev/null || true
    fi
}
trap report EXIT

echo "== Security check: $DOMAIN =="

# --- Apex: reachable + strict CSP actually emitted ---
[ "$(code "https://$DOMAIN/")" = 200 ]; assert $? "apex 200"
APEX=$(hdrs "https://$DOMAIN/")
csp=$(printf '%s\n' "$APEX" | grep -i '^content-security-policy:')
[ -n "$csp" ]; assert $? "apex sends Content-Security-Policy"
printf '%s' "$csp" | grep -q "default-src 'self'"; assert $? "CSP: default-src 'self'"
printf '%s' "$csp" | grep -qi 'unsafe-inline' && fail "CSP: no unsafe-inline" || pass "CSP: no unsafe-inline"
printf '%s' "$csp" | grep -q "script-src[^;]*'sha256-"; assert $? "CSP: script-src pins a sha256 hash"
printf '%s' "$csp" | grep -q "https://assets.$DOMAIN"; assert $? "CSP: allows the asset host"

# --- Apex: other security headers ---
printf '%s\n' "$APEX" | grep -qi '^strict-transport-security:';   assert $? "apex HSTS"
printf '%s\n' "$APEX" | grep -qi '^x-content-type-options: *nosniff'; assert $? "apex nosniff"
printf '%s\n' "$APEX" | grep -qi '^x-frame-options: *DENY';       assert $? "apex X-Frame-Options DENY"

# --- Auth gating: gated hosts must never serve 200 unauthenticated ---
for sub in dnd demiplane beastworld files kuma logs; do
    c=$(code "https://$sub.$DOMAIN/")
    [ "$c" = 302 ]; assert $? "$sub gated (302, got $c)"
done
# status: bare / is 404 by design; a status slug path is the gated one.
c=$(code "https://status.$DOMAIN/status/foundry"); [ "$c" = 302 ]; assert $? "status slug gated (302, got $c)"
# public portal
[ "$(code "https://auth.$DOMAIN/")" = 200 ]; assert $? "auth portal public (200)"

# --- Asset host: reachable, framed-denied, CORS scoped, isolated ---
FONT="https://assets.$DOMAIN/fonts/fa-solid-900.woff2"
[ "$(code "$FONT")" = 200 ]; assert $? "asset host serves fonts (200)"
hdrs "$FONT" | grep -qi '^x-frame-options: *DENY'; assert $? "asset host X-Frame-Options DENY"
curl -fsS -m 15 -o /dev/null -D - -H "Origin: https://dnd.$DOMAIN" "$FONT" 2>/dev/null \
    | grep -qi "^access-control-allow-origin: *https://dnd.$DOMAIN"; assert $? "asset CORS reflects own subdomain"
curl -fsS -m 15 -o /dev/null -D - -H "Origin: https://evil.example" "$FONT" 2>/dev/null \
    | grep -qi '^access-control-allow-origin:' && fail "asset CORS denies foreign origin" || pass "asset CORS denies foreign origin"
# Sibling gated trees live outside the asset vhost root and must be unreachable.
c=$(code "https://assets.$DOMAIN/dnd/"); [ "$c" != 200 ]; assert $? "asset host does not serve gated trees (/dnd -> $c)"

echo "== $((FAILS)) failed =="
[ "$FAILS" -eq 0 ]
