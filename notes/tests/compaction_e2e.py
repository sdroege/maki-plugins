import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from http.server import BaseHTTPRequestHandler, HTTPServer
from threading import Thread


SUMMARY = "E2E_SUMMARY"
REMINDER = (
    "The session was compacted. Read any relevant notes before retracing your steps."
    "\n\nSaved notes:\n- a.md\n- b.md"
)


def tool(index, name, **arguments):
    return {
        "index": index,
        "id": f"call_{name}_{index}",
        "type": "function",
        "function": {"name": name, "arguments": json.dumps(arguments)},
    }


def messages_text(messages, role):
    return "\n".join(
        message["content"] for message in messages if message["role"] == role
    )


def response(step, body):
    messages = body["messages"]
    if step == 1:
        tools = {item["function"]["name"] for item in body["tools"]}
        assert {"notes", "compact"} <= tools, tools
        return {
            "tool_calls": [
                tool(0, "notes", command="write", path="a.md", text="A"),
                tool(1, "notes", command="write", path="b.md", text="B"),
            ]
        }
    if step == 2:
        results = messages_text(messages, "tool")
        assert "wrote a.md" in results and "wrote b.md" in results, results
        return {"tool_calls": [tool(0, "compact", instructions="E2E_COMPACT")]}
    if step == 3:
        assert not body.get("tools"), "summarizer should not get tools"
        assert "E2E_COMPACT" in messages_text(messages[-1:], "user"), messages[-1]
        return {"content": SUMMARY}
    assert step == 4, f"unexpected model request {step}"
    assert body.get("tools"), "expected a normal request after the summary"
    summary_index = next(
        (
            i for i, message in enumerate(messages)
            if message["role"] == "assistant" and SUMMARY in message["content"]
        ),
        None,
    )
    assert summary_index is not None, "first resumed request is missing the summary"
    resumed = [m["content"] for m in messages[summary_index + 1:] if m["role"] == "user"]
    assert any(REMINDER in text for text in resumed), resumed
    return {"content": "E2E_OK"}


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send_body(self, data, content_type="application/json", status=200):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/props?autoload=false":
            self.send_body(b"{}")
        elif self.path == "/v1/models":
            self.send_body(b'{"data":[{"id":"fixture","meta":{"n_ctx":128000}}]}')
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self.send_error(404)
            return
        self.server.steps += 1
        try:
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            delta = response(self.server.steps, body)
        except Exception as error:
            self.server.errors.append(f"request {self.server.steps}: {error!r}")
            self.send_body(b'{"error":{"message":"fixture assertion failed"}}', status=400)
            return
        reason = "tool_calls" if "tool_calls" in delta else "stop"
        chunks = [
            {"index": 0, "delta": delta, "finish_reason": None},
            {"index": 0, "delta": {}, "finish_reason": reason},
        ]
        data = "".join(f"data: {json.dumps({'choices': [chunk]})}\n\n" for chunk in chunks)
        self.send_body((data + "data: [DONE]\n\n").encode(), "text/event-stream")


def main():
    maki = shutil.which(sys.argv[1] if len(sys.argv) > 1 else "maki")
    if not maki:
        raise SystemExit("Maki executable not found")
    with tempfile.TemporaryDirectory() as tmp, HTTPServer(("127.0.0.1", 0), Fixture) as server:
        root = Path(tmp)
        home, work = root / "home", root / "work"
        plugins = home / ".local/share/maki/site/pack/local/start"
        cache = home / ".cache/maki"
        work.mkdir()
        plugins.mkdir(parents=True)
        cache.mkdir(parents=True)
        (plugins / "notes").symlink_to(Path(__file__).resolve().parents[1], target_is_directory=True)
        (cache / "models-dev-catalog.json").write_text("{}", encoding="utf-8")
        server.steps, server.errors = 0, []
        thread = Thread(target=server.serve_forever)
        thread.start()
        try:
            run = subprocess.run(
                [os.path.abspath(maki), "-p", "--output-format", "json", "-m", "llama-cpp/fixture", "Run fixture"],
                cwd=work,
                env={
                    "HOME": str(home),
                    "PATH": os.defpath,
                    "MAKI_DISABLE_AUTOCOMPACT": "1",
                    "LLAMA_CPP_HOST": f"http://127.0.0.1:{server.server_port}",
                },
                capture_output=True,
                text=True,
                timeout=30,
            )
        finally:
            server.shutdown()
            thread.join()
        assert not server.errors, server.errors
        assert run.returncode == 0, (run.stdout, run.stderr)
        assert server.steps == 4, (server.steps, run.stdout, run.stderr)
        result = json.loads(run.stdout)
        assert result["is_error"] is False and result["result"].endswith("E2E_OK"), result
    print("compaction reminder end-to-end test passed")


if __name__ == "__main__":
    main()
