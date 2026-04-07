#!/usr/bin/env python3
import json
import os
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def tier_config():
    return {
        "main": {
            "api_base": os.environ.get("MAIN_ANTHROPIC_API_BASE", "").rstrip("/"),
            "api_key": os.environ.get("MAIN_ANTHROPIC_API_KEY", ""),
            "aliases": {
                "my-opus": os.environ.get("MAIN_OPUS_MODEL", ""),
                "my-sonnet": os.environ.get("MAIN_SONNET_MODEL", ""),
                "my-haiku": os.environ.get("MAIN_HAIKU_MODEL", ""),
            },
        },
        "fallback": {
            "api_base": os.environ.get("FALLBACK_ANTHROPIC_API_BASE", "").rstrip("/"),
            "api_key": os.environ.get("FALLBACK_ANTHROPIC_API_KEY", ""),
            "aliases": {
                "my-opus-fallback": os.environ.get("FALLBACK_OPUS_MODEL", ""),
                "my-sonnet-fallback": os.environ.get("FALLBACK_SONNET_MODEL", ""),
                "my-haiku-fallback": os.environ.get("FALLBACK_HAIKU_MODEL", ""),
            },
        },
        "fallback2": {
            "api_base": os.environ.get("FALLBACK2_ANTHROPIC_API_BASE", "").rstrip("/"),
            "api_key": os.environ.get("FALLBACK2_ANTHROPIC_API_KEY", ""),
            "aliases": {
                "my-opus-fallback-2": os.environ.get("FALLBACK2_OPUS_MODEL", ""),
                "my-sonnet-fallback-2": os.environ.get("FALLBACK2_SONNET_MODEL", ""),
                "my-haiku-fallback-2": os.environ.get("FALLBACK2_HAIKU_MODEL", ""),
            },
        },
        "fallback3": {
            "api_base": os.environ.get("FALLBACK3_ANTHROPIC_API_BASE", "").rstrip("/"),
            "api_key": os.environ.get("FALLBACK3_ANTHROPIC_API_KEY", ""),
            "aliases": {
                "my-opus-fallback-3": os.environ.get("FALLBACK3_OPUS_MODEL", ""),
                "my-sonnet-fallback-3": os.environ.get("FALLBACK3_SONNET_MODEL", ""),
                "my-haiku-fallback-3": os.environ.get("FALLBACK3_HAIKU_MODEL", ""),
            },
        },
    }


def normalize_model(tier: str, incoming_model: str) -> str:
    config = tier_config()[tier]
    mapped = config["aliases"].get(incoming_model)
    if mapped:
        return mapped
    if isinstance(incoming_model, str) and "/" in incoming_model:
        return incoming_model.split("/", 1)[1]
    return incoming_model


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        path_parts = [p for p in parsed.path.split("/") if p]
        if len(path_parts) < 3 or path_parts[1] != "v1" or path_parts[2] != "messages":
            self._send_json(404, {"error": "not found"})
            return

        tier = path_parts[0]
        config = tier_config().get(tier)
        if not config or not config["api_base"] or not config["api_key"]:
            self._send_json(500, {"error": f"tier not configured: {tier}"})
            return

        content_length = int(self.headers.get("Content-Length", "0"))
        raw_body = self.rfile.read(content_length)
        try:
            body = json.loads(raw_body.decode("utf-8"))
        except json.JSONDecodeError:
            self._send_json(400, {"error": "invalid json"})
            return

        incoming_model = body.get("model")
        body["model"] = normalize_model(tier, incoming_model)

        upstream_url = f'{config["api_base"]}/v1/messages'
        if parsed.query:
            upstream_url = f"{upstream_url}?{parsed.query}"

        forward_headers = {}
        for key, value in self.headers.items():
            lower = key.lower()
            if lower in {"host", "content-length", "x-api-key", "authorization", "connection"}:
                continue
            forward_headers[key] = value

        forward_headers["x-api-key"] = config["api_key"]
        forward_headers.setdefault("content-type", "application/json")
        forward_headers.setdefault("anthropic-version", "2023-06-01")

        payload = json.dumps(body).encode("utf-8")
        req = urllib.request.Request(
            upstream_url,
            data=payload,
            headers=forward_headers,
            method="POST",
        )

        try:
            with urllib.request.urlopen(req, timeout=180) as resp:
                response_body = resp.read()
                self.send_response(resp.status)
                for key, value in resp.headers.items():
                    if key.lower() in {"transfer-encoding", "connection", "content-encoding", "content-length"}:
                        continue
                    self.send_header(key, value)
                self.send_header("Content-Length", str(len(response_body)))
                self.end_headers()
                self.wfile.write(response_body)
        except urllib.error.HTTPError as exc:
            response_body = exc.read()
            self.send_response(exc.code)
            for key, value in exc.headers.items():
                if key.lower() in {"transfer-encoding", "connection", "content-encoding", "content-length"}:
                    continue
                self.send_header(key, value)
            self.send_header("Content-Length", str(len(response_body)))
            self.end_headers()
            self.wfile.write(response_body)

    def log_message(self, fmt: str, *args) -> None:
        return


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", 8081), Handler)
    server.serve_forever()
