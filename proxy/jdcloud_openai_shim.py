#!/usr/bin/env python3
"""
OpenAI-to-Anthropic Protocol Shim for JDCloud.

Accepts OpenAI-format requests (/v1/chat/completions) and converts them
to Anthropic format, then forwards to JDCloud's Anthropic endpoint.
"""
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def tier_config():
    """Get configuration for each tier from environment variables."""
    return {
        "main": {
            "api_base": os.environ.get("MAIN_ANTHROPIC_API_BASE", "").rstrip("/"),
            "api_key": os.environ.get("MAIN_ANTHROPIC_API_KEY", ""),
            "aliases": {
                "openai-high": os.environ.get("MAIN_OPUS_MODEL", ""),
                "openai-medium": os.environ.get("MAIN_SONNET_MODEL", ""),
                "openai-low": os.environ.get("MAIN_HAIKU_MODEL", ""),
            },
        },
        "fallback": {
            "api_base": os.environ.get("FALLBACK_ANTHROPIC_API_BASE", "").rstrip("/"),
            "api_key": os.environ.get("FALLBACK_ANTHROPIC_API_KEY", ""),
            "aliases": {
                "openai-high-fallback": os.environ.get("FALLBACK_OPUS_MODEL", ""),
                "openai-medium-fallback": os.environ.get("FALLBACK_SONNET_MODEL", ""),
                "openai-low-fallback": os.environ.get("FALLBACK_HAIKU_MODEL", ""),
            },
        },
        "fallback2": {
            "api_base": os.environ.get("FALLBACK2_ANTHROPIC_API_BASE", "").rstrip("/"),
            "api_key": os.environ.get("FALLBACK2_ANTHROPIC_API_KEY", ""),
            "aliases": {
                "openai-high-fallback-2": os.environ.get("FALLBACK2_OPUS_MODEL", ""),
                "openai-medium-fallback-2": os.environ.get("FALLBACK2_SONNET_MODEL", ""),
                "openai-low-fallback-2": os.environ.get("FALLBACK2_HAIKU_MODEL", ""),
            },
        },
        "fallback3": {
            "api_base": os.environ.get("FALLBACK3_ANTHROPIC_API_BASE", "").rstrip("/"),
            "api_key": os.environ.get("FALLBACK3_ANTHROPIC_API_KEY", ""),
            "aliases": {
                "openai-high-fallback-3": os.environ.get("FALLBACK3_OPUS_MODEL", ""),
                "openai-medium-fallback-3": os.environ.get("FALLBACK3_SONNET_MODEL", ""),
                "openai-low-fallback-3": os.environ.get("FALLBACK3_HAIKU_MODEL", ""),
            },
        },
    }


def normalize_model(tier: str, incoming_model: str) -> str:
    """Map model alias to actual model name."""
    config = tier_config()[tier]
    mapped = config["aliases"].get(incoming_model)
    if mapped:
        return mapped
    if isinstance(incoming_model, str) and "/" in incoming_model:
        return incoming_model.split("/", 1)[1]
    return incoming_model


def openai_to_anthropic_messages(openai_messages: list) -> tuple[str, list]:
    """
    Convert OpenAI messages format to Anthropic format.

    Returns: (system_prompt, anthropic_messages)
    """
    system_prompt = ""
    anthropic_messages = []

    for msg in openai_messages:
        role = msg.get("role", "")
        content = msg.get("content", "")

        if role == "system":
            system_prompt = content
        elif role == "user":
            anthropic_messages.append({"role": "user", "content": content})
        elif role == "assistant":
            anthropic_messages.append({"role": "assistant", "content": content})

    return system_prompt, anthropic_messages


