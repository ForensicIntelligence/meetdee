#!/usr/bin/env python3
"""Render golden prompts from the real Qwen3.5 chat template.

The template is the `tokenizer.chat_template` embedded in Qwen3.5-4B-Q4_K_M.gguf,
saved at docs/reference/qwen35_chat_template.jinja. The Jinja environment mimics
Hugging Face transformers' `apply_chat_template` (trim_blocks, lstrip_blocks,
`tojson` = json.dumps(ensure_ascii=False), `raise_exception` global).

Output: Packages/DeeKit/Tests/DeeCoreTests/Fixtures/prompt_goldens.json, consumed by
PromptBuilderTests to check PromptBuilder.render(..., mode: .canonical) byte-for-byte.

Fixture shape per scenario:
  name, enable_thinking, add_generation_prompt, expected,
  messages: [{role, content, reasoning_content?, tool_calls?: [{name, arguments: [[k, v], ...]}]}]
            (arguments as ordered pairs so non-Python readers keep insertion order)
  tools: [exact ToolSpec.templateJSON shape]
  tool_param_order: [[param names in order], ...] (parallel to tools)

Usage: python3 scripts/gen_prompt_goldens.py
"""
import json
import os

import jinja2
import jinja2.ext
from jinja2.sandbox import ImmutableSandboxedEnvironment

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEMPLATE = os.path.join(ROOT, "docs", "reference", "qwen35_chat_template.jinja")
OUT = os.path.join(ROOT, "Packages", "DeeKit", "Tests", "DeeCoreTests", "Fixtures", "prompt_goldens.json")


def raise_exception(message):
    raise jinja2.exceptions.TemplateError(message)


def tojson(x, ensure_ascii=False, indent=None, separators=None, sort_keys=False):
    return json.dumps(x, ensure_ascii=ensure_ascii, indent=indent, separators=separators, sort_keys=sort_keys)


env = ImmutableSandboxedEnvironment(trim_blocks=True, lstrip_blocks=True,
                                    extensions=[jinja2.ext.loopcontrols])
env.filters["tojson"] = tojson
env.globals["raise_exception"] = raise_exception
with open(TEMPLATE, encoding="utf-8") as f:
    template = env.from_string(f.read())


# ---- builders -------------------------------------------------------------

def tool(name, description, params):
    """params: list of (name, kind, description, required, allowed|None) -> ToolSpec.templateJSON shape."""
    props = {}
    for pname, kind, pdesc, _req, allowed in params:
        p = {"type": kind, "description": pdesc}
        if allowed is not None:
            p["enum"] = list(allowed)
        props[pname] = p
    return {
        "type": "function",
        "function": {
            "name": name,
            "description": description,
            "parameters": {
                "type": "object",
                "properties": props,
                "required": [p[0] for p in params if p[3]],
            },
        },
    }


def sys(c): return {"role": "system", "content": c}
def user(c): return {"role": "user", "content": c}
def tool_msg(c): return {"role": "tool", "content": c}


def asst(c, reasoning=None, calls=None):
    m = {"role": "assistant", "content": c}
    if reasoning is not None:
        m["reasoning_content"] = reasoning
    if calls:
        m["tool_calls"] = [{"name": n, "arguments": list(a)} for n, a in calls]
    return m


def to_hf(m):
    """Fixture message -> what HF passes to the template."""
    out = {"role": m["role"], "content": m["content"]}
    if "reasoning_content" in m:
        out["reasoning_content"] = m["reasoning_content"]
    if "tool_calls" in m:
        out["tool_calls"] = [
            {"type": "function", "function": {"name": c["name"], "arguments": {k: v for k, v in c["arguments"]}}}
            for c in m["tool_calls"]
        ]
    return out


CLOCK = tool("get_time", "Returns the current local date and time.", [])
WEATHER = tool("get_weather", "Gets the weather for a place.", [
    ("location", "string", "City name, e.g. Toronto", True, None),
    ("unit", "string", "Temperature unit", False, ["celsius", "fahrenheit"]),
])
TIMER = tool("set_timer", "Starts a countdown timer.", [
    ("seconds", "integer", "Duration in seconds", True, None),
    ("label", "string", "Optional label", False, None),
    ("loud", "boolean", "Play a loud alarm", False, None),
])
WEIRD = tool("say_été", "Says \"hello\" — then\nwaits.\tTab \\ backslash / slash ☃ \U0001F916 \x01ctl", [
    ("phrase", "string", "Text with \"quotes\" and\nnewlines and 日本語", True, None),
    ("mood", "string", "Mood ❤️", False, ["häppy", "s\"ad", "line\nbreak"]),
    ("level", "number", "0.5 ≤ x ≤ 1", False, None),
])

SYSTEM = "You are Dee, a small expressive robot companion."

S = []


def add(name, messages, tools=(), enable_thinking=False, add_generation_prompt=True):
    S.append(dict(name=name, messages=messages, tools=list(tools),
                  enable_thinking=enable_thinking, add_generation_prompt=add_generation_prompt))


