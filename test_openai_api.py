#!/usr/bin/env python3
"""
测试 OpenAI 兼容协议接入脚本

用法:
    python test_openai_api.py                    # 测试基础请求
    python test_openai_api.py --stream           # 测试流式请求
    python test_openai_api.py --models           # 列出可用模型
    python test_openai_api.py --tier fallback    # 测试指定 tier
"""
import argparse
import json
import os
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


def get_base_url(tier: str = "main") -> str:
    """获取基础 URL，根据 tier 决定路径"""
    host = os.environ.get("JDCLOUD_OPENAI_SHIM_HOST", "localhost")
    port = int(os.environ.get("JDCLOUD_OPENAI_SHIM_PORT", "8082"))

    if tier == "main":
        return f"http://{host}:{port}/v1"
    else:
        return f"http://{host}:{port}/{tier}/v1"


def check_server(host: str, port: int, timeout: float = 2.0) -> bool:
    """检查服务器是否运行"""
    try:
        with socket.create_connection((host, port), timeout):
            return True
    except (socket.timeout, OSError):
        return False


def test_models_endpoint(base_url: str) -> dict | None:
    """测试 /v1/models 端点"""
    print(f"\n{'='*60}")
    print(f"测试: GET {base_url}/models")
    print(f"{'='*60}")

    try:
        req = urllib.request.Request(f"{base_url}/models", method="GET")
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            print(f"✓ 状态码: {resp.status}")

            print("\n可用模型:")
            for model in data.get("data", []):
                print(f"  - {model.get('id')} (owned_by: {model.get('owned_by')})")

            return data
    except urllib.error.HTTPError as e:
        print(f"✗ HTTP 错误: {e.code}")
        try:
            print(f"  响应: {e.read().decode('utf-8')}")
        except:
            pass
        return None
    except Exception as e:
        print(f"✗ 请求失败: {e}")
        return None


def test_chat_completion(
    base_url: str,
    model: str = "openai-medium",
    message: str = "你好，请用一句话介绍你自己",
    stream: bool = False,
) -> dict | None:
    """测试 /v1/chat/completions 端点"""
    print(f"\n{'='*60}")
    print(f"测试: POST {base_url}/chat/completions")
    print(f"{'='*60}")
    print(f"模型: {model}")
    print(f"消息: {message}")
    print(f"流式: {'是' if stream else '否'}")

    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": "你是一个有用的助手。"},
            {"role": "user", "content": message},
        ],
        "max_tokens": 500,
        "stream": stream,
    }

    print(f"\n请求体:")
    print(json.dumps(payload, ensure_ascii=False, indent=2))

    try:
        req = urllib.request.Request(
            f"{base_url}/chat/completions",
            data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )

        start_time = time.time()
        with urllib.request.urlopen(req, timeout=180) as resp:
            elapsed = time.time() - start_time

            if stream:
                print(f"\n✓ 状态码: {resp.status}")
                print(f"✓ 响应时间: {elapsed:.2f}s")
                print(f"\n流式响应:")

                buffer = b""
                for line in resp:
                    buffer += line
                    text = line.decode("utf-8", errors="ignore")
                    if text.strip():
                        print(f"  {text.strip()}")
                return {"streamed": True, "bytes": len(buffer)}
            else:
                data = json.loads(resp.read().decode("utf-8"))
                print(f"\n✓ 状态码: {resp.status}")
                print(f"✓ 响应时间: {elapsed:.2f}s")

                # 打印响应
                print(f"\n响应头:")
                for key, value in resp.headers.items():
                    if key.lower() not in {"date", "server"}:
                        print(f"  {key}: {value}")

                print(f"\n响应体:")
                print(json.dumps(data, ensure_ascii=False, indent=2))

                # 打印生成的文本
                if "choices" in data and data["choices"]:
                    content = data["choices"][0].get("message", {}).get("content", "")
                    print(f"\n生成的文本:")
                    print(f"  {content}")

                # 打印使用情况
                if "usage" in data:
                    usage = data["usage"]
                    print(f"\nToken 使用:")
                    print(f"  输入: {usage.get('prompt_tokens', 0)}")
                    print(f"  输出: {usage.get('completion_tokens', 0)}")
                    print(f"  总计: {usage.get('total_tokens', 0)}")

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


def main():
    parser = argparse.ArgumentParser(
        description="测试 OpenAI 兼容协议接入",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  python test_openai_api.py                    # 测试基础请求
  python test_openai_api.py --stream           # 测试流式请求
  python test_openai_api.py --models           # 列出可用模型
  python test_openai_api.py --tier fallback    # 测试指定 tier
  python test_openai_api.py --model openai-high --message "写一首诗"
        """,
    )
    parser.add_argument("--tier", default="main", choices=["main", "fallback", "fallback2", "fallback3"], help="指定 tier")
    parser.add_argument("--model", default="openai-medium", help="模型名称 (默认: openai-medium)")
    parser.add_argument("--message", default="你好，请用一句话介绍你自己", help="测试消息")
    parser.add_argument("--stream", action="store_true", help="测试流式响应")
    parser.add_argument("--models", action="store_true", help="列出可用模型")
    parser.add_argument("--host", default=None, help="服务器地址 (默认: 从环境变量读取)")
    parser.add_argument("--port", type=int, default=None, help="服务器端口 (默认: 从环境变量读取)")

    args = parser.parse_args()

    # 覆盖环境变量
    if args.host:
        os.environ["JDCLOUD_OPENAI_SHIM_HOST"] = args.host
    if args.port:
        os.environ["JDCLOUD_OPENAI_SHIM_PORT"] = str(args.port)

    host = os.environ.get("JDCLOUD_OPENAI_SHIM_HOST", "localhost")
    port = int(os.environ.get("JDCLOUD_OPENAI_SHIM_PORT", "8082"))

    print(f"\n{'='*60}")
    print(f"OpenAI 兼容协议测试")
    print(f"{'='*60}")
    print(f"服务器: {host}:{port}")
    print(f"Tier: {args.tier}")

    # 检查服务器
    if not check_server(host, port):
        print(f"\n✗ 错误: 服务器 {host}:{port} 不可达")
        print(f"\n提示:")
        print(f"  1. 确保 jdcloud_openai_shim.py 正在运行")
        print(f"  2. 检查端口是否正确 (默认: 8082)")
        print(f"  3. 使用 --host 和 --port 指定正确的地址")
        return 1

    base_url = get_base_url(args.tier)
    print(f"基础 URL: {base_url}")

    # 测试 /models 端点
    if args.models:
        result = test_models_endpoint(base_url)
        if result is None:
            return 1
        return 0

    # 测试 chat completion
    result = test_chat_completion(
        base_url=base_url,
        model=args.model,
        message=args.message,
        stream=args.stream,
    )

    if result is None:
        return 1

    print(f"\n{'='*60}")
    print(f"✓ 测试完成")
    print(f"{'='*60}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
