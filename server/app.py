"""
Owns one real Jupyter (ipykernel) kernel for one notebook session, and bridges it
to two clients: Neovim (plain HTTP POST, fire-and-forget) and a browser (WebSocket,
server-push). Neovim tells us "run cell N with this code"; each run is appended as
a new, immutable entry to an execution log (not a live mirror of cell N's current
state) — the browser is a queue/history of what's actually been run, in the order
it was run, so re-running a cell adds a new entry rather than replacing the old one.
"""

import argparse
import asyncio
import json
import re
import signal
import sys
from pathlib import Path

from aiohttp import web, WSMsgType
from jupyter_client import AsyncKernelManager

STATIC_DIR = Path(__file__).parent / "static"

PLOTLY_MIMETYPE = "application/vnd.plotly.v1+json"

# Priority order for picking one representation out of a possibly-multi-mimetype
# IPython display bundle (e.g. a DataFrame yields both text/html and text/plain).
# The Plotly-specific mimetype is normalized into text/html below (see
# _normalize_output), so it's treated as equivalent to text/html here.
MIMETYPE_PRIORITY = ["text/html", PLOTLY_MIMETYPE, "image/png", "image/svg+xml", "text/plain"]

ANSI_ESCAPE = re.compile(r"\x1b\[[0-9;]*m")


class NotebookSession:
    def __init__(self):
        self.km = AsyncKernelManager()
        self.kc = None
        # Ordered execution log: each entry is one run, never overwritten.
        # {"runId": int, "cellId": int, "code": str, "outputs": list[dict]}
        self.runs = []
        self.runs_by_id = {}
        self.next_run_id = 1
        # msg_id (str) -> runId (int), only while that execute_request is in flight
        self.inflight = {}
        self.ws_clients = set()
        self._pump_task = None

    async def start(self):
        self.km.kernel_cmd = [sys.executable, "-m", "ipykernel_launcher", "-f", "{connection_file}"]
        await self.km.start_kernel()
        self.kc = self.km.client()
        self.kc.start_channels()
        await self.kc.wait_for_ready(timeout=30)
        # Makes matplotlib figures come back as image/png automatically, without
        # the user needing "%matplotlib inline" in every notebook.
        self.kc.execute("%matplotlib inline", silent=True)
        self._pump_task = asyncio.create_task(self._iopub_pump())

    async def stop(self):
        # Force-close any open browser WebSocket connections first: aiohttp's
        # AppRunner.cleanup() otherwise waits for connections to close
        # gracefully, and a browser tab left open can block shutdown
        # indefinitely (confirmed empirically — a lingering client hung
        # process exit even after the kernel itself had already shut down).
        for ws in list(self.ws_clients):
            await ws.close(code=1001, message=b"server shutting down")
        self.ws_clients.clear()

        if self._pump_task:
            self._pump_task.cancel()
        if self.kc:
            self.kc.stop_channels()
        if self.km.has_kernel:
            await self.km.shutdown_kernel(now=True)

    async def broadcast(self, message):
        dead = set()
        for ws in self.ws_clients:
            try:
                await ws.send_json(message)
            except ConnectionResetError:
                dead.add(ws)
        self.ws_clients -= dead

    async def run(self, cell_id, code):
        run_id = self.next_run_id
        self.next_run_id += 1
        entry = {"runId": run_id, "cellId": cell_id, "code": code, "outputs": []}
        self.runs.append(entry)
        self.runs_by_id[run_id] = entry

        await self.broadcast({"type": "run_started", "runId": run_id, "cellId": cell_id, "code": code})
        msg_id = self.kc.execute(code)
        self.inflight[msg_id] = run_id

    def _pick_mimetype(self, data):
        for mt in MIMETYPE_PRIORITY:
            if mt in data:
                return mt, data[mt]
        # Nothing we prioritize was present; just take whatever's first.
        mt, value = next(iter(data.items()))
        return mt, value

    def _normalize_output(self, mimetype, value):
        # Plotly's default renderer (via fig.show(), or a bare trailing `fig`)
        # emits this custom mimetype meant for Jupyter's own Plotly renderer
        # extension, which we don't have — its value is a JSON object
        # ({"data": [...], "layout": {...}}), not an HTML string. Reconstruct
        # a real Figure from it ourselves and render to HTML, so the user's
        # normal Plotly code (fig.show() / bare `fig`) just works, without
        # needing display(HTML(fig.to_html(...))) as a manual workaround.
        if mimetype == PLOTLY_MIMETYPE:
            try:
                import plotly.graph_objects as go
                import plotly.io as pio

                fig = go.Figure(data=value.get("data"), layout=value.get("layout"), frames=value.get("frames"))
                html = pio.to_html(fig, full_html=False, include_plotlyjs="cdn")
                return "text/html", html
            except Exception as exc:
                return "text/plain", f"[could not render plotly figure: {exc}]"
        return mimetype, value

    async def _iopub_pump(self):
        while True:
            msg = await self.kc.get_iopub_msg()
            parent_msg_id = msg.get("parent_header", {}).get("msg_id")
            run_id = self.inflight.get(parent_msg_id)
            if run_id is None:
                continue  # not something we submitted (e.g. our own silent %matplotlib inline)

            msg_type = msg["header"]["msg_type"]
            content = msg["content"]

            output = None
            if msg_type == "stream":
                output = {"kind": "stream", "stream": content["name"], "text": content["text"]}
            elif msg_type in ("execute_result", "display_data"):
                mimetype, value = self._pick_mimetype(content["data"])
                mimetype, value = self._normalize_output(mimetype, value)
                output = {"kind": "result", "mimetype": mimetype, "data": value}
            elif msg_type == "error":
                traceback_text = "\n".join(ANSI_ESCAPE.sub("", line) for line in content["traceback"])
                output = {
                    "kind": "error",
                    "ename": content["ename"],
                    "evalue": content["evalue"],
                    "traceback": traceback_text,
                }
            elif msg_type == "status" and content["execution_state"] == "idle":
                del self.inflight[parent_msg_id]
                await self.broadcast({"type": "run_finished", "runId": run_id})
                continue
            else:
                continue

            self.runs_by_id[run_id]["outputs"].append(output)
            await self.broadcast({"type": "output", "runId": run_id, **output})


