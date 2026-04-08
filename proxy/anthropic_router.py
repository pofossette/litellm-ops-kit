#!/usr/bin/env python3
import json
import os
import socket
import time
import urllib.parse
from http.client import HTTPConnection, HTTPException, HTTPResponse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


MODEL_FALLBACK_CHAINS = {
    "my-opus": ["my-opus-fallback", "my-opus-fallback-2", "my-opus-fallback-3"],
    "my-sonnet": ["my-sonnet-fallback", "my-sonnet-fallback-2", "my-sonnet-fallback-3"],
    "my-haiku": ["my-haiku-fallback", "my-haiku-fallback-2", "my-haiku-fallback-3"],
}

FALLBACK_MODEL_TO_TIER = {
    "my-opus-fallback": "fallback",
    "my-sonnet-fallback": "fallback",
    "my-haiku-fallback": "fallback",
    "my-opus-fallback-2": "fallback2",
    "my-sonnet-fallback-2": "fallback2",
    "my-haiku-fallback-2": "fallback2",
    "my-opus-fallback-3": "fallback3",
    "my-sonnet-fallback-3": "fallback3",
    "my-haiku-fallback-3": "fallback3",
}

ROUTE_TO_MODEL_KEY = {
    "my-opus": "OPUS",
    "my-sonnet": "SONNET",
    "my-haiku": "HAIKU",
}

RETRYABLE_STATUS_CODES = {408, 409, 425, 429}
PRIMARY_USAGE_LIMIT_COOLDOWN_SECONDS = 3600
PRIMARY_USAGE_LIMIT_UNTIL: dict[str, float] = {}
RETRYABLE_ERROR_KEYWORDS = (
    "quota",
    "credit",
    "balance",
    "insufficient",
    "exhausted",
    "rate limit",
    "rate_limit",
    "concurrent",
    "overloaded",
    "overload",
    "capacity",
    "temporarily unavailable",
    "usage limit",
    "limit reached",
    "timeout",
    "timed out",
    "connection reset",
    "connection refused",
    "network",
    "额度",
    "限流",
    "并发",
    "余额",
)


def upstream_request(
    host: str,
    port: int,
    method: str,
    path: str,
    body: bytes | None,
    headers: dict[str, str],
) -> HTTPResponse:
    conn = HTTPConnection(host, port, timeout=180)
    try:
        conn.request(method, path, body=body, headers=headers)
        resp = conn.getresponse()
        resp._codex_conn = conn  # type: ignore[attr-defined]
        return resp
    except Exception:
        conn.close()
        raise


def close_response(resp: HTTPResponse) -> None:
    conn = getattr(resp, "_codex_conn", None)
    try:
        resp.close()
    finally:
        if conn is not None:
            conn.close()


def tier_prefix_for_model(model: str) -> str:
    tier = FALLBACK_MODEL_TO_TIER[model]
    return "FALLBACK" if tier == "fallback" else tier.upper()


def configured_fallback_models(model: str) -> list[str]:
    configured = []
    model_key = ROUTE_TO_MODEL_KEY[model]
    for fallback_model in MODEL_FALLBACK_CHAINS.get(model, []):
        prefix = tier_prefix_for_model(fallback_model)
        if all(
            os.environ.get(var, "").strip()
            for var in (
                f"{prefix}_ANTHROPIC_API_BASE",
                f"{prefix}_ANTHROPIC_API_KEY",
                f"{prefix}_{model_key}_MODEL",
            )
        ):
            configured.append(fallback_model)
    return configured


def should_fallback(status: int, body: bytes) -> bool:
    if status >= 500 or status in RETRYABLE_STATUS_CODES:
        return True

    message = body.decode("utf-8", errors="ignore").lower()
    return any(keyword in message for keyword in RETRYABLE_ERROR_KEYWORDS)


def is_error_sse(headers: list[tuple[str, str]], body: bytes) -> bool:
    content_type = ""
    for key, value in headers:
        if key.lower() == "content-type":
            content_type = value.lower()
            break

    if "text/event-stream" not in content_type:
        return False

    text = body.decode("utf-8", errors="ignore").lstrip()
    if text.startswith("event: error"):
        return True
    return 'data: {"error":' in text or 'data: {\"error\":' in text


