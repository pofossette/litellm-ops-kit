#!/usr/bin/env python3
"""
Patch LiteLLM Anthropic passthrough auth handling.

LiteLLM forwards inbound client headers to the upstream Anthropic-compatible
provider. When the gateway itself is authenticated with `x-api-key`, that
header can leak upstream and override the provider API key. JD Cloud then
rejects the request because it receives the LiteLLM master key instead of the
JD Cloud API key.
"""


def apply_patch():
    from litellm.llms.custom_httpx import llm_http_handler
    from litellm.llms.anthropic.experimental_pass_through.messages import transformation
    from litellm.llms.anthropic.experimental_pass_through.messages import handler as messages_handler

    handler_file = llm_http_handler.__file__
    with open(handler_file, "r") as f:
      content = f.read()

    patch_marker = "# Strip inbound gateway auth headers so provider auth wins"
    if patch_marker in content:
        print("Patch already applied!")
        return True

    old_code = '''        merged_headers = {}
        if forwarded_headers:
            merged_headers.update(forwarded_headers)
        if extra_headers_from_kwargs:
            merged_headers.update(extra_headers_from_kwargs)
        if provider_specific_headers:
            merged_headers.update(provider_specific_headers)
        (
            headers,
            api_base,
        ) = anthropic_messages_provider_config.validate_anthropic_messages_environment('''

    new_code = '''        merged_headers = {}
        if forwarded_headers:
            merged_headers.update(forwarded_headers)
        if extra_headers_from_kwargs:
            merged_headers.update(extra_headers_from_kwargs)
        if provider_specific_headers:
            merged_headers.update(provider_specific_headers)
        # Strip inbound gateway auth headers so provider auth wins
        merged_headers.pop("x-api-key", None)
        merged_headers.pop("authorization", None)
        (
            headers,
            api_base,
        ) = anthropic_messages_provider_config.validate_anthropic_messages_environment('''

    new_content = content.replace(old_code, new_code, 1)
    if new_content == content:
        print("Warning: Pattern not found, patch may not be needed!")
    else:
        with open(handler_file, "w") as f:
            f.write(new_content)
        print("Auth header patch applied successfully!")

    transformation_file = transformation.__file__
    with open(transformation_file, "r") as f:
        transformation_content = f.read()

    model_patch_marker = "# Use the provider deployment model instead of the alias model group"
    if model_patch_marker in transformation_content:
        print("Model alias patch already applied!")
        return True

    old_model_code = '''        ####### get required params for all anthropic messages requests ######
        verbose_logger.debug(f"TRANSFORMATION DEBUG - Messages: {messages}")
        anthropic_messages_request: AnthropicMessagesRequest = AnthropicMessagesRequest(
            messages=messages,
            max_tokens=max_tokens,
            model=model,
            **anthropic_messages_optional_request_params,
        )
        return dict(anthropic_messages_request)'''

    new_model_code = '''        ####### get required params for all anthropic messages requests ######
        verbose_logger.debug(f"TRANSFORMATION DEBUG - Messages: {messages}")
        provider_model = model
        deployment_model = litellm_params.get("model")
        if isinstance(deployment_model, str) and deployment_model:
            # Use the provider deployment model instead of the alias model group
            provider_model = deployment_model.split("/", 1)[-1]
        anthropic_messages_request: AnthropicMessagesRequest = AnthropicMessagesRequest(
            messages=messages,
            max_tokens=max_tokens,
            model=provider_model,
            **anthropic_messages_optional_request_params,
        )
        return dict(anthropic_messages_request)'''

    patched_transformation_content = transformation_content.replace(
        old_model_code, new_model_code, 1
    )
    if patched_transformation_content == transformation_content:
        print("Warning: Model patch pattern not found, patch may not be needed!")
        return False

    with open(transformation_file, "w") as f:
        f.write(patched_transformation_content)

    messages_handler_file = messages_handler.__file__
    with open(messages_handler_file, "r") as f:
        messages_handler_content = f.read()

    handler_debug_marker = "# JD handler debug logging"
    if handler_debug_marker not in messages_handler_content:
        old_handler_code = '''    litellm_params = GenericLiteLLMParams(
        **kwargs,
        api_key=api_key,
        api_base=api_base,
        custom_llm_provider=custom_llm_provider,
    )
    (
        model,
        custom_llm_provider,
        dynamic_api_key,
        dynamic_api_base,
    ) = litellm.get_llm_provider('''
        new_handler_code = '''    litellm_params = GenericLiteLLMParams(
        **kwargs,
        api_key=api_key,
        api_base=api_base,
        custom_llm_provider=custom_llm_provider,
    )
    # JD handler debug logging
    print(
        "JDHANDLER",
        {
            "incoming_model": model,
            "incoming_custom_llm_provider": custom_llm_provider,
            "incoming_api_base": api_base,
            "kwargs_keys": sorted(list(kwargs.keys())),
            "litellm_params_model": litellm_params.get("model"),
            "litellm_params_api_base": litellm_params.get("api_base"),
        },
        flush=True,
    )
    (
        model,
        custom_llm_provider,
        dynamic_api_key,
        dynamic_api_base,
    ) = litellm.get_llm_provider('''
        patched_messages_handler_content = messages_handler_content.replace(
            old_handler_code, new_handler_code, 1
        )
        if patched_messages_handler_content != messages_handler_content:
            with open(messages_handler_file, "w") as f:
                f.write(patched_messages_handler_content)
            print("Messages handler debug patch applied successfully!")

    adapters_handler_file = "/app/litellm/llms/anthropic/experimental_pass_through/adapters/handler.py"
    with open(adapters_handler_file, "r") as f:
        adapters_handler_content = f.read()

    adapter_debug_marker = "# JD adapter debug logging"
    if adapter_debug_marker not in adapters_handler_content:
        old_adapter_code = '''        completion_kwargs: Dict[str, Any] = dict(openai_request)

        if stream:'''
        new_adapter_code = '''        completion_kwargs: Dict[str, Any] = dict(openai_request)
        # JD adapter debug logging
        print(
            "JDADAPTER",
            {
                "incoming_model": model,
                "extra_kwargs_keys": sorted(list(extra_kwargs.keys())),
                "extra_kwargs_model": extra_kwargs.get("model"),
                "extra_kwargs_api_base": extra_kwargs.get("api_base"),
                "extra_kwargs_custom_llm_provider": extra_kwargs.get("custom_llm_provider"),
                "completion_model_before": completion_kwargs.get("model"),
            },
            flush=True,
        )

        if stream:'''
        patched_adapters_handler_content = adapters_handler_content.replace(
            old_adapter_code, new_adapter_code, 1
        )
        if patched_adapters_handler_content != adapters_handler_content:
            with open(adapters_handler_file, "w") as f:
                f.write(patched_adapters_handler_content)
            print("Adapters handler debug patch applied successfully!")

    http_handler_file = "/app/litellm/llms/custom_httpx/http_handler.py"
    with open(http_handler_file, "r") as f:
        http_handler_content = f.read()

    http_debug_marker = "# JD HTTP debug logging"
    if http_debug_marker not in http_handler_content:
        old_http_code = '''            req = self.client.build_request(
                "POST",
                url,
                data=request_data,
                json=json,
                params=params,
                headers=headers,
                timeout=timeout,
                files=files,
                content=request_content,
            )
            response = await self.client.send(req, stream=stream)'''
        new_http_code = '''            req = self.client.build_request(
                "POST",
                url,
                data=request_data,
                json=json,
                params=params,
                headers=headers,
                timeout=timeout,
                files=files,
                content=request_content,
            )
            # JD HTTP debug logging
            try:
                import json as _json
                _body = None
                if isinstance(request_content, (str, bytes)):
                    _body = request_content.decode() if isinstance(request_content, bytes) else request_content
                elif isinstance(data, (str, bytes)):
                    _body = data.decode() if isinstance(data, bytes) else data
                if _body is not None:
                    _parsed = _json.loads(_body)
                    print("JDHTTP", {"url": url, "model": _parsed.get("model")}, flush=True)
            except Exception:
                pass
            response = await self.client.send(req, stream=stream)'''
        patched_http_handler_content = http_handler_content.replace(
            old_http_code, new_http_code, 1
        )
        if patched_http_handler_content != http_handler_content:
            with open(http_handler_file, "w") as f:
                f.write(patched_http_handler_content)
            print("HTTP handler debug patch applied successfully!")

    with open(handler_file, "r") as f:
        handler_content = f.read()

    debug_marker = "# JDCloud debug logging"
    if debug_marker not in handler_content:
        old_debug_code = '''        logging_obj.pre_call(
            input=[{"role": "user", "content": json.dumps(request_body)}],
            api_key="",
            additional_args={
                "complete_input_dict": request_body,
                "api_base": str(request_url),
                "headers": headers,
            },
        )

        try:'''
        new_debug_code = '''        logging_obj.pre_call(
            input=[{"role": "user", "content": json.dumps(request_body)}],
            api_key="",
            additional_args={
                "complete_input_dict": request_body,
                "api_base": str(request_url),
                "headers": headers,
            },
        )
        # JDCloud debug logging
        print(
            "JDDEBUG",
            json.dumps(
                {
                    "request_url": str(request_url),
                    "body_model": request_body.get("model"),
                    "header_x_api_key_prefix": (headers.get("x-api-key", "")[:8] if headers.get("x-api-key") else ""),
                    "has_anthropic_beta": "anthropic-beta" in headers,
                },
                ensure_ascii=False,
            )
            ,
            flush=True,
        )
        try:'''
        patched_handler_content = handler_content.replace(old_debug_code, new_debug_code, 1)
        if patched_handler_content != handler_content:
            with open(handler_file, "w") as f:
                f.write(patched_handler_content)
            print("Debug patch applied successfully!")

    print("Model alias patch applied successfully!")
    return True

if __name__ == "__main__":
    apply_patch()
