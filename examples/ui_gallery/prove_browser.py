"""Exercise real canvas input with agent-browser and retain actual screenshots."""
import json
import subprocess

SESSION = "polyworld-ui-gallery"


def browser(*args):
    return subprocess.run(
        ["agent-browser", "--session", SESSION, *args], check=True,
        text=True, stdout=subprocess.PIPE).stdout


def wait(expression):
    browser("wait", "--fn", expression)


def snapshot():
    return json.loads(browser("eval", "(() => window.__polyworldUiGallery.snapshot())()"))


def frames():
    frame = snapshot()["frame"]
    wait(f"window.__polyworldUiGallery.snapshot().frame >= {frame + 2}")


def click(x, y):
    browser("mouse", "move", str(x), str(y))
    frames()
    browser("mouse", "down")
    frames()
    browser("mouse", "up")
    frames()


subprocess.run(["agent-browser", "session", "list"], check=True)
server = subprocess.Popen([
    "python3", "-m", "http.server", "8898", "--bind", "127.0.0.1",
    "--directory", "tmp/ui-gallery"], stdout=subprocess.DEVNULL)
try:
    browser("open", "about:blank")
    browser("set", "viewport", "960", "720")
    browser("open", "http://127.0.0.1:8898/index.html")
    wait("window.__polyworldUiGallery && window.__polyworldUiGallery.snapshot().tab === 0")
    click(170, 398)
    wait("window.__polyworldUiGallery.snapshot().inspected")
    browser("screenshot", "tmp/ui-gallery/character.png")
    click(180, 130)
    wait("window.__polyworldUiGallery.snapshot().tab === 1")
    click(150, 300)
    browser("press", "End")
    frames()
    for _ in range(4):
        browser("press", "Backspace")
        frames()
    browser("keyboard", "type", "Nora")
    wait("window.__polyworldUiGallery.snapshot().playerName === 'Nora'")
    click(54, 340)
    wait("!window.__polyworldUiGallery.snapshot().hints")
    browser("mouse", "move", "620", "412")
    frames()
    browser("mouse", "down")
    frames()
    browser("mouse", "move", "240", "412")
    frames()
    browser("mouse", "up")
    frames()
    assert 0.1 < snapshot()["volume"] < 0.4
    click(150, 490)
    browser("screenshot", "tmp/ui-gallery/dropdown.png")
    click(150, 600)
    wait("window.__polyworldUiGallery.snapshot().difficulty === 'Hard'")
    browser("screenshot", "tmp/ui-gallery/settings.png")
    click(150, 575)
    click(150, 650)
    wait("window.__polyworldUiGallery.snapshot().theme === 'Parchment'")
    browser("screenshot", "tmp/ui-gallery/parchment.png")
    click(290, 130)
    wait("window.__polyworldUiGallery.snapshot().tab === 2")
    click(110, 474)
    assert snapshot()["gold"] == 0
    click(100, 397)
    wait("window.__polyworldUiGallery.snapshot().crossingFound")
    click(110, 474)
    wait("window.__polyworldUiGallery.snapshot().claimed")
    click(110, 474)
    assert snapshot()["gold"] == 25
    browser("screenshot", "tmp/ui-gallery/quest.png")
    browser("set", "viewport", "360", "640")
    wait("window.__polyworldUiGallery.snapshot().width === 360")
    browser("screenshot", "tmp/ui-gallery/narrow.png")
    browser("mouse", "move", "200", "540")
    browser("mouse", "wheel", "320")
    wait("Math.abs(window.__polyworldUiGallery.snapshot().scrollY) > 0")
    browser("screenshot", "tmp/ui-gallery/narrow-scrolled.png")
    print(snapshot())
    print("Live gallery input, disabled actions, theme, resize and scroll proof passed")
finally:
    subprocess.run(["agent-browser", "--session", SESSION, "screenshot", "tmp/ui-gallery/final.png"], check=False)
    for command in ["console", "errors", "close"]:
        subprocess.run(["agent-browser", "--session", SESSION, command], check=False)
    server.terminate()
    server.wait(timeout=10)