def extract_error_payload(body: bytes) -> dict | None:
    text = body.decode("utf-8", errors="ignore").strip()
    if not text:
        return None

    try:
        parsed = json.loads(text)
        if isinstance(parsed, dict):
            return parsed
    except json.JSONDecodeError:
        pass

    for line in text.splitlines():
        if not line.startswith("data: "):
            continue
        payload = line[6:].strip()
        if not payload or payload == "[DONE]":
            continue
        try:
            parsed = json.loads(payload)
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict):
            return parsed
    return None


def is_usage_limit_error(body: bytes) -> bool:
    payload = extract_error_payload(body)
    if isinstance(payload, dict):
        error = payload.get("error")
        if isinstance(error, dict):
            code = str(error.get("code", "")).strip()
            message = str(error.get("message", "")).lower()
            if code == "1308":
                return True
            if "usage limit reached" in message:
                return True
    text = body.decode("utf-8", errors="ignore").lower()
    return "usage limit reached" in text and "concurrent" not in text


def should_prefer_fallback(model: str) -> bool:
    until = PRIMARY_USAGE_LIMIT_UNTIL.get(model)
    if until is None:
        return False
    if until <= time.time():
        PRIMARY_USAGE_LIMIT_UNTIL.pop(model, None)
        return False
    return True


def mark_primary_usage_limit(model: str) -> None:
    PRIMARY_USAGE_LIMIT_UNTIL[model] = time.time() + PRIMARY_USAGE_LIMIT_COOLDOWN_SECONDS


