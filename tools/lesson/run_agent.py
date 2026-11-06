"""First lesson: a real LLM selects one sandbox tool call at a time.

Uses the configured local smolagents demo credentials without copying them into
the repository or logs. Start Godot's agent_transport scene, then --serve or --demo.
The environment and schema-v6 record remain authoritative in Godot.
"""
import argparse
import json
import os
import re
import socket
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "tools/video/lesson01"
SYSTEM = """你是沙盒中的运输智能体。根据用户目标选择操作。每轮只输出一个 JSON 对象，
格式 {"tool":"工具名","args":{...}}，不加 Markdown、不输出思维过程。
工具：observe {} 读取地图与状态；move {"node":"节点名"} 只移动一条相邻道路，
不会自动寻路；pickup {"crate":"方块名"} 在当前位置装一个方块；drop {} 卸货；
finish {"text":"简短结果"} 结束。先观测，再行动。工具返回的 state 是最新观测。
道路可能在执行期间变化，以最新 blocked_edges 为准。禁止穿越封路；自行根据地图选择相邻节点。
carrier 是运输车的位置；crates 是各方块位置；carrying 是正在装载的方块。
抵达目标后必须 drop，之后 observe 检查；只有状态符合任务才可声称完成。"""


def rpc(tool, args=None):
    with socket.create_connection(("127.0.0.1", 7321), timeout=8) as sock:
        sock.sendall((json.dumps({"tool": tool, "args": args or {}}) + "\n").encode())
        with sock.makefile("rb") as stream:
            return json.loads(stream.readline())


def credentials():
    values = {key: os.environ.get(key, "") for key in ("SMOL_API_KEY", "SMOL_BASE_URL", "SMOL_MODEL")}
    local = Path("D:/smolagents/chat.bat")
    if local.is_file():
        for line in local.read_text(encoding="utf-8").splitlines():
            match = re.match(r"set\s+(SMOL_\w+)=(.*)", line, re.I)
            if match and match[1] in values and not values[match[1]]:
                values[match[1]] = match[2].strip().strip('"')
    if not values["SMOL_API_KEY"]:
        raise RuntimeError("SMOL_API_KEY is not configured")
    from urllib.parse import urlparse
    host = urlparse(values["SMOL_BASE_URL"]).hostname
    os.environ["NO_PROXY"] = ",".join(filter(None, [os.environ.get("NO_PROXY", ""), host, "127.0.0.1", "localhost"]))
    return values


class LessonAgent:
    def __init__(self):
        from openai import OpenAI
        config = credentials()
        self.model = config["SMOL_MODEL"] or "deepseek-flash"
        self.client = OpenAI(api_key=config["SMOL_API_KEY"], base_url=config["SMOL_BASE_URL"], timeout=90, max_retries=0)
        self.messages = [{"role": "system", "content": SYSTEM}]
        self.lock = threading.Lock()

    def run(self, task):
        if not self.lock.acquire(blocking=False):
            raise RuntimeError("An agent task is already running")
        run_id = "unstarted"
        try:
            rpc("task", {"text": task})
            run_id = rpc("trace")["run"]["runId"]
            self.messages.append({"role": "user", "content": task})
            for turn in range(36):
                started = time.perf_counter()
                request = dict(model=self.model, messages=self.messages, temperature=0.1,
                    max_tokens=512, response_format={"type": "json_object"})
                request_dir = OUT / "requests"
                request_dir.mkdir(parents=True, exist_ok=True)
                request_file = run_id + "-" + uuid.uuid4().hex + ".json"
                (request_dir / request_file).write_text(json.dumps(request, ensure_ascii=False, indent=2), encoding="utf-8")
                response = self.client.chat.completions.create(**request)
                raw = response.choices[0].message.content
                call = json.loads(raw)
                rpc("model", {"model": self.model, "response": call,
                    "responseText": raw,
                    "contextFile": "requests/" + request_file,
                    "contextMessages": len(self.messages), "costMs": round((time.perf_counter()-started)*1000),
                    "tokens": response.usage.total_tokens if response.usage else 0})
                self.messages.append({"role": "assistant", "content": raw})
                tool, args = call.get("tool"), call.get("args", {})
                if tool == "finish":
                    final = str(args.get("text", "完成"))
                    rpc("reply", {"text": final})
                    return final
                if tool not in ("observe", "move", "pickup", "drop") or not isinstance(args, dict):
                    result = {"ok": False, "error": "invalid_tool_call"}
                else:
                    result = rpc(tool, args)
                self.messages.append({"role": "user", "content": "工具返回的观测：" + json.dumps(result, ensure_ascii=False)})
                print(json.dumps({"turn": turn, "tool": tool, "args": args, "ok": result.get("ok")}, ensure_ascii=False), flush=True)
                time.sleep(0.8)  # Let the live scene finish its movement before the next call.
            raise RuntimeError("Agent exceeded the 36-step task budget")
        except Exception as exc:
            rpc("reply", {"text": "运行停止：" + type(exc).__name__})
            raise
        finally:
            OUT.mkdir(parents=True, exist_ok=True)
            (OUT / (run_id + "-context.json")).write_text(json.dumps(self.messages, ensure_ascii=False, indent=2), encoding="utf-8")
            self.lock.release()


