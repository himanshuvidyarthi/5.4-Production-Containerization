"""
FastAPI gateway for the EPOCH cluster.

/health         — liveness probe (HEALTHCHECK polls this)
/cluster/health — human-readable backend status (calls litellm, redis, vllm)
/agent/invoke   — authenticated agent call (JWT -> LiteLLM)

All upstream URLs come from environment variables injected by compose.
NEVER use localhost — use container-name DNS (http://litellm:4000 etc.).
"""
import os
import httpx
import redis.asyncio as aioredis
import jwt
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

app = FastAPI(title="EPOCH Gateway")

# Injected by compose via env_file — resolved by container-name DNS
LITELLM_URL        = os.environ.get("LITELLM_URL",        "http://litellm:4000")
REDIS_URL          = os.environ.get("REDIS_URL",           "redis://redis:6379/0")
VLLM_URL           = os.environ.get("VLLM_URL",            "http://vllm:8000")
JWT_SECRET         = os.environ.get("JWT_SECRET",          "epoch-demo-secret")
JWT_AUDIENCE       = os.environ.get("JWT_AUDIENCE",        "epoch-gateway.internal")
JWT_ISSUER         = os.environ.get("JWT_ISSUER",          "https://idp.epoch.internal")
LITELLM_MASTER_KEY = os.environ.get("LITELLM_MASTER_KEY",  "epoch-litellm-key")


@app.get("/health")
async def health():
    """Liveness probe. Returns immediately — no backend calls.
    HEALTHCHECK and depends_on poll this; do NOT check backends here
    or a degraded backend will kill the fastapi health status too."""
    return {"status": "ok", "service": "epoch-fastapi"}


@app.get("/cluster/health")
async def cluster_health():
    """Human-readable backend status. Calls litellm, vllm, redis."""
    results = {}
    async with httpx.AsyncClient(timeout=5.0) as client:
        for name, url in [
            ("litellm", f"{LITELLM_URL}/health"),
            ("vllm",    f"{VLLM_URL}/health"),
        ]:
            try:
                r = await client.get(url)
                results[name] = "ok" if r.status_code == 200 else f"http_{r.status_code}"
            except Exception as e:
                results[name] = f"error:{str(e)[:50]}"
    try:
        r = aioredis.from_url(REDIS_URL)
        await r.ping()
        results["redis"] = "ok"
        await r.aclose()
    except Exception as e:
        results["redis"] = f"error:{str(e)[:50]}"
    overall = "ok" if all(v == "ok" for v in results.values()) else "degraded"
    return {"status": overall, "backends": results}


def verify_jwt(authorization: str) -> dict:
    """Verify Bearer JWT. algorithms=['HS256'] is explicit — never read
    alg from the token header (source of every major JWT CVE)."""
    if not authorization.startswith("Bearer "):
        raise ValueError("missing_bearer")
    try:
        return jwt.decode(
            authorization[7:], JWT_SECRET,
            algorithms=["HS256"],
            audience=JWT_AUDIENCE,
            issuer=JWT_ISSUER,
            options={"require": ["exp", "iat", "sub", "role", "hospital_id", "jti"]},
        )
    except jwt.ExpiredSignatureError:
        raise ValueError("token_expired")
    except jwt.InvalidAudienceError:
        raise ValueError("bad_audience")
    except jwt.InvalidSignatureError:
        raise ValueError("bad_signature")
    except Exception as e:
        raise ValueError(f"decode_error:{e}")


@app.post("/agent/invoke")
async def agent_invoke(request: Request):
    """Authenticated agent call. JWT -> LiteLLM (via container-name DNS)."""
    try:
        claims = verify_jwt(request.headers.get("Authorization", ""))
    except ValueError as e:
        return JSONResponse({"error": str(e)}, status_code=401)

    body = await request.json()
    prompt = body.get("prompt") or body.get("question", "")

    async with httpx.AsyncClient(timeout=30.0) as client:
        try:
            resp = await client.post(
                f"{LITELLM_URL}/chat/completions",
                headers={"Authorization": f"Bearer {LITELLM_MASTER_KEY}"},
                json={"model": "epoch-default",
                      "messages": [{"role": "user", "content": prompt}]},
            )
            answer = resp.json()
        except Exception as e:
            return JSONResponse({"error": f"litellm:{e}"}, status_code=502)

    return {"status": 200, "hospital_id": claims["hospital_id"],
            "role": claims["role"], "answer": answer}
