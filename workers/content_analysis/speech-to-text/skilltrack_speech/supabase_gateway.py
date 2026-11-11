"""Small HTTPS client. Credentials are sent only to the configured Supabase host."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote, unquote, urlparse
from urllib.request import Request, build_opener, HTTPRedirectHandler


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def urlopen(request, timeout):
    # Never forward backend credentials to a redirect target.
    return build_opener(NoRedirect).open(request, timeout=timeout)

from .config import Config


class GatewayError(RuntimeError):
    """A backend call failed; raw responses and credentials are never included."""


class SupabaseGateway:
    def __init__(self, config: Config):
        parsed = urlparse(config.supabase_url)
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
            raise ValueError("SUPABASE_URL must be an HTTPS project URL")
        self.config = config
        self.discovery_cursor: str | None = None

    def _headers(self) -> dict[str, str]:
        return {"apikey": self.config.service_role_key}

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

    def discover(self, draft_resource_id: str | None = None) -> None:
        rows = self._rpc("resource_extraction_candidates", {
            "p_limit": self.config.discovery_batch_size,
            "p_after_id": self.discovery_cursor if draft_resource_id is None else None,
            "p_draft_resource_id": draft_resource_id,
        })
        if not isinstance(rows, list):
            raise GatewayError("Backend returned invalid discovery candidates")
        for row in rows:
            kind = row.get("kind", "Video")
            bucket = self.config.video_bucket if kind == "Video" else self.config.pdf_bucket
            path = self._storage_path(row.get("external_url"), bucket)
            if kind not in {"Video", "Reading"} or (kind == "Reading" and (not path or not path.lower().endswith(".pdf"))):
                continue
            if path is not None:
                self._rpc("enqueue_discovered_extraction", {
                    "p_resource_id": row["id"],
                    "p_external_url": row["external_url"],
                    "p_storage_bucket": bucket,
                    "p_storage_path": path,
                    "p_allow_draft": draft_resource_id is not None,
                })
        # Advance only after the page succeeds. Replaying a page is idempotent.
        if draft_resource_id is None:
            self.discovery_cursor = (
                rows[-1]["id"] if len(rows) == self.config.discovery_batch_size else None
            )

    def _video_path(self, value: Any) -> str | None:
        return self._storage_path(value, self.config.video_bucket)

    def _storage_path(self, value: Any, bucket: str) -> str | None:
        if not isinstance(value, str):
            return None
        try:
            url = urlparse(value)
            project = urlparse(self.config.supabase_url)
            if (url.scheme != "https" or url.netloc != project.netloc
                    or url.username or url.password or url.query or url.fragment
                    or "?" in value or "#" in value):
                return None
            for mode in ("public", "authenticated"):
                prefix = f"/storage/v1/object/{mode}/{quote(bucket, safe='')}/"
                if url.path.startswith(prefix):
                    path = unquote(url.path[len(prefix):], errors="strict")
                    if (path and len(path) <= 1024 and "\\" not in path
                            and all(part not in ("", ".", "..") for part in path.split("/"))
                            and not any(ord(char) < 32 for char in path)):
                        return path
        except (ValueError, UnicodeError):
            pass
        return None

    # Atomic RPCs claim and update resource_extractions by its primary key.
    def claim(self, lease_seconds: int) -> dict[str, Any] | None:
        result = self._rpc("claim_resource_extraction", {"p_lease_seconds": lease_seconds})
        if result is None:
            return None
        if not isinstance(result, dict):
            raise GatewayError("Backend returned an invalid job")
        return result

    def renew(self, transcript_id: str, token: str, lease_seconds: int) -> bool:
        return self._rpc("renew_resource_extraction", {
            "p_extraction_id": transcript_id,
            "p_claim_token": token,
            "p_lease_seconds": lease_seconds,
        }) is True

    def complete(
        self, transcript_id: str, token: str, transcript: str,
        language: str | None, segments: list[dict[str, Any]],
    ) -> bool:
        return self._rpc("complete_resource_extraction", {
            "p_extraction_id": transcript_id,
            "p_claim_token": token,
            "p_extracted_text": transcript,
            "p_language": language,
            "p_segments": segments,
        }) is True

    def fail(self, transcript_id: str, token: str, error_code: str) -> bool:
        return self._rpc("fail_resource_extraction", {
            "p_extraction_id": transcript_id,
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

