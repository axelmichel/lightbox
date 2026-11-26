"""Minimal fake ComfyUI for exercising ComfyKit's client end to end.

Speaks the same HTTP + WebSocket protocol as ComfyUI: queues a prompt,
streams execution_start / progress / binary previews / execution_success,
and serves the result through /history and /view. Validates the graph
like ComfyUI does for the parts we use (known class types, links to
existing nodes, checkpoint names from object_info).
"""

import asyncio
import json
import struct
import sys
import uuid
import zlib

from aiohttp import web

FIXTURE = sys.argv[1]
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8189
OBJECT_INFO = json.load(open(FIXTURE))
KNOWN = set(OBJECT_INFO) | {"CLIPTextEncode", "CLIPSetLastLayer", "EmptyLatentImage", "VAEDecode", "PreviewImage", "LoadImage",
                            "SaveImage"}

sockets: dict[str, web.WebSocketResponse] = {}
history: dict[str, dict] = {}
log: list[str] = []


def png(w=8, h=8, rgb=(200, 80, 40)):
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


async def send(cid, typ, data):
    ws = sockets.get(cid)
    if ws is not None and not ws.closed:
        await ws.send_str(json.dumps({"type": typ, "data": data}))


async def run(pid, cid, graph):
    # Like an idle real server: starts at once. Clients must not rely on
    # execution_start (it is lost if their socket connects late), so the
    # fake does not send it at all.
    await asyncio.sleep(0)
    await send(cid, "executing", {"node": next(iter(graph)), "display_node": next(iter(graph)), "prompt_id": pid})
    sampler = next((n for n in graph.values() if n["class_type"] == "KSampler"), None)
    steps = sampler["inputs"]["steps"] if sampler else 4
    for i in range(1, steps + 1):
        await send(cid, "progress", {"value": i, "max": steps, "prompt_id": pid, "node": "x"})
        ws = sockets.get(cid)
        if ws is not None and not ws.closed:
            await ws.send_bytes(struct.pack(">II", 1, 2) + png(4, 4, (min(i * 20, 255), 0, 0)))
        await asyncio.sleep(0.02)
    out = next(k for k, n in graph.items() if n["class_type"] in ("PreviewImage", "SaveImage"))
    batch = next((n["inputs"]["batch_size"] for n in graph.values() if n["class_type"] == "EmptyLatentImage"), 1)
    images = [{"filename": f"ComfyUI_temp_{pid[:6]}_{i}.png", "subfolder": "", "type": "temp"} for i in range(batch)]
    # As ComfyUI does: the queued prompt is in the history too.
    history[pid] = {"prompt": [1, pid, graph, {}, [out]], "outputs": {out: {"images": images}},
                    "status": {"status_str": "success", "completed": True}}
    await send(cid, "executed", {"node": out, "output": {"images": images}, "prompt_id": pid})
    await send(cid, "execution_success", {"prompt_id": pid})
    await send(cid, "executing", {"node": None, "prompt_id": pid})


def validate(graph):
    errors = {}
    ckpts = OBJECT_INFO["CheckpointLoaderSimple"]["input"]["required"]["ckpt_name"][0]
    for nid, node in graph.items():
        ct = node.get("class_type")
        if ct not in KNOWN:
            errors[nid] = f"unknown class {ct}"
        for name, value in node.get("inputs", {}).items():
            if isinstance(value, list) and len(value) == 2 and isinstance(value[0], str) and value[0] not in graph:
                errors[nid] = f"{name} links to missing node {value[0]}"
        if ct == "CheckpointLoaderSimple" and node["inputs"]["ckpt_name"] not in ckpts:
            errors[nid] = f"ckpt_name not in list: {node['inputs']['ckpt_name']}"
    return errors


async def prompt(request):
    body = await request.json()
    graph, cid = body["prompt"], body.get("client_id", "")
    errors = validate(graph)
    if errors:
        return web.json_response({"error": {"message": "Prompt outputs failed validation", "details": ""},
                                  "node_errors": {k: {"errors": [{"message": v, "details": ""}], "class_type": graph[k].get("class_type")} for k, v in errors.items()}},
                                 status=400)
    pid = str(uuid.uuid4())
    log.append("prompt " + ",".join(sorted(n["class_type"] for n in graph.values())))
    asyncio.get_running_loop().create_task(run(pid, cid, graph))
    return web.json_response({"prompt_id": pid, "number": 1, "node_errors": {}})


async def ws_handler(request):
    ws = web.WebSocketResponse()
    await ws.prepare(request)
    cid = request.query.get("clientId", "")
    sockets[cid] = ws
    await ws.send_str(json.dumps({"type": "status", "data": {"status": {"exec_info": {"queue_remaining": 0}}, "sid": cid}}))
    async for _ in ws:
        pass
    sockets.pop(cid, None)
    return ws


async def upload(request):
    data = await request.post()
    f = data["image"]
    log.append(f"upload {f.filename} {len(f.file.read())} bytes subfolder={data.get('subfolder')}")
    return web.json_response({"name": f.filename, "subfolder": data.get("subfolder", ""), "type": "input"})


async def system_stats(_):
    return web.json_response({"system": {"os": "posix", "comfyui_version": "fake-0.1", "pytorch_version": "none"},
                              "devices": [{"name": "cuda:0 Fake GPU : cudaMallocAsync", "type": "cuda", "vram_total": 8589934592, "vram_free": 4294967296}]})


async def get_log(_):
    return web.json_response(log)


async def object_info(_):
    return web.json_response(OBJECT_INFO)


async def get_history(r):
    pid = r.match_info["pid"]
    return web.json_response({pid: history[pid]} if pid in history else {})


async def view(_):
    return web.Response(body=png(), content_type="image/png")


async def ok(_):
    log.append("cancel")
    return web.Response()


# The frontend's saved workflows: one made-up workflow from the tests' fixtures.
SAVED = {"made_up_krea2.json": __import__("pathlib").Path(__file__).resolve().parent.parent.parent
         / "Packages/LightboxCore/Tests/LightboxCoreTests/Fixtures/workflow_krea2_ui.json"}


async def userdata(request):
    if request.query.get("dir") != "workflows":
        return web.json_response([])
    return web.json_response(sorted(SAVED))


async def userdata_file(request):
    name = request.match_info["file"]
    path = SAVED.get(name.removeprefix("workflows/"))
    if path is None:
        return web.Response(status=404)
    return web.Response(body=path.read_bytes(), content_type="application/json")


app = web.Application()
app.add_routes([
    web.get("/system_stats", system_stats),
    web.get("/object_info", object_info),
    web.post("/prompt", prompt),
    web.get("/ws", ws_handler),
    web.post("/upload/image", upload),
    web.get("/history/{pid}", get_history),
    web.get("/view", view),
    web.post("/interrupt", ok),
    web.post("/queue", ok),
    web.get("/fake_log", get_log),
    web.get("/api/userdata", userdata),
    web.get("/api/userdata/{file}", userdata_file),
])
web.run_app(app, host="127.0.0.1", port=PORT, print=None)
