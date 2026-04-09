# cors-proxy-py

> **Disclaimer:** This software is provided for **local development and testing purposes only**.
> It is offered as-is, with **no warranty of any kind** — express or implied — including but not limited to
> correctness, security, fitness for a particular purpose, or suitability for production use.
> Do not expose this proxy to the public internet without additional hardening (authentication,
> rate limiting, domain allowlisting, TLS termination). Use at your own risk.

A Python (aiohttp) port of [@isomorphic-git/cors-proxy](https://github.com/isomorphic-git/cors-proxy).

Enables browser-based git operations (clone, fetch, push) by acting as an HTTP proxy that adds the correct CORS headers to git protocol traffic. Designed to work with [isomorphic-git](https://isomorphic-git.org) running inside a browser.

---

## Why this exists

Browsers enforce the [Same-Origin Policy](https://developer.mozilla.org/en-US/docs/Web/Security/Same-origin_policy). When isomorphic-git tries to talk to a remote git server (e.g. a private GitLab instance), the browser blocks the request unless the server sends `Access-Control-Allow-Origin` headers — which most git servers do not.

This proxy sits between the browser and the git server. It:
1. Receives the git HTTP request from the browser
2. Forwards it to the real git server (including `Authorization` headers)
3. Streams the response back with the correct CORS headers added

---

## Quick start

### Docker (recommended)

```bash
docker build -t cors-proxy-py .
docker run -d --name cors-proxy -p 8333:9999 cors-proxy-py
```

The proxy is now available at `http://localhost:8333`.

### Local (Python 3.9+)

```bash
pip install -e .
cors-proxy start -p 8333
# or directly:
python3 -m cors_proxy.server
```

---

## Configuration

All configuration is via environment variables.

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `9999` | Port the server listens on |
| `ALLOW_ORIGIN` | `*` | Value for `Access-Control-Allow-Origin`. Set to your app's origin in production (e.g. `https://your-app.example.com`) |
| `INSECURE_HTTP_ORIGINS` | _(empty)_ | Comma-separated list of domains to reach over plain HTTP instead of HTTPS (e.g. `mygitlab.internal,dev.local`) |
| `MAX_RESPONSE_SIZE` | `536870912` (512 MB) | Maximum response body size in bytes. Requests exceeding this are aborted mid-stream |

### Docker with custom config

```bash
docker run -d --name cors-proxy \
  -p 8333:9999 \
  -e ALLOW_ORIGIN="https://your-app.example.com" \
  -e MAX_RESPONSE_SIZE=1073741824 \
  cors-proxy-py
```

### docker-compose

```yaml
services:
  cors-proxy:
    image: cors-proxy-py
    build: ./cors-proxy-py
    ports:
      - "8333:9999"
    environment:
      ALLOW_ORIGIN: "https://your-app.example.com"
    restart: unless-stopped
```

---

## Using with isomorphic-git and GitLab

Configure isomorphic-git to route git traffic through the proxy using its `http` plugin.

### Clone from a private GitLab instance

```javascript
import git from 'isomorphic-git'
import http from 'isomorphic-git/http/web'

await git.clone({
  fs,
  http,
  dir: '/repo',
  corsProxy: 'http://localhost:8333',
  url: 'https://your-gitlab.example.com/group/repo.git',
  onAuth: () => ({
    username: 'YOUR_USERNAME',
    password: 'YOUR_PERSONAL_ACCESS_TOKEN',
  }),
})
```

### Push to a private GitLab instance

```javascript
await git.push({
  fs,
  http,
  dir: '/repo',
  corsProxy: 'http://localhost:8333',
  remote: 'origin',
  onAuth: () => ({
    username: 'YOUR_USERNAME',
    password: 'YOUR_PERSONAL_ACCESS_TOKEN',
  }),
})
```

The `corsProxy` URL is prepended to every git request. A request to `https://your-gitlab.example.com/group/repo.git/info/refs` becomes:

```
GET http://localhost:8333/your-gitlab.example.com/group/repo.git/info/refs?service=git-upload-pack
```

The proxy extracts the domain from the path, reconstructs the real HTTPS URL, forwards the request (including `Authorization`), and streams the response back with CORS headers.

---

## How it works

```
Browser (isomorphic-git)
        │
        │  GET /your-gitlab.example.com/group/repo.git/info/refs?service=git-upload-pack
        ▼
  cors-proxy-py  (localhost:8333)
        │
        │  GET https://your-gitlab.example.com/group/repo.git/info/refs?service=git-upload-pack
        │  Authorization: Basic <forwarded as-is>
        ▼
  GitLab server
        │
        │  200 OK  (no CORS headers)
        ▼
  cors-proxy-py
        │  adds Access-Control-Allow-Origin, etc.
        ▼
Browser (isomorphic-git)  ✓
```

### Allowed requests

Only git protocol requests are proxied. Everything else returns `403 Forbidden`.

| Method | Path pattern | Purpose |
|--------|-------------|---------|
| `GET` | `*/info/refs?service=git-upload-pack` | fetch/clone discovery |
| `POST` | `*/git-upload-pack` | fetch/clone data |
| `GET` | `*/info/refs?service=git-receive-pack` | push discovery |
| `POST` | `*/git-receive-pack` | push data |
| `OPTIONS` | any of the above | CORS preflight |

---

## CLI reference

```
cors-proxy start [-p PORT] [-d]
cors-proxy stop
```

| Flag | Description |
|------|-------------|
| `-p PORT` | Port to listen on (default: 9999) |
| `-d` | Run as background daemon (writes PID to `cors-proxy.pid`) |

> **Note:** In Docker, the server runs in the foreground via `python3 -m cors_proxy.server`. Do not use `cors-proxy start` as the Docker `CMD` — the double-fork daemonization exits the foreground process and kills the container.

---

## Middleware usage

You can embed the proxy in your own aiohttp application:

```python
from aiohttp import web
from cors_proxy.middleware import create_proxy_middleware

proxy_middleware, get_client_session = create_proxy_middleware(
    origin="https://your-app.example.com",
    insecure_origins=[],
)

app = web.Application(middlewares=[proxy_middleware])
web.run_app(app, port=9999)
```

Optional `authorization` parameter accepts an async callable `(request) -> bool` to gate access before proxying:

```python
async def check_auth(request):
    token = request.headers.get("X-Proxy-Token", "")
    return token == EXPECTED_TOKEN  # compare against your secret

proxy_middleware, _ = create_proxy_middleware(
    origin="*",
    authorization=check_auth,
)
```

---

## Security notes

- **Set `ALLOW_ORIGIN` in production.** The default `*` allows any website to use your proxy as a relay. Restrict it to your app's origin.
- **Deploy behind a reverse proxy** (nginx, Caddy, Traefik) for TLS termination and rate limiting.
- **The proxy can reach any HTTPS host** — target domains are not restricted. Run it in a private network or behind a firewall if you do not want it used as an open relay.
- **Credentials are not logged.** Auth tokens passed via the `Authorization` header are forwarded but not printed to stdout.
- **Response size is capped** at `MAX_RESPONSE_SIZE` (default 512 MB) to prevent unbounded memory use.

---

## Project layout

```
cors_proxy/
├── server.py        # aiohttp app, root handler, startup/shutdown
├── middleware.py    # CORS headers, filtering, proxy logic, streaming
├── allow_request.py # git request detection predicates
├── cli.py           # start/stop CLI
└── config.py        # environment variable helpers
Dockerfile
pyproject.toml
```

---

## Requirements

- Python 3.9+
- `aiohttp >= 3.9, < 4`
- `psutil >= 5.9, < 7` (for `cors-proxy stop`)
- `python-daemon >= 3.0, < 4` (for `cors-proxy start -d`)

---

## License

MIT
