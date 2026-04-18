#!/usr/bin/env python3
"""
Haiku API Proxy - Converts x-api-key header to Authorization: Bearer
For haiku provider that requires Bearer authentication instead of x-api-key
"""
from flask import Flask, request, Response
import requests
import os

app = Flask(__name__)

# Haiku provider configuration
HAIKU_API_BASE = os.environ.get('HAIKU_API_BASE', 'https://zhenze-huhehaote.cmecloud.cn/api/coding')
HAIKU_API_KEY = os.environ.get('HAIKU_API_KEY', '40WYEioWUDN7JvE26uu3owMgsf7mpX7y5bdJcPj9Ox4')
HAIKU_MODEL = os.environ.get('HAIKU_MODEL', 'cm-code-latest')

@app.route('/v1/messages', methods=['POST'])
def proxy_messages():
    """Proxy requests to haiku provider with Bearer authentication"""
    # Get the original request data
    request_data = request.get_json()
    request_headers = dict(request.headers)

    # Debug logging - use print for stdout
    model_name = request_data.get('model')
    print(f"[HAIKU-PROXY] Received request: model={model_name}", flush=True)
    print(f"[HAIKU-PROXY] Full request data: {request_data}", flush=True)
    print(f"[HAIKU-PROXY] Headers received: {list(request_headers.keys())}", flush=True)

    # Expand os.environ/ references in model name
    if model_name and model_name.startswith('os.environ/'):
        var_name = model_name.split('/', 1)[1]
        model_name = os.environ.get(var_name, HAIKU_MODEL)
        request_data['model'] = model_name
        print(f"[HAIKU-PROXY] Expanded model to: {model_name}", flush=True)

    # Extract x-api-key (litellm sends this)
    # Use haiku API key from environment if not provided
    api_key = request_headers.get('x-api-key', HAIKU_API_KEY)

    # Remove x-api-key and other headers that shouldn't be forwarded
    headers_to_remove = ['x-api-key', 'host', 'content-length', 'transfer-encoding']
    forward_headers = {k: v for k, v in request_headers.items()
                       if k.lower() not in headers_to_remove}

    # Add Authorization header with Bearer token
    forward_headers['Authorization'] = f'Bearer {api_key}'

    app.logger.info(f"Forwarding to {HAIKU_API_BASE}/v1/messages with Bearer token")

    # Forward request to haiku provider
    url = f"{HAIKU_API_BASE}/v1/messages"
    try:
        response = requests.post(
            url,
            json=request_data,
            headers=forward_headers,
            timeout=120
        )

        app.logger.info(f"Provider response status: {response.status_code}")
        if response.status_code != 200:
            app.logger.error(f"Provider error response: {response.text[:200]}")

        # Return the response
        excluded_headers = ['content-encoding', 'content-length', 'transfer-encoding', 'connection']
        response_headers = [(name, value) for name, value in response.headers.items()
                           if name.lower() not in excluded_headers]

        return Response(
            response.content,
            status=response.status_code,
            headers=response_headers
        )
    except requests.RequestException as e:
        app.logger.error(f"Proxy error: {str(e)}")
        return Response(
            f'{{"error": "Proxy error: {str(e)}"}}',
            status=502,
            mimetype='application/json'
        )

@app.route('/health', methods=['GET'])
def health():
    """Health check endpoint"""
    return {'status': 'healthy', 'provider': 'haiku-proxy'}

if __name__ == '__main__':
    port = int(os.environ.get('PORT', 8765))
    app.run(host='0.0.0.0', port=port)
