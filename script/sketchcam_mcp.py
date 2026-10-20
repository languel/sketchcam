#!/usr/bin/env python3
"""Local stdio MCP bridge to the running SketchCam app (no dependencies)."""

import json
import os
import pathlib
import sys
import time
import uuid

BRIDGE = pathlib.Path.home() / "Library/Application Support/SketchCam/mcp-bridge"
VERSION = "2025-11-25"


def catalog():
    try:
        return json.loads((BRIDGE / "catalog.json").read_text())
    except (OSError, ValueError):
        return []


def app_is_live():
    try:
        return time.time() - float((BRIDGE / "heartbeat").read_text()) < 1.5
    except (OSError, ValueError):
        return False


def invoke(command_id):
    if not app_is_live():
        raise RuntimeError("SketchCam is not running with its command bridge active")
    if command_id not in {item["id"] for item in catalog()}:
        raise ValueError("Unknown SketchCam command")
    ticket = str(uuid.uuid4())
    temporary = BRIDGE / f"{ticket}.tmp"
    response = BRIDGE / f"{ticket}.response"
    temporary.write_text(json.dumps({"id": command_id}))
    os.replace(temporary, BRIDGE / f"{ticket}.request")
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            result = json.loads(response.read_text())
            response.unlink(missing_ok=True)
            if not result.get("ok"):
                raise RuntimeError("SketchCam did not accept the command")
            return
        except FileNotFoundError:
            time.sleep(0.025)
    raise TimeoutError("SketchCam did not respond within five seconds")


def handle(message):
    method = message.get("method")
    params = message.get("params") or {}
    if method == "initialize":
        return {"protocolVersion": VERSION, "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "sketchcam", "version": "0.1.0"},
                "instructions": "Commands control the running local SketchCam app. Some commands edit or clear artwork."}
    if method == "ping":
        return {}
    if method == "tools/list":
        return {"tools": [
            {"name": "sketchcam." + item["id"],
             "description": item["category"] + ": " + item["title"] +
                ". Invokes this command in the running SketchCam app.",
             "annotations": {"destructiveHint": item["id"] in {"ink.clear", "ink.delete"},
                             "readOnlyHint": False},
             "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False}}
            for item in catalog()
        ]}
    if method == "tools/call":
        name = params.get("name", "")
        if not name.startswith("sketchcam."):
            raise ValueError("Unknown tool")
        try:
            if params.get("arguments") not in (None, {}):
                raise ValueError("This SketchCam command takes no arguments")
            invoke(name[len("sketchcam."):])
            return {"content": [{"type": "text", "text": "Command sent to SketchCam."}]}
        except (RuntimeError, ValueError, TimeoutError) as error:
            return {"isError": True, "content": [{"type": "text", "text": str(error)}]}
    raise KeyError(method)


def main():
    for line in sys.stdin:
        try:
            message = json.loads(line)
            if "id" not in message:
                continue
            try:
                result = handle(message)
                reply = {"jsonrpc": "2.0", "id": message["id"], "result": result}
            except KeyError as error:
                reply = {"jsonrpc": "2.0", "id": message["id"],
                         "error": {"code": -32601, "message": f"Unknown method: {error}"}}
            except (ValueError, TypeError) as error:
                reply = {"jsonrpc": "2.0", "id": message["id"],
                         "error": {"code": -32602, "message": str(error)}}
        except (ValueError, TypeError) as error:
            reply = {"jsonrpc": "2.0", "id": None,
                     "error": {"code": -32700, "message": str(error)}}
        sys.stdout.write(json.dumps(reply, separators=(",", ":")) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
