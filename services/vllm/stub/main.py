"""CPU-only vLLM stub. Same OpenAI-compatible API. Returns canned tokens."""
from fastapi import FastAPI
app = FastAPI()


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/v1/chat/completions")
async def completions(request: dict = {}):
    return {
        "id": "stub-001",
        "choices": [{"message": {"role": "assistant",
                                  "content": "[vLLM stub] Response."},
                     "finish_reason": "stop"}],
        "model": "stub",
        "usage": {"prompt_tokens": 10, "completion_tokens": 8, "total_tokens": 18},
    }
