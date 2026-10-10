#!/usr/bin/env bash
set -euo pipefail
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass() { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; FAILED=1; }
FAILED=0

echo ""
echo "EPOCH Cluster Validation — Session 16.1"
echo "========================================"

# 0. Wait up to 90s for all containers to report healthy before checking
#    anything else — right after `docker compose up -d` the first
#    healthcheck interval hasn't fired yet, and every check below would
#    flake. This does not run the checks; it just waits for the healthy
#    state that check #6 later re-verifies.
echo "Waiting for containers to report healthy..."
for i in $(seq 1 30); do
    TOTAL=$(docker compose ps --status running -q 2>/dev/null | wc -l | tr -d ' ')
    HEALTHY=$(docker compose ps 2>/dev/null | grep -c "healthy" || true)
    [ "$TOTAL" -gt 0 ] && [ "$HEALTHY" -eq "$TOTAL" ] && break
    sleep 3
done

# 1. Gateway health from host
if curl -fsS http://localhost:8000/health 2>/dev/null | grep -q '"ok"'; then
    pass "fastapi health: $(curl -s http://localhost:8000/health)"
else
    fail "fastapi health: not reachable on localhost:8000"
fi

# 2. Backplane DNS — resolve from inside fastapi container
for SVC in litellm redis postgres vllm; do
    if docker exec epoch-fastapi-1 getent hosts $SVC > /dev/null 2>&1; then
        pass "backplane DNS: $SVC resolves from inside fastapi"
    else
        fail "backplane DNS: $SVC DOES NOT resolve from fastapi (check networks:)"
    fi
done

# 3. litellm reachable from fastapi via container-name
if docker exec epoch-fastapi-1 curl -fsS http://litellm:4000/health > /dev/null 2>&1; then
    pass "litellm reachable from fastapi via http://litellm:4000"
else
    fail "litellm NOT reachable from fastapi"
fi

# 4. Port 8000 on host
if nc -zw2 localhost 8000 2>/dev/null; then
    pass "port 8000 reachable from host"
else
    fail "port 8000 NOT reachable from host"
fi

# 5. vLLM NOT directly exposed to host (no ports: mapping)
if nc -zw1 localhost 8001 2>/dev/null; then
    fail "vllm port 8001 is exposed to host — remove ports: from vllm service"
else
    pass "vllm not directly reachable from host (correct)"
fi

# 6. All containers healthy
UNHEALTHY=$(docker compose ps 2>/dev/null | grep -v "healthy" | grep -c "Up" || true)
if [ "$UNHEALTHY" -eq 0 ]; then
    pass "all containers report healthy"
else
    fail "$UNHEALTHY container(s) not yet healthy (check docker compose ps)"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo -e "${GREEN}✓ Session 16.1 COMPLETE.${NC}"
else
    echo -e "${RED}✗ Some checks failed. See above.${NC}"; exit 1
fi