def forward_headers_from_request(handler: BaseHTTPRequestHandler) -> dict[str, str]:
    filtered = {}
    for key, value in handler.headers.items():
        if key.lower() in {"host", "content-length", "connection"}:
            continue
        filtered[key] = value
    return filtered


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    ALLOWED_ORIGINS = [
        "http://192.168.5.214:4000",
        "http://localhost:4000",
        "http://192.168.5.214:3000",
        "http://localhost:3000",
    ]

    def _get_cors_headers(self) -> dict[str, str]:
        origin = self.headers.get("Origin", "")
        if origin in self.ALLOWED_ORIGINS:
            return {
                "Access-Control-Allow-Origin": origin,
                "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, PATCH, OPTIONS",
                "Access-Control-Allow-Headers": "Authorization, Content-Type, X-API-Key",
                "Access-Control-Allow-Credentials": "true",
            }
        return {}

    def _send_buffered_response(
        self,
        status: int,
        headers: list[tuple[str, str]],
        body: bytes,
    ) -> None:
        self.send_response(status)
        for key, value in headers:
            if key.lower() in {"transfer-encoding", "connection", "content-length"}:
                continue
            self.send_header(key, value)

        for key, value in self._get_cors_headers().items():
            self.send_header(key, value)

        self.send_header("Connection", "close")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)
            self.wfile.flush()

    def _copy_response(self, resp: HTTPResponse) -> None:
        try:
            self.send_response(resp.status)
            for key, value in resp.getheaders():
                if key.lower() in {"transfer-encoding", "connection", "content-length"}:
                    continue
                self.send_header(key, value)

            for key, value in self._get_cors_headers().items():
                self.send_header(key, value)

            self.send_header("Connection", "close")
            self.end_headers()

            while True:
                chunk = resp.read(8192)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        finally:
            close_response(resp)

    def _proxy_generic(self, body: bytes | None) -> None:
        headers = forward_headers_from_request(self)
        resp = upstream_request("litellm", 4000, self.command, self.path, body, headers)
        self._copy_response(resp)

    def _fallback_path(self, model: str, query: str) -> str:
        suffix = f"?{query}" if query else ""
        return f'/{FALLBACK_MODEL_TO_TIER[model]}/v1/messages{suffix}'

    def _request_via_fallback(
        self,
        model: str,
        payload: dict,
        headers: dict[str, str],
        query: str,
    ) -> tuple[HTTPResponse | None, tuple[int, list[tuple[str, str]], bytes] | None]:
        fallback_payload = dict(payload)
        fallback_payload["model"] = model
        fallback_body = json.dumps(fallback_payload).encode("utf-8")
        resp = upstream_request(
            "jdcloud-anthropic-shim",
            8081,
            "POST",
            self._fallback_path(model, query),
            fallback_body,
            headers,
        )
        if 200 <= resp.status < 300:
            return resp, None

        buffered = (resp.status, resp.getheaders(), resp.read())
        close_response(resp)
        return None, buffered

    def _buffer_response(
        self,
        resp: HTTPResponse,
    ) -> tuple[int, list[tuple[str, str]], bytes]:
        buffered = (resp.status, resp.getheaders(), resp.read())
        close_response(resp)
        return buffered

    def _request_primary(
        self,
        body: bytes,
        headers: dict[str, str],
    ) -> tuple[int, list[tuple[str, str]], bytes]:
        resp = upstream_request("litellm", 4000, "POST", self.path, body, headers)
        return self._buffer_response(resp)

    def do_POST(self) -> None:
        content_length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(content_length) if content_length else b""

        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/v1/messages":
            self._proxy_generic(body)
            return

        try:
            payload = json.loads(body.decode("utf-8"))
        except json.JSONDecodeError:
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"error":"invalid json"}')
            return

        model = payload.get("model")
        headers = forward_headers_from_request(self)

        if model in FALLBACK_MODEL_TO_TIER:
            resp = upstream_request(
                "jdcloud-anthropic-shim",
                8081,
                "POST",
                self._fallback_path(model, parsed.query),
                body,
                headers,
            )
            self._copy_response(resp)
            return

        if model not in MODEL_FALLBACK_CHAINS:
            self._proxy_generic(body)
            return

        configured_fallbacks = configured_fallback_models(model)

        attempt_order = list(configured_fallbacks)
        if should_prefer_fallback(model) and attempt_order:
            attempt_order.append(model)
        else:
            attempt_order = [model, *attempt_order]

        last_error: tuple[int, list[tuple[str, str]], bytes] | None = None
        for target_model in attempt_order:
            try:
                if target_model == model:
                    attempt = self._request_primary(body, headers)
                else:
                    fallback_resp, fallback_error = self._request_via_fallback(
                        target_model, payload, headers, parsed.query
                    )
                    if fallback_resp is not None:
                        attempt = self._buffer_response(fallback_resp)
                    elif fallback_error is not None:
                        attempt = fallback_error
                    else:
                        continue
            except (OSError, socket.timeout, TimeoutError, HTTPException):
                last_error = (
                    503,
                    [("Content-Type", "application/json")],
                    json.dumps({"error": f"{target_model} unavailable"}).encode("utf-8"),
                )
                continue

            if (
                target_model == model
                and is_usage_limit_error(attempt[2])
                and attempt[0] in {200, 429}
            ):
                mark_primary_usage_limit(model)

            if 200 <= attempt[0] < 300 and not is_error_sse(attempt[1], attempt[2]):
                self._send_buffered_response(*attempt)
                return

            last_error = attempt
            if not should_fallback(attempt[0], attempt[2]) and not is_usage_limit_error(attempt[2]):
                self._send_buffered_response(*attempt)
                return

        if last_error is None:
            self.send_error(502, "upstream unavailable")
            return
        self._send_buffered_response(*last_error)

    def do_GET(self) -> None:
        self._proxy_generic(None)

    def do_PUT(self) -> None:
        self._proxy_generic(None)

    def do_DELETE(self) -> None:
        self._proxy_generic(None)

    def do_PATCH(self) -> None:
        self._proxy_generic(None)

    def do_OPTIONS(self) -> None:
        cors_headers = self._get_cors_headers()
        if cors_headers:
            self.send_response(200)
            for key, value in cors_headers.items():
                self.send_header(key, value)
            self.send_header("Content-Length", "0")
            self.end_headers()
        else:
            self.send_response(403)
            self.end_headers()

    def log_message(self, fmt: str, *args) -> None:
        return


if __name__ == "__main__":
    port = int(os.environ.get("ANTHROPIC_ROUTER_PORT", "4001"))
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    server.serve_forever()
