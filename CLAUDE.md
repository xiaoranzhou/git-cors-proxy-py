# cors-proxy-py

Python port of [@isomorphic-git/cors-proxy](https://github.com/isomorphic-git/cors-proxy) using aiohttp.
Enables browser git operations (clone/push/fetch) by proxying HTTP git requests with CORS headers.

## Running

```bash
# Direct (dev)
pip3 install -e .
python3 -m cors_proxy.cli start -p 8333

# Docker (preferred)
docker build -t cors-proxy-py .
docker run -d --name cors-proxy-py -p 8333:9999 cors-proxy-py
```

Environment variables: `PORT` (default 9999), `ALLOW_ORIGIN` (default `*`), `INSECURE_HTTP_ORIGINS` (comma-separated domains to reach via HTTP).

## Architecture

- `server.py` — aiohttp app, root handler, startup/shutdown
- `middleware.py` — CORS headers, git request filtering, proxy logic, streaming
- `allow_request.py` — git request detection (upload-pack / receive-pack / info/refs)
- `cli.py` — start/stop commands with PID file daemonization
- `config.py` — env var helpers

Key design: `proxy_middleware` intercepts all requests, calls `allow()` to filter non-git traffic, handles OPTIONS preflight inline, then calls `proxy_handler` for GET/POST. CORS headers must be set on the `StreamResponse` **before** `await response.prepare(request)` — after prepare() headers are sent and immutable.

## Known Bugs Fixed

- **CORS headers missing on proxy responses**: Original code never set CORS headers on `StreamResponse` before `prepare()`. Fixed in `middleware.py:212-217`.
- **Auth header mangling**: Spurious base64 re-encoding of Basic auth credentials removed (was not in original Node.js version and corrupted valid personal access tokens).
- **URL comparison**: `proxy_response.url` (URL object) vs `target_url` (str) now uses `str()` cast.

## Improvements applied (2026-04-09)

- **Query string injection** fixed: `urlencode(query)` instead of raw string join (`middleware.py`)
- **Header injection** fixed: `\r\n` stripped from `location` and `x-redirected-url` before setting on response (`middleware.py`)
- **Response size limit** added: streams are capped at `MAX_RESPONSE_SIZE` bytes (default 512 MB) (`middleware.py`, `config.py`)
- **Port validation** added: `PORT` env var is checked for integer type and 1–65535 range with clear error (`config.py`)
- **Dependency upper bounds** added: `aiohttp<4`, `psutil<7`, `python-daemon<4` (`pyproject.toml`)
- **Non-root container**: Dockerfile now creates `corsproxy` user and runs as that user

## Security Audit (2026-04-09)

### CRITICAL

**SSRF — no internal network protection** (`middleware.py:162-186`)
The domain from the request path is used directly to build the target URL with no blocklist. Requests to `127.0.0.1`, `192.168.x.x`, `10.x.x.x`, `169.254.169.254` (AWS metadata), `kubernetes.default.svc.cluster.local`, etc. are proxied without restriction.
→ *Not fixed. In a private deployment behind a firewall this is acceptable; for public exposure add an IP/domain blocklist.*

### HIGH

**Domain spoofing / path traversal** (`middleware.py:79-89, 162`)
`parse_path()` only rejects `/` in the domain segment. Inputs like `/evil.com:8080@google.com/`, `/127.0.0.1/`, `/[::1]/` are accepted. Port numbers in domain are passed through.
→ *Not fixed. Validate domain with a strict regex (hostname only, optional port in 1–65535).*

**Query string injection** (`middleware.py:166-169`)
Query params are concatenated raw (`f"{k}={v}"`) without URL encoding. Arbitrary query params or fragment injection possible.
→ *Not fixed. Use `urllib.parse.urlencode(query)` instead.*

**Header injection / HTTP response splitting** (`middleware.py:190-210`)
`location` and `x-redirected-url` headers are taken from upstream response without stripping `\r\n`. A malicious upstream could inject arbitrary response headers.
→ *Not fixed. Strip `\r\n` from all values before setting response headers.*

**Credentials logged** (`middleware.py:171`)
Full target URL is printed. Git URLs with embedded credentials (`https://user:token@host/`) would be logged in plaintext.
→ *Low risk for this deployment (PATs passed via Authorization header, not URL) but worth noting.*

### MEDIUM

**No request/response size limits** (`middleware.py:174-176, 230-238`)
`request.content` is streamed without a size cap. Responses are streamed chunk by chunk with no total-size limit. Enables memory exhaustion / DoS.
→ *Not fixed.*

**No rate limiting**
No per-IP request limits or concurrency caps. Trivial DoS via request flood.
→ *Not fixed. Consider adding aiohttp-ratelimiter or an upstream proxy (nginx/caddy) for rate limiting.*

**CORS wildcard** (`middleware.py:213`, `server.py:19`)
Default `ALLOW_ORIGIN=*` allows any website to initiate git requests through this proxy. Intentional by design but increases exposure surface.
→ *Set `ALLOW_ORIGIN` to the specific elab2arc origin in production.*

**Daemon umask=0 and CWD change** (`cli.py:45-46`)
Double-fork daemonization sets `umask(0)` (world-writable files) and `chdir("/")`. PID file stored in CWD which may differ after chdir. Use `python-daemon` (already a dependency) instead of manual fork.
→ *Not fixed. Not relevant when running via Docker (preferred).*

**Container runs as root** (`Dockerfile`)
No `USER` directive; process runs as root inside container. No capability dropping.
→ *Add `RUN useradd -r proxy && USER proxy` to Dockerfile.*

**Dependency versions unpinned** (`pyproject.toml`)
`aiohttp>=3.9.0` has no upper bound. Future breaking or vulnerable versions will be installed automatically.
→ *Pin to known-good versions or use a lockfile.*

### LOW

**Port env var not validated** (`config.py:14-16`)
`int(os.environ.get("PORT", "9999"))` crashes on non-integer values; no range check (1–65535).

**Exception details re-raised uncaught** (`middleware.py:247-252`)
aiohttp network/SSL errors are printed and re-raised, potentially leaking internal target server details in error responses.

**Open redirect via location header**
When upstream returns a 3xx, the rewritten `location` is forwarded to the client. A malicious upstream can redirect to arbitrary URLs.

## What NOT to change

- Do not re-add the auth header base64 re-encoding logic (lines 155-166 in original commit) — it was incorrect and broke GitLab PAT authentication.
- Do not call `cors-proxy start` in Docker CMD — the daemon double-fork exits the foreground process and kills the container. Use `python3 -m cors_proxy.server` instead.
- Do not set CORS headers after `response.prepare()` — they will be silently dropped.