def anthropic_to_openai_response(anthropic_response: dict, model: str) -> dict:
    """Convert Anthropic response to OpenAI format."""
    # Extract text content
    text_content = ""
    for block in anthropic_response.get("content", []):
        if block.get("type") == "text":
            text_content += block.get("text", "")

    # Build OpenAI response
    return {
        "id": anthropic_response.get("id", f"chatcmpl-{int(time.time())}"),
        "object": "chat.completion",
        "created": int(time.time()),
        "model": model,
        "choices": [
            {
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": text_content,
                },
                "finish_reason": "stop" if anthropic_response.get("stop_reason") == "end_turn" else anthropic_response.get("stop_reason"),
            }
        ],
        "usage": {
            "prompt_tokens": anthropic_response.get("usage", {}).get("input_tokens", 0),
            "completion_tokens": anthropic_response.get("usage", {}).get("output_tokens", 0),
            "total_tokens": anthropic_response.get("usage", {}).get("input_tokens", 0)
                          + anthropic_response.get("usage", {}).get("output_tokens", 0),
        },
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        path_parts = [p for p in parsed.path.split("/") if p]

        # Handle /v1/chat/completions endpoint
        if len(path_parts) < 3 or path_parts[-2] != "v1" or path_parts[-1] != "chat" or path_parts[-1] == "chat":
            # Actually we expect: /{tier}/v1/chat/completions or /v1/chat/completions
            pass

        # Extract tier from path: /{tier}/v1/chat/completions or fallback if no tier
        if len(path_parts) >= 4 and path_parts[1] == "v1":
            # Path: /{tier}/v1/chat/completions
            tier = path_parts[0]
            endpoint = "/".join(path_parts[1:])
        elif len(path_parts) >= 3 and path_parts[0] == "v1":
            # Path: /v1/chat/completions (no tier, use fallback)
            tier = "fallback"
            endpoint = "/".join(path_parts)
        else:
            tier = path_parts[0] if path_parts else "fallback"
            endpoint = "/".join(path_parts[1:]) if len(path_parts) > 1 else ""

        if "chat/completions" not in endpoint:
            self._send_json(404, {"error": "not found, expected /v1/chat/completions"})
            return

        config = tier_config().get(tier)
        if not config or not config["api_base"] or not config["api_key"]:
            self._send_json(500, {"error": f"tier not configured: {tier}"})
            return

        # Read and parse OpenAI request
        content_length = int(self.headers.get("Content-Length", "0"))
        raw_body = self.rfile.read(content_length)
        try:
            openai_body = json.loads(raw_body.decode("utf-8"))
        except json.JSONDecodeError:
            self._send_json(400, {"error": "invalid json"})
            return

        # Convert OpenAI to Anthropic format
        openai_model = openai_body.get("model", "")
        anthropic_model = normalize_model(tier, openai_model)
        system_prompt, anthropic_messages = openai_to_anthropic_messages(
            openai_body.get("messages", [])
        )

        anthropic_body = {
            "model": anthropic_model,
            "messages": anthropic_messages,
            "max_tokens": openai_body.get("max_tokens", 4096),
        }

        if system_prompt:
            anthropic_body["system"] = system_prompt

        # Handle stream flag
        stream = openai_body.get("stream", False)
        if stream:
            anthropic_body["stream"] = True

        # Inject thinking for GLM-5 models
        model_upper = anthropic_model.upper() if anthropic_model else ""
        if model_upper.startswith("GLM-5"):
            if "thinking" not in anthropic_body:
                anthropic_body["thinking"] = {"type": "enabled"}
                print(f"[DEBUG] JDCloud OpenAI Shim: Injected thinking for {anthropic_model}")

        # Forward to Anthropic endpoint
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
        forward_headers["content-type"] = "application/json"
        forward_headers["anthropic-version"] = "2023-06-01"

        payload = json.dumps(anthropic_body).encode("utf-8")
        req = urllib.request.Request(
            upstream_url,
            data=payload,
            headers=forward_headers,
            method="POST",
        )

        try:
            with urllib.request.urlopen(req, timeout=180) as resp:
                response_body = resp.read()

                if stream:
                    # For streaming, just forward as-is (SSE format)
                    self.send_response(resp.status)
                    for key, value in resp.headers.items():
                        if key.lower() in {"transfer-encoding", "connection", "content-encoding", "content-length"}:
                            continue
                        self.send_header(key, value)
                    self.send_header("Content-Length", str(len(response_body)))
                    self.end_headers()
                    self.wfile.write(response_body)
                else:
                    # Convert Anthropic response to OpenAI format
                    anthropic_response = json.loads(response_body.decode("utf-8"))
                    openai_response = anthropic_to_openai_response(anthropic_response, openai_model)
                    openai_body_bytes = json.dumps(openai_response, ensure_ascii=False).encode("utf-8")

                    self.send_response(resp.status)
                    for key, value in resp.headers.items():
                        if key.lower() in {"transfer-encoding", "connection", "content-encoding", "content-length"}:
                            continue
                        self.send_header(key, value)
                    self.send_header("Content-Length", str(len(openai_body_bytes)))
                    self.end_headers()
                    self.wfile.write(openai_body_bytes)

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

    def do_GET(self) -> None:
        """Handle GET requests for /v1/models endpoint."""
        parsed = urllib.parse.urlparse(self.path)
        path_parts = [p for p in parsed.path.split("/") if p]

        if path_parts[-1] == "models" or path_parts[-2:] == ["v1", "models"]:
            # Return available models
            models = []
            for tier, cfg in tier_config().items():
                if cfg["api_base"] and cfg["api_key"]:
                    for alias in cfg["aliases"].keys():
                        models.append({
                            "id": alias,
                            "object": "model",
                            "created": 1677610602,
                            "owned_by": "jdcloud",
                        })

            response = {
                "object": "list",
                "data": models,
            }
            self._send_json(200, response)
        else:
            self._send_json(404, {"error": "not found"})

    def log_message(self, fmt: str, *args) -> None:
        return


if __name__ == "__main__":
    port = int(os.environ.get("JDCLOUD_OPENAI_SHIM_PORT", "8082"))
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"JDCloud OpenAI Shim listening on port {port}")
    server.serve_forever()