def verify_trace(doc):
    steps = doc["steps"]
    pending = None
    calls = 0
    for step in steps:
        action = step["action"]
        if action.get("tool") == "model.generate":
            pending = action["args"]["response"]
            calls += 1
        elif action.get("tool") in ("observe", "move", "pickup", "drop"):
            assert pending and pending["tool"] == action["tool"] and pending["args"] == action["args"], step["i"]
            pending = None
    changes = [s for s in steps if s["action"].get("tool") == "environment.close_road"]
    assert len(changes) == 1
    before = steps[:changes[0]["i"]]
    assert any(s["action"].get("tool") == "move" and s["output"].get("ok") for s in before)
    after = steps[changes[0]["i"]+1:]
    assert any(s["action"].get("tool") == "model.generate" for s in after)
    final = steps[-1]["world"]["entities"]
    assert final["carrying"] == "" and all(v == "D" for v in final["crates"].values()), final
    assert len([s for s in steps if s["action"].get("tool") == "dialogue.submit"]) == 2
    return {"schemaVersion": doc["schemaVersion"], "steps": len(steps), "modelCalls": calls, "closureStep": changes[0]["i"],
            "verified": "transport and collection delivered; closure after first movement", "final": final}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--demo", action="store_true")
    opts = parser.parse_args()
    agent = LessonAgent()
    if opts.demo:
        agent.run("把货物从 A 运到 D。")
        agent.run("现在把散落在 E 和 F 的蓝方块、黄方块都整理到 D。")
        doc = rpc("trace")
        report = verify_trace(doc)
        (OUT / "run.json").write_text(json.dumps(doc, ensure_ascii=False, indent=2), encoding="utf-8")
        (OUT / "verification.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps(rpc("save")), flush=True)
        print("VERIFIED", report["steps"], flush=True)
        rpc("capture")
        return
    if not opts.serve:
        parser.error("select --serve or --demo")

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            if self.path != "/task":
                self.send_error(404)
                return
            data = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            if agent.lock.locked():
                self.send_error(409)
                return
            def work():
                try: agent.run(str(data["text"]))
                except Exception as exc: print("Task failed:", type(exc).__name__, flush=True)
            threading.Thread(target=work, daemon=True).start()
            self.send_response(202)
            self.end_headers()
            self.wfile.write(b'{"accepted":true}')

    print("Lesson dialogue service http://127.0.0.1:7322", flush=True)
    ThreadingHTTPServer(("127.0.0.1", 7322), Handler).serve_forever()


if __name__ == "__main__":
    main()