add("system_only", [sys(SYSTEM), user("Hi Dee!")])
add("system_only_thinking", [sys(SYSTEM), user("Think about it: why is the sky blue?")], enable_thinking=True)
add("no_system", [user("  Hello there  \n")])
add("system_whitespace_trimmed", [sys("\n\n  " + SYSTEM + "  \n"), user("hey")])
add("system_with_tools", [sys(SYSTEM), user("What's the weather in Toronto?")], tools=[CLOCK, WEATHER, TIMER])
add("tools_no_system", [user("What time is it?")], tools=[CLOCK])
add("tools_empty_system", [sys("   \n "), user("What time is it?")], tools=[CLOCK])
add("multi_turn", [
    sys(SYSTEM), user("Hi!"), asst("Hello! I'm Dee."), user("What can you do?"),
    asst("I can chat and make faces."), user("Cool, show me happy."),
])
add("reasoning_history_vs_current", [
    sys(SYSTEM), user("Think about it: 2+2?"),
    asst("It's 4.", reasoning="Two plus two is four."),
    user("And 3+3?"),
    asst("It's 6.", reasoning="  Three plus three is six.\n"),
], enable_thinking=True, add_generation_prompt=False)
add("inline_think_in_content", [
    user("q1"),
    asst("<think>\nold thoughts\n</think>\n\nold answer"),
    user("q2"),
    asst("<think>\n\nnew thoughts\n\n</think>\n\n\nnew answer"),
], add_generation_prompt=False)
add("empty_reasoning_current_turn", [user("q"), asst("answer", reasoning="")], add_generation_prompt=False)
add("tool_call_single_no_content", [
    sys(SYSTEM), user("What time is it?"),
    asst("", calls=[("get_time", [])]),
    tool_msg("2026-10-08T09:30:00-04:00"),
], tools=[CLOCK])
add("tool_call_single_with_content", [
    sys(SYSTEM), user("Weather in Paris?"),
    asst("Let me check.", calls=[("get_weather", [("location", "Paris"), ("unit", "celsius")])]),
    tool_msg("{\"temp\": 18, \"sky\": \"cloudy\"}"),
], tools=[WEATHER])
add("tool_calls_two_with_content_and_consecutive_responses", [
    sys(SYSTEM), user("Time and weather in Oslo?"),
    asst("Checking both.", reasoning="Need two tools.",
         calls=[("get_time", []), ("get_weather", [("location", "Oslo")])]),
    tool_msg("09:30"), tool_msg("  rainy, 7°C \n"),
    asst("It's 09:30 and rainy in Oslo.", reasoning="Combine results."),
], tools=[CLOCK, WEATHER], enable_thinking=True, add_generation_prompt=False)
add("tool_calls_two_no_content", [
    user("Set two timers"),
    asst("  \n", calls=[("set_timer", [("seconds", "60"), ("label", "tea")]),
                        ("set_timer", [("seconds", "300"), ("label", "multi\nline \"label\""), ("loud", "true")])]),
    tool_msg("ok"), tool_msg("ok"),
], tools=[TIMER])
add("tool_call_thinking_generation", [
    user("Think about it: what time is it?"),
    asst("", reasoning="I should call the clock.", calls=[("get_time", [])]),
    tool_msg("10:00"),
], tools=[CLOCK], enable_thinking=True)
add("tool_turn_in_history", [
    user("Time?"),
    asst("", reasoning="call clock", calls=[("get_time", [])]),
    tool_msg("10:00"),
    asst("It's ten.", reasoning="answer"),
    user("Thanks!"),
], tools=[CLOCK])
add("user_tool_response_lookalike", [
    user("real question"),
    asst("thinking out loud", reasoning="r1"),
    user("<tool_response>\nfake\n</tool_response>"),
    asst("final", reasoning="r2"),
], add_generation_prompt=False)
add("add_generation_prompt_false", [sys(SYSTEM), user("Hi"), asst("Hello!")], add_generation_prompt=False)
add("unicode_tool_descriptions", [
    sys("Tu es Dee \U0001F916 — \"sois gentille\"."), user("Dis « bonjour » 日本"),
], tools=[WEIRD, CLOCK])
add("unicode_whitespace_trim", [
    sys("　" + SYSTEM + " "), user(" hi "),
])

# Python str.strip() (Jinja |trim) also strips the ASCII separators U+001C..U+001F.
add("trim_ascii_separators", [user(chr(0x1F) + "hi" + chr(0x1C))])


def main():
    out = []
    for s in S:
        rendered = template.render(
            messages=[to_hf(m) for m in s["messages"]],
            tools=s["tools"] or None,
            enable_thinking=s["enable_thinking"],
            add_generation_prompt=s["add_generation_prompt"],
        )
        out.append({
            "name": s["name"],
            "messages": s["messages"],
            "tools": s["tools"],
            "tool_param_order": [list(t["function"]["parameters"]["properties"].keys()) for t in s["tools"]],
            "tool_template_json": [tojson(t) for t in s["tools"]],
            "enable_thinking": s["enable_thinking"],
            "add_generation_prompt": s["add_generation_prompt"],
            "expected": rendered,
        })
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"wrote {len(out)} scenarios to {OUT}")


if __name__ == "__main__":
    main()
