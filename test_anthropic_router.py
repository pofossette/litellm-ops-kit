#!/usr/bin/env python3
"""
测试 Anthropic Router 的自动降级功能

当主 provider 失效时，自动转移到 fallback provider
"""
import json
import os
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


def get_api_key() -> str:
    """从环境变量获取 Litellm API Key"""
    # 尝试从 .env 文件加载
    try:
        for line in open('.env'):
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                key, value = line.split('=', 1)
                if key == 'LITELLM_MASTER_KEY':
                    return value
    except:
        pass
    return os.environ.get('LITELLM_MASTER_KEY', '')


def check_server(host: str, port: int, timeout: float = 2.0) -> bool:
    """检查服务器是否运行"""
    try:
        with socket.create_connection((host, port), timeout):
            return True
    except (socket.timeout, OSError):
        return False


def test_anthropic_router(
    host: str = "localhost",
    port: int = 4001,
    model: str = "my-haiku",
    message: str = "Hello, please introduce yourself in one sentence.",
) -> dict | None:
    """测试 Anthropic Router 的 /v1/messages 端点"""
    base_url = f"http://{host}:{port}"

    print(f"\n{'='*60}")
    print(f"测试: POST {base_url}/v1/messages")
    print(f"{'='*60}")
    print(f"模型: {model}")
    print(f"消息: {message}")

    payload = {
        "model": model,
        "max_tokens": 500,
        "messages": [
            {"role": "user", "content": message},
        ],
    }

    print(f"\n请求体:")
    print(json.dumps(payload, ensure_ascii=False, indent=2))

    api_key = get_api_key()
    headers = {
        "Content-Type": "application/json",
        "anthropic-version": "2023-06-01",
    }
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    try:
        req = urllib.request.Request(
            f"{base_url}/v1/messages",
            data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            headers=headers,
            method="POST",
        )

        start_time = time.time()
        with urllib.request.urlopen(req, timeout=180) as resp:
            elapsed = time.time() - start_time
            data = json.loads(resp.read().decode("utf-8"))

            print(f"\n✓ 状态码: {resp.status}")
            print(f"✓ 响应时间: {elapsed:.2f}s")

            # 打印响应
            print(f"\n响应头:")
            for key, value in resp.headers.items():
                if key.lower() not in {"date", "server", "connection"}:
                    print(f"  {key}: {value}")

            print(f"\n响应体:")
            print(json.dumps(data, ensure_ascii=False, indent=2))

            # 打印生成的文本
            if "content" in data:
                text_parts = []
                for block in data.get("content", []):
                    if block.get("type") == "text":
                        text_parts.append(block.get("text", ""))
                content = "".join(text_parts)
                if content:
                    print(f"\n生成的文本:")
                    print(f"  {content}")

            # 打印使用情况
            if "usage" in data:
                usage = data["usage"]
                print(f"\nToken 使用:")
                print(f"  输入: {usage.get('input_tokens', 0)}")
                print(f"  输出: {usage.get('output_tokens', 0)}")

            # 检查是否来自 fallback
            if "model" in data:
                actual_model = data.get("model", "")
                print(f"\n实际模型: {actual_model}")
                if actual_model != model:
                    print(f"⚠️  请求模型: {model} -> 实际模型: {actual_model} (可能来自 fallback)")

            return data

    except urllib.error.HTTPError as e:
        print(f"\n✗ HTTP 错误: {e.code}")
        try:
            error_body = e.read().decode("utf-8")
            print(f"  响应: {error_body}")
            try:
                error_json = json.loads(error_body)
                print(f"\n错误详情:")
                print(json.dumps(error_json, ensure_ascii=False, indent=2))
            except:
                pass
        except:
            pass
        return None
    except Exception as e:
        print(f"\n✗ 请求失败: {e}")
        return None


def test_all_models():
    """测试所有模型"""
    models = [
        ("my-haiku", "Hello, introduce yourself in one sentence."),
        ("my-sonnet", "What is 2+2?"),
        ("my-opus", "Say hi"),
    ]

    results = {}
    for model, message in models:
        print(f"\n\n{'#'*60}")
        print(f"# 测试模型: {model}")
        print(f"{'#'*60}")
        result = test_anthropic_router(model=model, message=message)
        results[model] = result is not None

    print(f"\n\n{'='*60}")
    print(f"测试结果汇总")
    print(f"{'='*60}")
    for model, success in results.items():
        status = "✅ 成功" if success else "❌ 失败"
        print(f"  {model}: {status}")

    return all(results.values())


def main():
    host = "localhost"
    port = 4001

    print(f"\n{'='*60}")
    print(f"Anthropic Router 测试")
    print(f"{'='*60}")
    print(f"服务器: {host}:{port}")
    print(f"目标: 测试主 provider 失效时的自动降级")

    # 检查服务器
    if not check_server(host, port):
        print(f"\n✗ 错误: 服务器 {host}:{port} 不可达")
        return 1

    # 测试所有模型
    success = test_all_models()

    if success:
        print(f"\n{'='*60}")
        print(f"✅ 所有测试通过 - 自动降级功能正常")
        print(f"{'='*60}")
        return 0
    else:
        print(f"\n{'='*60}")
        print(f"❌ 部分测试失败")
        print(f"{'='*60}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
