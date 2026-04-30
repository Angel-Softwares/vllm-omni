from __future__ import annotations

import logging
from typing import Any, AsyncGenerator

import httpx
from fastapi import Depends, FastAPI, Header, HTTPException, status
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, ConfigDict

from idblu_tts_wrapper.config import Settings
from idblu_tts_wrapper.voice_registry import VoiceRegistry

logger = logging.getLogger(__name__)


class SpeechRequest(BaseModel):
    model_config = ConfigDict(extra="allow")

    input: str
    model: str | None = None
    voice_id: str | None = None
    voice: str | None = None
    ref_audio: str | None = None
    ref_text: str | None = None
    response_format: str | None = None
    task_type: str | None = None
    language: str | None = None
    stream: bool | None = None


settings = Settings.from_env()
voice_registry = VoiceRegistry(settings.voice_cache_dir)
app = FastAPI(title="idblu_tts", version="1.0.0")


async def _authorize(
    x_admin_key: str | None = Header(default=None),
    authorization: str | None = Header(default=None),
) -> None:
    if not settings.admin_key:
        logger.warning("IDBLU_TTS_ADMIN_KEY is not configured; rejecting authenticated endpoints.")
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="Service auth not configured")

    bearer_token = ""
    if authorization:
        scheme, _, token = authorization.partition(" ")
        if scheme.lower() == "bearer":
            bearer_token = token.strip()

    presented_key = (x_admin_key or "").strip() or bearer_token
    if presented_key != settings.admin_key:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid admin key")


@app.get("/health")
async def healthcheck() -> JSONResponse:
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.get(f"{settings.upstream_url}/health")
            response.raise_for_status()
            payload = response.json()
    except Exception as exc:  # pragma: no cover - error path is exercised in runtime
        logger.warning("Upstream health check failed: %s", exc)
        return JSONResponse(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, content={"status": "unhealthy"})
    return JSONResponse(content=payload)


@app.get("/v1/audio/voices", dependencies=[Depends(_authorize)])
async def list_voices() -> dict[str, Any]:
    return {"data": voice_registry.list_voices()}


@app.post("/v1/audio/speech", dependencies=[Depends(_authorize)])
async def create_speech(request: SpeechRequest) -> StreamingResponse:
    payload = request.model_dump(exclude_none=True)
    payload["model"] = payload.get("model") or settings.default_model
    payload["task_type"] = payload.get("task_type") or settings.default_task_type
    payload["response_format"] = payload.get("response_format") or settings.default_response_format
    payload["stream"] = True if payload.get("stream") is None else payload["stream"]

    resolved_locally = False
    requested_voice_id = payload.pop("voice_id", None) or payload.get("voice") or settings.default_voice_id

    try:
        if payload.get("ref_audio") is None and requested_voice_id:
            voice_spec = voice_registry.resolve(requested_voice_id)
            payload["ref_audio"] = voice_spec.ref_audio
            if not payload.get("ref_text") and voice_spec.ref_text:
                payload["ref_text"] = voice_spec.ref_text
            payload.pop("voice", None)
            resolved_locally = True
    except FileNotFoundError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc

    logger.info(
        "Proxying TTS request model=%s voice=%s resolved_locally=%s",
        payload.get("model"),
        requested_voice_id,
        resolved_locally,
    )

    async def stream() -> AsyncGenerator[bytes, None]:
        async with httpx.AsyncClient(timeout=None) as client:
            async with client.stream("POST", f"{settings.upstream_url}/v1/audio/speech", json=payload) as response:
                response.raise_for_status()
                async for chunk in response.aiter_bytes():
                    if chunk:
                        yield chunk

    return StreamingResponse(stream(), media_type=_media_type_for_format(payload["response_format"]))


def _media_type_for_format(response_format: str) -> str:
    normalized = response_format.lower()
    if normalized == "pcm":
        return "audio/pcm"
    if normalized == "wav":
        return "audio/wav"
    if normalized == "mp3":
        return "audio/mpeg"
    return "application/octet-stream"
