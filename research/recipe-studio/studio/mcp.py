"""A minimal MCP client for `redlamp mcp` (newline-delimited JSON-RPC over stdio).

Agents reach Redlamp only through these tools; there is no other path to the engine.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

from . import ROOT


def default_cli() -> Path:
    if "REDLAMP_CLI" in os.environ:
        return Path(os.environ["REDLAMP_CLI"])
    for folder in ("DerivedData", "DerivedData-recipes"):
        for configuration in ("Release", "Debug"):
            candidate = ROOT / "build" / folder / "Build" / "Products" / configuration / "redlamp"
            if candidate.exists():
                return candidate
    raise FileNotFoundError("redlamp CLI not found; build it (mise run build) or set REDLAMP_CLI")


class ToolError(Exception):
    pass


class RedlampMCP:
    """Starts `redlamp mcp` and calls its tools. Also counts renders for budgets."""

    RENDERING_TOOLS = {"render", "contact_sheet", "compare", "fit_to_fingerprint", "save_candidate", "lint", "fingerprint"}

    def __init__(self, cli: Path | None = None):
        self.process = subprocess.Popen(
            [str(cli or default_cli()), "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, cwd=ROOT, env={**os.environ, "REDLAMP_ROOT": str(ROOT)},
        )
        self.next_id = 0
        self.calls = 0
        self._request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                     "clientInfo": {"name": "recipe-studio", "version": "1"}})
        self._notify("notifications/initialized")
        self.tools = [tool["name"] for tool in self._request("tools/list", {})["tools"]]

    def _send(self, message: dict) -> None:
        assert self.process.stdin
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def _notify(self, method: str) -> None:
        self._send({"jsonrpc": "2.0", "method": method})

    def _request(self, method: str, params: dict) -> dict:
        self.next_id += 1
        self._send({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params})
        assert self.process.stdout
        while True:
            line = self.process.stdout.readline()
            if not line:
                raise ToolError("redlamp mcp exited")
            message = json.loads(line)
            if message.get("id") != self.next_id:
                continue
            if "error" in message:
                raise ToolError(message["error"].get("message", "error"))
            return message["result"]

    def call(self, tool: str, **arguments) -> dict:
        """Calls a tool; returns its JSON text parsed (or {"text": …}) plus saved paths."""
        if tool in self.RENDERING_TOOLS:
            self.calls += 1
        result = self._request("tools/call", {"name": tool, "arguments": arguments})
        texts = [item["text"] for item in result.get("content", []) if item.get("type") == "text"]
        if result.get("isError"):
            raise ToolError(" ".join(texts))
        text = "\n".join(texts)
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            saved = text.split("saved ", 1)[1].split(" (", 1)[0] if text.startswith("saved ") else None
            return {"text": text, "path": saved}

    def close(self) -> None:
        if self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=10)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()
