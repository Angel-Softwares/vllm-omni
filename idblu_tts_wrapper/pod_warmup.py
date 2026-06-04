from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


BASE_URL = os.getenv("IDBLU_TTS_BASE_URL", "http://127.0.0.1:8080").rstrip("/")
UPSTREAM_URL = os.getenv("IDBLU_TTS_UPSTREAM_URL", "http://127.0.0.1:8091").rstrip("/")
MAX_WAIT_SECONDS = int(os.getenv("IDBLU_TTS_WARMUP_MAX_WAIT_SECONDS", "1800"))
STATUS_FILE = Path(os.getenv("IDBLU_TTS_WARMUP_STATUS_FILE", "/tmp/idblu-tts-warmup-status.json"))
SECRET_FILE = Path(os.getenv("IDBLU_TTS_ADMIN_KEY_FILE", "/mnt/secrets-store/IDBLU_TTS_ADMIN_KEY"))


def _write_status(status: str, **extra: Any) -> None:
    STATUS_FILE.parent.mkdir(parents=True, exist_ok=True)
    payload = {"status": status, **extra}
    STATUS_FILE.write_text(json.dumps(payload))


def _request(url: str, *, headers: dict[str, str] | None = None, timeout: float = 10.0) -> urllib.response.addinfourl:
    req = urllib.request.Request(url, headers=headers or {})
    return urllib.request.urlopen(req, timeout=timeout)


def _request_json(url: str, *, headers: dict[str, str] | None = None, timeout: float = 10.0) -> dict[str, Any]:
    with _request(url, headers=headers, timeout=timeout) as response:
        raw = response.read().decode("utf-8")
        return json.loads(raw) if raw else {}


def _wait_for_endpoint(url: str, *, expected_status: int = 200, timeout: float = 5.0) -> None:
    deadline = time.monotonic() + MAX_WAIT_SECONDS
    last_error = ""
    while time.monotonic() < deadline:
        try:
            with _request(url, timeout=timeout) as response:
                if response.status == expected_status:
                    return
                last_error = f"unexpected status {response.status}"
        except Exception as exc:
            last_error = repr(exc)
        time.sleep(2)
    raise RuntimeError(f"Endpoint not ready: {url}: {last_error}")


def _resolve_voice_id(admin_key: str) -> str:
    voice_id = os.getenv("IDBLU_TTS_DEFAULT_VOICE_ID", "").strip()
    if voice_id:
        return voice_id
    payload = _request_json(
        f"{BASE_URL}/v1/audio/voices",
        headers={"x-admin-key": admin_key},
        timeout=15.0,
    )
    voices = payload.get("data") or []
    if voices:
        return str(voices[0].get("voice_id") or "").strip()
    return ""


def _run_warmup_request(admin_key: str, voice_id: str) -> int:
    body = {
        "model": os.environ["IDBLU_TTS_MODEL_ID"],
        "input": os.environ.get("IDBLU_TTS_WARMUP_TEXT", "Bonjour, ceci est un court test de demarrage."),
        "voice_id": voice_id,
        "task_type": os.environ.get("IDBLU_TTS_TASK_TYPE", "Base"),
        "language": "Auto",
        "stream": True,
        "response_format": os.environ.get("IDBLU_TTS_RESPONSE_FORMAT", "pcm"),
    }
    req = urllib.request.Request(
        f"{BASE_URL}/v1/audio/speech",
        data=json.dumps(body).encode("utf-8"),
        headers={"content-type": "application/json", "x-admin-key": admin_key},
        method="POST",
    )
    total = 0
    with urllib.request.urlopen(req, timeout=MAX_WAIT_SECONDS) as response:
        while True:
            chunk = response.read(4096)
            if not chunk:
                break
            total += len(chunk)
            if total >= 49152:
                break
    return total


def main() -> int:
    _write_status("pending")
    try:
        _wait_for_endpoint(f"{BASE_URL}/health")
        _wait_for_endpoint(f"{UPSTREAM_URL}/health")
        admin_key = SECRET_FILE.read_text().strip()
        voice_id = _resolve_voice_id(admin_key)
        if not voice_id:
            raise RuntimeError("No voice available for warmup")
        bytes_read = _run_warmup_request(admin_key, voice_id)
        _write_status("complete", voice_id=voice_id, bytes_read=bytes_read)
        print(f"Warmup completed with voice_id={voice_id} bytes_read={bytes_read}")
        return 0
    except Exception as exc:
        _write_status("failed", reason=str(exc))
        print(f"Warmup failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
