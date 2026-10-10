# EPOCH Cluster — Session 16.1

Production containerization of the EPOCH stack: five services (Postgres, Redis,
vLLM, LiteLLM, FastAPI) declared in one `docker-compose.yml`, booting in a
strict three-layer dependency order behind a real `HEALTHCHECK`-driven
`depends_on` chain.

This README has been validated end-to-end against this exact directory:
clean teardown → image rebuild → cold boot → `validate.sh`, run with no
manual waiting in between. See [Verified state](#verified-state) for the
sanity-check log.

---

## Architecture

```
                    ┌─────────────┐
   host:8000  ───►  │   fastapi   │  (gateway network — only service reachable from host)
                    └──────┬──────┘
                           │ backplane network (never exposed to host)
             ┌─────────────┼─────────────┬─────────────┐
             ▼             ▼             ▼             ▼
        ┌─────────┐  ┌──────────┐  ┌─────────┐   ┌──────────┐
        │ litellm │  │  redis   │  │postgres │   │  ...     │
        └────┬────┘  └──────────┘  └─────────┘   └──────────┘
             │ depends_on: service_healthy
             ▼
        ┌─────────┐
        │  vllm   │  (CPU stub by default — see Real GPU vs. CPU stub)
        └─────────┘
```

Boot order (`depends_on: condition: service_healthy` at each arrow):

1. **Layer 1** — `postgres`, `redis`, `vllm` start in parallel, no upstream deps.
2. **Layer 2** — `litellm` waits for `vllm` to report healthy.
3. **Layer 3** — `fastapi` waits for `litellm` + `redis` + `postgres` to report healthy.

Only `fastapi` sits on both the `gateway` network (host-facing, port `8000`)
and the `backplane` network (east-west, no host ports). Every other service
uses `expose:` only — reachable from other containers, never from the host.
All inter-service URLs use **container-name DNS** (`http://litellm:4000`,
`redis://redis:6379`, ...), never `localhost`.

---

## Prerequisites

```bash
docker --version          # Docker Engine 24+
docker compose version    # Compose v2 — no hyphen
```

Verified against Docker Engine 27.3.1 / Compose v2.30.3 on this machine.

If `docker info` fails with `Cannot connect to the Docker daemon`, Docker
Desktop isn't running — start it (`open -a Docker` on macOS) and wait ~15s
before retrying.

---

## Cloning the repo

This directory is not yet pushed to a remote, and it's the git root itself —
`docker-compose.yml`, `services/`, etc. all live at the top level, with no
extra subfolder to `cd` into. If you're setting that up:

```bash
# from this directory, one time
git init
git add .
git commit -m "EPOCH cluster — Session 16.1"
git remote add origin <your-remote-url>
git push -u origin main
```

Once it has a remote, anyone else picks it up the normal way:

```bash
git clone <your-remote-url>
cd <the-directory-git-created>   # named after your remote, e.g. epoch-cluster
```

`.env` is git-ignored on purpose (see `.gitignore`) — it never gets pushed.
**After cloning, you must recreate it yourself** (see below) before the
cluster will boot; a fresh clone has no secrets in it.

---

## Quick start

```bash
# from the repo root — docker-compose.yml lives here directly

# 1. Secrets — .env is git-ignored, so a fresh clone won't have one.
#    The version in this directory already has working demo defaults
#    (JWT secret matching epoch_auth.py, local Postgres/Redis creds).
#    Only edit it if you're pointing at real GEMINI_API_KEY / OPENAI_API_KEY.
test -f .env || echo "Missing .env — copy one from the course material or teammate before continuing."

# 2. Build all images
docker compose build

# 3. Boot the cluster
docker compose up -d

# 4. Validate
bash validate.sh
```

Expected `bash validate.sh` output:

```
EPOCH Cluster Validation — Session 16.1
========================================
Waiting for containers to report healthy...
✓ fastapi health: {"status":"ok","service":"epoch-fastapi"}
✓ backplane DNS: litellm resolves from inside fastapi
✓ backplane DNS: redis resolves from inside fastapi
✓ backplane DNS: postgres resolves from inside fastapi
✓ backplane DNS: vllm resolves from inside fastapi
✓ litellm reachable from fastapi via http://litellm:4000
✓ port 8000 reachable from host
✓ vllm not directly reachable from host (correct)
✓ all containers report healthy

✓ Session 16.1 COMPLETE.
```

`validate.sh` waits (up to 90s) for every container to report healthy before
running its checks, so it's safe to run immediately after `docker compose up -d`
— no manual `sleep` needed.

### Everyday commands

```bash
docker compose ps                 # status + health of all 5 services
docker compose logs -f            # tail all services
docker compose logs -f fastapi    # tail one service
docker compose down               # stop + remove containers, keep volumes
docker compose down --volumes     # also wipe pg_data / redis_data / hf_cache — destructive
docker compose restart fastapi    # restart one service
```

---

## Validating the build

Beyond `validate.sh`, a few manual checks worth knowing:

```bash
# Image size scoreboard
docker images | grep epoch
#   epoch-fastapi   ~235 MB   (target: < 320 MB)
#   epoch-vllm      ~212 MB   (CPU stub; real GPU build is a different image, target < 7 GB)

# Watch the three-layer boot sequence live
docker compose logs -f
#   Layer 1: redis, postgres, vllm boot in parallel
#   Layer 2: litellm starts only after vllm is healthy
#   Layer 3: fastapi starts only after litellm + redis + postgres are healthy

# Backplane DNS, one-liner, from inside the gateway container
docker exec epoch-fastapi-1 sh -c \
  'for s in litellm redis postgres vllm; do echo -n "$s: "; getent hosts $s || echo FAIL; done'

# Human-readable backend status through the gateway itself
curl -s http://localhost:8000/cluster/health | python3 -m json.tool

# Confirm vLLM is NOT reachable from the host (no ports: mapping — by design)
nc -zw1 localhost 8001 && echo "BAD: exposed" || echo "OK: not exposed"

# Layer X-ray on the fastapi image (checks nothing leaked into a layer)
docker history epoch-fastapi:latest --no-trunc | grep -i secret
# should print nothing
```

### Verified state

The following was run end-to-end against this directory on 2026-08-26 as a
full sanity check — not just "the files look right," but an actual clean
rebuild:

```
docker compose down                  # remove containers + networks
docker rmi epoch-fastapi epoch-vllm  # force real rebuild, not cache reuse
docker compose build                 # rebuild both custom images
docker compose up -d                 # cold boot, fresh networks
bash validate.sh                     # run immediately, zero manual delay
```

Result: all 5 containers reported `healthy`, and `validate.sh` printed
`✓ Session 16.1 COMPLETE.` with no flakes. Cold boot from `up -d` to all
containers `Started` took ~17s on this machine (image layers were
already cached locally; a true first-time `docker compose build` on a
clean machine will take several minutes to pull `python:3.11-slim`,
`postgres:16-alpine`, `redis:7-alpine`, and `ghcr.io/berriai/litellm:main`,
the last of which is ~830 MB).

This project also previously lived one level deeper, in an `epoch-cluster/`
subfolder — it was flattened to the repo root afterward (no other project
shares this directory, so the nesting only added an unnecessary `cd` after
cloning). `docker compose down` → move files up → `docker compose build` →
`docker compose up -d` → `bash validate.sh` was re-run in full from the new
location and passed identically; `COMPOSE_PROJECT_NAME=epoch` in `.env`
keeps container names (`epoch-fastapi-1`, etc.) stable regardless of the
directory name, so this move required no changes to `docker-compose.yml`.

---

## Known gotchas (found during this sanity pass — not in the original spec)

These aren't the intentional [bug exercises](#deliberate-bug-exercises) below —
they're real issues that block a first-time boot if you're typing this cluster
out by hand from a written spec, and are already fixed in this directory:

1. **`ghcr.io/berriai/litellm:main`'s `ENTRYPOINT` ignores `command:`.** It's a
   fixed shell string (`litellm --config /app/proxy_server_config.yaml --port 4000`),
   so config must be volume-mounted to that exact path — not wherever you'd
   naturally mount it (`/app/config.yaml` gets silently ignored, and the
   container falls back to a baked-in example config with dummy Azure
   endpoints that fails to start).
2. **The litellm image has neither `curl` nor `wget`.** Its `HEALTHCHECK`
   here uses `python3 -c "import urllib.request; ..."` against `/health`
   instead — `python3` is the only HTTP-capable tool present in that image.
3. **`pip install --target=` does not put console-script entry points on
   `PATH`.** `uvicorn` ends up at `site-packages/bin/uvicorn`, not on `PATH`.
   The fastapi `Dockerfile`'s `CMD` uses `python -m uvicorn ...` instead of
   bare `uvicorn ...` to sidestep this.

If you're re-deriving this cluster from a written spec elsewhere, expect to
hit these three regardless of how carefully you copy the YAML — they only
surface when you actually run `docker compose up`, not from reading the
compose file.

---

## Real GPU vs. CPU stub

`docker-compose.yml`'s `vllm` service builds `Dockerfile.stub` by default —
CPU-only, no GPU required, boots in under a second, returns canned
OpenAI-compatible responses. This is what's running in this sanity check.

To switch to the real GPU-backed vLLM:

```yaml
# in docker-compose.yml, under services.vllm.build:
dockerfile: Dockerfile        # was: Dockerfile.stub
```

and uncomment the `deploy.resources.reservations.devices` block in the same
service. Also raise `healthcheck.start_period` for `vllm` from `30s` to
`120s` — real weight loading for an 8B model takes 90–120s, and a too-short
`start_period` will get `vllm` marked unhealthy before it's actually ready,
which blocks `litellm` from ever starting (this is [Exercise 2](#deliberate-bug-exercises)
below, reproduced deliberately).

---

## Deliberate bug exercises

Three intentional breakages, each demonstrating a real containerization
failure mode. All three were run against this directory, observed, and
reverted — the cluster is currently in the clean, working state.

| # | Bug | How to reproduce | Lesson |
|---|-----|-------------------|--------|
| 1 | `services/fastapi/app/main.py`: change `LITELLM_URL` default to `"http://localhost:4000"` | `docker compose build fastapi && docker compose up -d fastapi`, then `curl localhost:8000/cluster/health` | `localhost` inside a container means *that container*. Use container-name DNS. |
| 2 | `docker-compose.yml`: set `vllm`'s `healthcheck.start_period` too low relative to real cold-start time | With the CPU stub this needs an artificial `time.sleep()` added to `stub/main.py` to actually reproduce (the stub itself boots instantly) — set `start_period: 1s` + a 45s sleep, then `docker compose up -d vllm litellm` | `start_period` must exceed real cold-start time (2× is a safe rule of thumb), or `depends_on: condition: service_healthy` blocks every downstream service. |
| 3 | `services/fastapi/Dockerfile`: add `ENV JWT_SECRET=leaked-in-every-layer` before `USER app` | `docker build -t epoch-leak-test ./services/fastapi && docker history epoch-leak-test --no-trunc \| grep JWT` | Secrets baked in with `ENV` persist in the image's layer history forever, visible to anyone who pulls it — regardless of what the running container's actual env looks like. Docker's own Buildx even flags this natively as `SecretsUsedInArgOrEnv`. Secrets belong only in `env_file:`, injected at runtime. |

Revert each change after reproducing it — none of these should be left in
place.

---

## Directory structure

Flat at the repo root — no wrapper folder to `cd` into after cloning:

```
.
├── .env                    # secrets — git-ignored, recreate after cloning
├── .gitignore
├── docker-compose.yml      # the 5-service, 2-network, 4-volume declaration
├── validate.sh             # end-to-end health + DNS + isolation checks
├── README.md                # this file
│
└── services/
    ├── fastapi/             # the only host-facing service (port 8000)
    │   ├── Dockerfile        # multi-stage, non-root, < 320 MB
    │   ├── requirements.txt
    │   └── app/main.py       # /health, /cluster/health, /agent/invoke (JWT)
    │
    ├── vllm/
    │   ├── Dockerfile        # real GPU build — nvidia/cuda multi-stage
    │   ├── Dockerfile.stub   # CPU-only fake — used by default in compose
    │   ├── requirements.txt  # real-GPU deps only
    │   └── stub/main.py      # canned OpenAI-compatible responses
    │
    └── litellm/
        └── config.yaml       # routes epoch-default → vllm, falls back to Gemini
```

---

## Final checklist

- [x] Two networks: `backplane` (east-west only) + `gateway` (fastapi only)
- [x] Only `fastapi` has a `ports:` mapping — everything else uses `expose:`
- [x] All five services have working `healthcheck:` blocks
- [x] `litellm` `depends_on: vllm: condition: service_healthy`
- [x] `fastapi` `depends_on:` litellm + redis + postgres, all `service_healthy`
- [x] All internal URLs use container-name DNS, not `localhost`
- [x] `env_file: [.env]` — no secrets baked into any Dockerfile
- [x] Four named volumes: `pg_data`, `redis_data`, `hf_cache`, `epoch_indexes`
- [x] `epoch-fastapi` image: 235 MB (target < 320 MB)
- [x] `docker compose ps` — all five `healthy`, cold boot verified
- [x] `bash validate.sh` — all checks pass, verified with zero manual delay
- [x] All three bug exercises reproduced and reverted

---

## What's next — Session 16.2

Per the handoff notes for this cluster:

- **Keep the cluster running** (`docker compose up -d`) between sessions —
  16.2 builds directly on top of this, it doesn't re-provision from scratch.
- 16.2 adds a **`smoke_test.py`** that fires real requests at this running
  cluster (through `POST /agent/invoke` with a signed JWT, matching the
  claims `verify_jwt()` in `main.py` requires: `exp`, `iat`, `sub`, `role`,
  `hospital_id`, `jti`) and asserts on the responses, rather than just
  checking health/DNS the way `validate.sh` does.
- Before starting 16.2, re-run `bash validate.sh` to confirm you're picking
  up from a known-good state — don't assume the cluster is still healthy
  just because it was last time you looked.

Beyond 16.2, the spec doesn't yet document later sessions in this track —
treat anything past 16.2 as unconfirmed until its own materials show up.
