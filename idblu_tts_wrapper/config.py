from __future__ import annotations

import os
from dataclasses import dataclass


def _truthy(value: str | None, *, default: bool) -> bool:
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class Settings:
    admin_key: str
    upstream_url: str
    default_model: str
    default_task_type: str
    default_response_format: str
    default_voice_id: str
    voice_cache_dir: str
    health_public: bool

    @classmethod
    def from_env(cls) -> "Settings":
        return cls(
            admin_key=os.getenv("IDBLU_TTS_ADMIN_KEY", ""),
            upstream_url=os.getenv("IDBLU_TTS_UPSTREAM_URL", "http://127.0.0.1:8091").rstrip("/"),
            default_model=os.getenv("IDBLU_TTS_MODEL_ID", "Qwen/Qwen3-TTS-12Hz-1.7B-Base"),
            default_task_type=os.getenv("IDBLU_TTS_TASK_TYPE", "Base"),
            default_response_format=os.getenv("IDBLU_TTS_RESPONSE_FORMAT", "pcm"),
            default_voice_id=os.getenv("IDBLU_TTS_DEFAULT_VOICE_ID", "eliane"),
            voice_cache_dir=os.getenv("IDBLU_TTS_VOICE_CACHE_DIR", "/data/voices"),
            health_public=_truthy(os.getenv("IDBLU_TTS_PUBLIC_HEALTH"), default=True),
        )
