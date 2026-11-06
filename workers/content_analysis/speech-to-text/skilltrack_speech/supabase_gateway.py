"""Small HTTPS client. Credentials are sent only to the configured Supabase host."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlparse
from urllib.request import Request, urlopen

from .config import Config


class GatewayError(RuntimeError):
    """A backend call failed; raw responses and credentials are never included."""


class SupabaseGateway:
    def __init__(self, config: Config):
        parsed = urlparse(config.supabase_url)
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
            raise ValueError("SUPABASE_URL must be an HTTPS project URL")
        self.config = config

    def _headers(self) -> dict[str, str]:
        return {
            "apikey": self.config.service_role_key,
            "Authorization": f"Bearer {self.config.service_role_key}",
        }

    def _rpc(self, name: str, payload: dict[str, Any]) -> Any:
        request = Request(
            f"{self.config.supabase_url}/rest/v1/rpc/{name}",
            data=json.dumps(payload).encode("utf-8"),
            headers={**self._headers(), "Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urlopen(request, timeout=45) as response:
                return json.load(response)
        except (HTTPError, URLError, TimeoutError, ValueError) as exc:
            # HTTP bodies can contain sensitive data. The status code is sufficient here.
            status = getattr(exc, "code", "network")
            raise GatewayError(f"Backend RPC {name} failed ({status})") from None

    def claim(self, lease_seconds: int) -> dict[str, Any] | None:
        result = self._rpc("claim_transcription_job", {"p_lease_seconds": lease_seconds})
        if result is None:
            return None
        if not isinstance(result, dict):
            raise GatewayError("Backend returned an invalid job")
        return result

    def renew(self, job_id: str, token: str, lease_seconds: int) -> bool:
        return self._rpc("renew_transcription_claim", {
            "p_job_id": job_id,
            "p_claim_token": token,
            "p_lease_seconds": lease_seconds,
        }) is True

    def complete(
        self, job_id: str, token: str, transcript: str,
        language: str | None, segments: list[dict[str, Any]],
    ) -> bool:
        return self._rpc("complete_transcription_job", {
            "p_job_id": job_id,
            "p_claim_token": token,
            "p_transcript_text": transcript,
            "p_language": language,
            "p_segments": segments,
        }) is True

    def fail(self, job_id: str, token: str, error_code: str) -> bool:
        return self._rpc("fail_transcription_job", {
            "p_job_id": job_id,
            "p_claim_token": token,
            "p_error_code": error_code,
        }) is True

    def download(self, bucket: str, storage_path: str, destination: Path) -> None:
        if (not bucket or "/" in bucket or not storage_path
                or any(part in ("", ".", "..") for part in storage_path.split("/"))):
            raise GatewayError("Invalid Storage object path")
        encoded = f"{quote(bucket, safe='')}/{quote(storage_path, safe='/')}"
        request = Request(
            f"{self.config.supabase_url}/storage/v1/object/authenticated/{encoded}",
            headers=self._headers(),
            method="GET",
        )
        limit = self.config.max_video_mb * 1024 * 1024
        try:
            with urlopen(request, timeout=120) as response, destination.open("wb") as output:
                size = 0
                while chunk := response.read(1024 * 1024):
                    size += len(chunk)
                    if size > limit:
                        raise GatewayError("Video exceeds MAX_VIDEO_MB")
                    output.write(chunk)
        except GatewayError:
            raise
        except (HTTPError, URLError, TimeoutError, OSError) as exc:
            status = getattr(exc, "code", "network")
            raise GatewayError(f"Storage download failed ({status})") from None

