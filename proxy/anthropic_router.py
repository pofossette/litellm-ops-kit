#!/usr/bin/env python3
import json
import os
import socket
import urllib.parse
from http.client import HTTPConnection, HTTPResponse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


PRIMARY_TO_FALLBACK = {
    "my-opus": "my-opus-fallback",
    "my-sonnet": "my-sonnet-fallback",
    "my-haiku": "my-haiku-fallback",
}

FALLBACK_MODELS = set(PRIMARY_TO_FALLBACK.values())


def upstream_request(
    host: str,
    port: int,
    method: str,
    path: str,
    body: bytes | None,
    headers: dict[str, str],
) -> HTTPResponse:
    conn = HTTPConnection(host, port, timeout=180)
    conn.request(method, path, body=body, headers=headers)
    return conn.getresponse()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _copy_response(self, resp: HTTPResponse) -> None:
        self.send_response(resp.status)
        for key, value in resp.getheaders():
            if key.lower() in {"transfer-encoding", "connection", "content-length"}:
                continue
            self.send_header(key, value)
        self.send_header("Connection", "close")
        self.end_headers()

        while True:
            chunk = resp.read(8192)
            if not chunk:
                break
            self.wfile.write(chunk)
            self.wfile.flush()

    def _proxy_generic(self, body: bytes | None) -> None:
        headers = {k: v for k, v in self.headers.items() if k.lower() != "host"}
        resp = upstream_request("litellm", 4000, self.command, self.path, body, headers)
        self._copy_response(resp)

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
        if model in FALLBACK_MODELS:
            headers = {k: v for k, v in self.headers.items() if k.lower() != "host"}
            resp = upstream_request(
                "jdcloud-anthropic-shim",
                8081,
                "POST",
                "/fallback/v1/messages" + (f"?{parsed.query}" if parsed.query else ""),
                body,
                headers,
            )
            self._copy_response(resp)
            return

        if model not in PRIMARY_TO_FALLBACK:
            self._proxy_generic(body)
            return

        headers = {k: v for k, v in self.headers.items() if k.lower() != "host"}
        primary_resp = upstream_request("litellm", 4000, "POST", self.path, body, headers)
        if 200 <= primary_resp.status < 300:
            self._copy_response(primary_resp)
            return

        fallback_payload = dict(payload)
        fallback_payload["model"] = PRIMARY_TO_FALLBACK[model]
        fallback_body = json.dumps(fallback_payload).encode("utf-8")
        fallback_resp = upstream_request(
            "jdcloud-anthropic-shim",
            8081,
            "POST",
            "/fallback/v1/messages" + (f"?{parsed.query}" if parsed.query else ""),
            fallback_body,
            headers,
        )
        self._copy_response(fallback_resp)

    def do_GET(self) -> None:
        self._proxy_generic(None)

    def do_PUT(self) -> None:
        self._proxy_generic(None)

    def do_DELETE(self) -> None:
        self._proxy_generic(None)

    def do_PATCH(self) -> None:
        self._proxy_generic(None)

    def log_message(self, fmt: str, *args) -> None:
        return


if __name__ == "__main__":
    port = int(os.environ.get("ANTHROPIC_ROUTER_PORT", "4001"))
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    server.serve_forever()
