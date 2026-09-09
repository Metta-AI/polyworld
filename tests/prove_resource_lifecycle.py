"""Retain a browser capture after the real WebGL lifecycle assertions pass."""
import subprocess

SESSION = "polyworld-resource-lifecycle"


def browser(*args):
    subprocess.run(["agent-browser", "--session", SESSION, *args], check=True)


subprocess.run(["agent-browser", "session", "list"], check=True)
server = subprocess.Popen([
    "python3", "-m", "http.server", "8879", "--bind", "127.0.0.1",
    "--directory", "tmp/resource-lifecycle"], stdout=subprocess.DEVNULL)
try:
    browser("open", "about:blank")
    browser("set", "viewport", "256", "256")
    browser("open", "http://127.0.0.1:8879/index.html")
    browser("wait", "--fn", "window.__polyworldResourceProof?.passed === true")
    browser("screenshot", "tmp/resource-lifecycle/webgl.png")
finally:
    for command in ["console", "errors", "close"]:
        subprocess.run(["agent-browser", "--session", SESSION, command], check=False)
    server.terminate()
    server.wait(timeout=10)
