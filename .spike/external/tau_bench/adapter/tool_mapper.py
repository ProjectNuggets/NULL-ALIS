#!/usr/bin/env python3
"""Map tau-bench tool metadata into the nullalis benchmark prompt catalog."""

from __future__ import annotations

import json
from typing import Any, Iterable


def to_nullalis_tool(tool_info: dict[str, Any]) -> dict[str, Any]:
    """Return the stable nullalis-style catalog shape for one tau-bench tool.

    nullalis tools expose name, description, and a JSON parameter schema. The
    tau-bench definitions already use OpenAI function-tool metadata, so this
    mapper preserves that schema and adds benchmark provenance.
    """

    function = tool_info.get("function", {})
    parameters = function.get("parameters") or {"type": "object", "properties": {}}
    return {
        "name": function.get("name", ""),
        "description": function.get("description", ""),
        "parameters_json": json.dumps(parameters, sort_keys=True),
        "input_schema": parameters,
        "cost_class": "B",
        "source": "tau_bench_airline",
    }


def map_tools(tools_info: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    return [to_nullalis_tool(tool) for tool in tools_info]


def catalog_for_prompt(tools_info: Iterable[dict[str, Any]]) -> str:
    """Compact JSON catalog embedded in the gateway prompt."""

    return json.dumps(map_tools(tools_info), indent=2, sort_keys=True)
