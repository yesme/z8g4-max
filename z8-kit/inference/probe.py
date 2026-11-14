#!/usr/bin/env python3
"""Smoke-test a local OpenAI-style text service without logging prompt content."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import statistics
import threading
import time
from urllib.error import HTTPError
from urllib.request import Request, urlopen


def request(args, payload):
    headers = {"Content-Type": "application/json"}
    if os.environ.get("DS41_API_KEY"):
        headers["Authorization"] = f"Bearer {os.environ['DS41_API_KEY']}"
    if args.reasoning_effort is not None:
        payload = {**payload, "reasoning_effort": args.reasoning_effort}
    return Request(
        args.base.rstrip("/") + "/chat/completions",
        data=json.dumps({"model": args.model, **payload}).encode(),
        headers=headers,
    )


def stream(args, label, messages, expected=None):
    payload = {
        "messages": messages, "stream": True, "temperature": 0,
        "max_tokens": args.max_tokens,
    }
    if args.usage:
        payload["stream_options"] = {"include_usage": True}
    started = time.monotonic()
    first_delta = first_content = last_content = None
    usage = {}
    timings = {}
    complete = False
    finish_reason = None
    text_chunks = 0
    text = []
    with urlopen(request(args, payload), timeout=args.timeout) as response:
        for raw in response:
            if not raw.startswith(b"data:"):
                continue
            data = raw[5:].strip()
            if data == b"[DONE]":
                complete = True
                break
            chunk = json.loads(data)
            if chunk.get("error"):
                raise RuntimeError("SSE returned an error")
            usage = chunk.get("usage") or usage
            timings.update(chunk.get("timings") or {})
            for choice in chunk.get("choices", []):
                finish_reason = choice.get("finish_reason") or finish_reason
                delta = choice.get("delta") or {}
                now = time.monotonic()
                content = delta.get("content")
                if first_delta is None and (content or delta.get("reasoning_content") or delta.get("reasoning")):
                    first_delta = now
                if content:
                    if first_content is None:
                        first_content = now
                    last_content = now
                    text_chunks += 1
                    if expected is not None:
                        text.append(content)
    elapsed = time.monotonic() - started
    if not complete:
        raise RuntimeError(f"{label}: missing SSE end marker")
    if first_content is None:
        raise RuntimeError(
            f"{label}: no visible text (finish_reason={finish_reason!r}); "
            "check the engine's thinking setting and --max-tokens"
        )
    if expected is not None and "".join(text).strip() != expected:
        raise RuntimeError(f"{label}: expected the request's marker in the reply")
    tokens = usage.get("completion_tokens")
    first_delta_seconds = first_delta - started
    result = {
        "case": label,
        "first_delta_s": round(first_delta_seconds, 3),
        "first_visible_text_s": round(first_content - started, 3),
        "elapsed_s": round(elapsed, 3),
        "text_chunks": text_chunks,
        "usage": usage,
        "visible_stream_s": round(last_content - first_content, 3),
    }
    if isinstance(tokens, int) and tokens > 1 and elapsed > first_delta_seconds:
        result["approx_completion_tokens_per_s"] = round((tokens - 1) / (elapsed - first_delta_seconds), 2)
    timing_fields = ("cache_n", "prompt_n", "prompt_ms", "predicted_n", "predicted_ms")
    observed_timings = {key: timings[key] for key in timing_fields if key in timings}
    if observed_timings:
        result["server_timings"] = observed_timings
    return result


def tool_round_trip(args):
    tool = {
        "type": "function",
        "function": {
            "name": "add_two",
            "description": "Add two integers",
            "parameters": {
                "type": "object",
                "properties": {"a": {"type": "integer"}, "b": {"type": "integer"}},
                "required": ["a", "b"],
            },
        },
    }
    messages = [{
        "role": "user",
        "content": "Call add_two with a=17 and b=25. After the tool returns, reply with just its numeric result.",
    }]
    payload = {
        "messages": messages,
        "tools": [tool],
        "tool_choice": "auto",
        "temperature": 0,
        "max_tokens": max(128, args.max_tokens),
    }
    with urlopen(request(args, payload), timeout=args.timeout) as response:
        assistant = json.load(response)["choices"][0]["message"]
    calls = assistant.get("tool_calls") or []
    if len(calls) != 1:
        raise RuntimeError("Expected one function call")
    call = calls[0]
    function = call["function"]
    if function["name"] != "add_two" or json.loads(function["arguments"]) != {"a": 17, "b": 25}:
        raise RuntimeError("Wrong function or arguments")
    turn = {
        "role": "assistant", "content": assistant.get("content") or "",
        "tool_calls": calls,
    }
    for key in ("reasoning", "reasoning_content"):
        if assistant.get(key):
            turn[key] = assistant[key]
    payload["messages"] = messages + [turn, {
        "role": "tool", "tool_call_id": call["id"], "content": "42",
    }]
    with urlopen(request(args, payload), timeout=args.timeout) as response:
        reply = json.load(response)["choices"][0]["message"].get("content") or ""
    if reply.strip() != "42":
        raise RuntimeError("Tool result was not returned as the numeric answer")
    return {"case": "tool-round-trip", "passed": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="http://127.0.0.1:18000/v1")
    parser.add_argument("--model", default="deepseek-v4.1-flash-1017")
    parser.add_argument("--prompt-file", type=Path)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--max-tokens", type=int, default=256)
    parser.add_argument("--timeout", type=float, default=300)
    parser.add_argument("--tools", action="store_true")
    parser.add_argument("--parallel-pairs", action="store_true",
                        help="Also send simultaneous pairs to an engine configured for concurrency")
    parser.add_argument("--usage", action="store_true", help="Request SSE usage for supporting engines")
    parser.add_argument("--reasoning-effort", help="Set reasoning_effort for engines that support it")
    args = parser.parse_args()
    if args.repeats < 1 or args.max_tokens < 1 or args.timeout <= 0:
        parser.error("repeats, max-tokens and timeout must be positive")
    prefix = args.prompt_file.read_text(encoding="utf-8") if args.prompt_file else "We are reviewing a Linux workstation."
    shared = [{"role": "system", "content": prefix}]
    a = shared + [{"role": "user", "content": "Explain PCIe link widths in four short sentences."}]
    b = shared + [{"role": "user", "content": "Explain NUMA affinity in four short sentences."}]
    distinct = [
        {"role": "system", "content": "You are reviewing a separate project about audio encoding."},
        {"role": "user", "content": "Explain bitrate in four short sentences."},
    ]
    markers = ("Z8-PCI-1800", "Z8-CAS-8980")
    isolation_inputs = [
        [{"role": "user", "content": f"Repeat exactly this string, with no other text: {marker}"}]
        for marker in markers
    ]

    def show(value):
        print(json.dumps(value), flush=True)

    def run_pair(label, first, second, expected=(None, None)):
        barrier = threading.Barrier(2)

        def simultaneous(name, messages, marker):
            barrier.wait(timeout=15)
            return stream(args, name, messages, marker)

        started = time.monotonic()
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [
                pool.submit(simultaneous, f"{label}-A", first, expected[0]),
                pool.submit(simultaneous, f"{label}-B", second, expected[1]),
            ]
            results = [future.result() for future in futures]
        for result in results:
            show(result)
        show({"case": f"{label}-combined", "elapsed_s": round(time.monotonic() - started, 3)})

    try:
        warm = []
        for _ in range(args.repeats):
            for label, messages in (("A", a), ("A-repeat", a), ("B-shared", b), ("A-after-B", a)):
                result = stream(args, label, messages)
                show(result)
                if label == "A-repeat":
                    warm.append(result["first_visible_text_s"])
            if args.parallel_pairs:
                run_pair("parallel-shared", a, b)
                run_pair("parallel-distinct", a, distinct)
        if args.parallel_pairs:
            run_pair("parallel-markers", *isolation_inputs, expected=markers)
        if args.tools:
            show(tool_round_trip(args))
        show({"case": "summary", "A-repeat_median_first_text_s": statistics.median(warm)})
    except HTTPError as exc:
        raise SystemExit(f"HTTP {exc.code} from chat completion endpoint") from exc
    except (OSError, RuntimeError, ValueError, KeyError, IndexError) as exc:
        raise SystemExit(f"Probe failed: {exc}") from exc


if __name__ == "__main__":
    main()