def full_state_message(session):
    return {"type": "full_state", "runs": session.runs}


def build_app(session):
    app = web.Application()

    async def index(request):
        return web.FileResponse(STATIC_DIR / "index.html")

    async def health(request):
        return web.Response(text="ok")

    async def run(request):
        body = await request.json()
        await session.run(int(body["cellId"]), body["code"])
        return web.Response(status=202, text=json.dumps({"status": "submitted"}))

    async def ws_handler(request):
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        session.ws_clients.add(ws)
        await ws.send_json(full_state_message(session))
        try:
            async for msg in ws:
                if msg.type == WSMsgType.ERROR:
                    break
        finally:
            session.ws_clients.discard(ws)
        return ws

    app.router.add_get("/", index)
    app.router.add_get("/health", health)
    app.router.add_post("/run", run)
    app.router.add_get("/ws", ws_handler)
    app.router.add_static("/static/", STATIC_DIR)
    return app


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--notebook-path", default=None)
    # 0 (default) = OS-assigned ephemeral port. A fixed port is opt-in from
    # the Neovim side (require("ipynb-run-nvim").setup({ port = N })) — it
    # exists specifically to make SSH port-forwarding to a remote instance
    # practical (an ephemeral port changes every session, which is awkward
    # to tunnel). Still only ever binds 127.0.0.1 either way.
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()

    session = NotebookSession()
    await session.start()

    app = build_app(session)
    # shutdown_timeout bounds how long cleanup() waits for connections to
    # close gracefully — a safety net on top of explicitly closing WebSocket
    # clients in session.stop(), so a stuck connection can't hang the process.
    runner = web.AppRunner(app, shutdown_timeout=2.0)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", args.port)
    await site.start()

    port = site._server.sockets[0].getsockname()[1]
    print(json.dumps({"port": port}), flush=True)

    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop_event.set)

    await stop_event.wait()
    await session.stop()
    await runner.cleanup()


if __name__ == "__main__":
    asyncio.run(main())
