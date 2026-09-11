"""Exercise real WASM playback and the iframe readiness/error protocol."""
import argparse
import json
import time
from pathlib import Path
from urllib.parse import quote
from playwright.sync_api import sync_playwright

GAMES = {'gota': ('gods_of_the_arena', 18680), 'lvd': ('light_vs_dark', 28800),
         'cta': ('call_to_adventure', 28800)}


def probe_url(base, game, replay):
    """Point a test iframe at a static viewer and a public replay file."""
    directory = GAMES[game][0]
    viewer = f'{base}/examples/{directory}/emscripten/{game}.html'
    if replay:
        viewer += '#replay=' + quote(base + '/tmp/coworld/' + replay, safe='')
    return base + '/coworld/tools/replay_probe.html?viewer=' + quote(viewer, safe='')


def click(page, x, y):
    """Hold a real mouse press across frames on software-rendered browsers."""
    page.mouse.move(x, y)
    page.mouse.down()
    page.wait_for_timeout(500)
    page.mouse.up()
    page.wait_for_timeout(500)


def check_browser(base, executable, output, games):
    """Verify rendering, replay determinism, controls, resize and visible errors."""
    report_path = output / 'browser.json'
    report = json.loads(report_path.read_text()) if report_path.exists() else {}
    output.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as p:
        options = {'headless': True, 'args': ['--enable-unsafe-swiftshader', '--use-angle=swiftshader']}
        if executable:
            options['executable_path'] = executable
        browser = p.chromium.launch(**options)
        page = browser.new_page(viewport={'width': 1280, 'height': 576})
        page.set_default_navigation_timeout(180000)
        for game in games:
            _, end_tick = GAMES[game]
            page.goto(probe_url(base, game, game + '.replay'))
            page.wait_for_function('replayMessages.some(x => x.type === "ready")', timeout=120000)
            frame = page.frames[1]
            assert not frame.evaluate('failed')
            assert frame.evaluate('Module.replayTick') >= 0
            page.screenshot(path=str(output / (game + '.png')), timeout=180000)
            print(game + ': first frame rendered', flush=True)
            # Turn looping off, then seek forward through every recorded tick.
            click(page, 210, 556)
            page.wait_for_timeout(100)
            click(page, 166, 556)
            frame.wait_for_function('Module.replayTick === ' + str(end_tick), timeout=600000)
            assert not frame.evaluate('failed'), frame.locator('#status').inner_text()
            report[game] = {'end_tick': end_tick, 'messages': page.evaluate('replayMessages')}
            # Rewind, change speed, then resize the real iframe canvas.
            click(page, 22, 556)
            page.wait_for_timeout(200)
            click(page, 362, 556)
            frame.wait_for_function('Module.replayTick < 2000', timeout=30000)
            page.set_viewport_size({'width': 960, 'height': 640})
            frame.wait_for_function('Module.canvas.width === 960 && Module.canvas.height === 640')
            page.set_viewport_size({'width': 1280, 'height': 576})
            report_path.write_text(json.dumps(report, indent=2) + '\n')
            print(game + ': full replay, seek, speed and resize passed', flush=True)
        for fixture in ['', 'corrupt.replay', 'divergent.replay']:
            page.goto(probe_url(base, 'cta', fixture))
            page.wait_for_function('replayMessages.some(x => x.type === "error")', timeout=120000)
            frame = page.frames[1]
            assert frame.locator('#status').is_visible()
            report[fixture or 'missing'] = page.evaluate('replayMessages')
            print((fixture or 'missing') + ': visible error passed', flush=True)
        browser.close()
    (output / 'browser.json').write_text(json.dumps(report, indent=2) + '\n')


def check_director(base, executable, output, games, layout_only=False):
    """Check fixed framing and viewing-time scheduling in directorProbe builds."""
    output.mkdir(parents=True, exist_ok=True)
    distances = {'gota': 17, 'lvd': 17, 'cta': 13}
    report = {}
    with sync_playwright() as p:
        options = {'headless': True, 'args': ['--enable-unsafe-swiftshader',
                   '--use-angle=swiftshader']}
        if executable:
            options['executable_path'] = executable
        browser = p.chromium.launch(**options)
        page = browser.new_page(viewport={'width': 1280, 'height': 800})
        page.set_default_timeout(120000)
        errors = []
        page.on('pageerror', lambda error: errors.append(str(error)))
        for game in ([] if layout_only else games):
            directory = GAMES[game][0]
            url = (f'{base}/examples/{directory}/emscripten/{game}.html'
                   '?replay=../replays/demo.replay&speed=16')
            page.goto(url)
            page.wait_for_function('typeof Module !== "undefined" && '
                                   'Module.directorProbe && loading.hidden')
            samples = []
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                sample = page.evaluate('Module.directorProbe')
                assert sample['distance'] == distances[game], sample
                assert sample['locked'] or sample['finalResults'], sample
                assert sample.get('mismatches', 0) == 0, sample
                assert not page.evaluate('failed'), game
                samples.append(sample)
                if len(samples) == 3:
                    page.screenshot(path=str(output / f'{game}-world.png'))
                if sample['overview']:
                    page.screenshot(path=str(output / f'{game}-overview.png'))
                if sample['finalResults']:
                    page.screenshot(path=str(output / f'{game}-final.png'))
                    break
                page.wait_for_timeout(500)
            assert not errors, errors
            # Seek to the actual replay end, then observe a complete final card.
            click(page, 166, 780)
            page.wait_for_function('Module.directorProbe.finalResults')
            final_start = page.evaluate('Module.directorProbe.time')
            page.screenshot(path=str(output / f'{game}-final.png'))
            page.wait_for_function('!Module.directorProbe.finalResults')
            assert page.evaluate('Module.directorProbe.time') - final_start >= 3.5
            assert page.evaluate('Module.directorProbe.mismatches || 0') == 0
            # Pause uses the actual transport keyboard handler.
            page.keyboard.press('Space')
            page.wait_for_function('!Module.directorProbe.playing')
            paused = page.evaluate('Module.directorProbe.time')
            page.wait_for_timeout(1200)
            assert page.evaluate('Module.directorProbe.time') == paused
            page.keyboard.press('Space')
            page.wait_for_function('Module.directorProbe.playing')
            # Exercise the browser visibility listener, including a resume gap.
            page.evaluate('''() => {
              Object.defineProperty(document, 'hidden', {
                configurable: true, value: true
              });
              document.dispatchEvent(new Event('visibilitychange'));
            }''')
            page.wait_for_timeout(250)
            hidden = page.evaluate('Module.directorProbe.time')
            page.wait_for_timeout(1200)
            assert page.evaluate('Module.directorProbe.time') == hidden
            page.evaluate('''() => {
              delete document.hidden;
              document.dispatchEvent(new Event('visibilitychange'));
            }''')
            page.wait_for_timeout(300)
            assert page.evaluate('Module.directorProbe.time') - hidden < 0.6
            # A manual pan disables both automatic camera and overview.
            page.keyboard.down('ArrowRight')
            page.wait_for_timeout(250)
            page.keyboard.up('ArrowRight')
            page.wait_for_function('!Module.directorProbe.enabled')
            assert not page.evaluate('Module.directorProbe.overview')
            report[game] = samples
            (output / 'director.json').write_text(json.dumps(report, indent=2) + '\n')
            print(game + ': fixed zoom, replay, pause, visibility, manual pan passed',
                  flush=True)
        # Three simultaneous replay canvases use the same game defaults.
        page.set_viewport_size({'width': 1440, 'height': 900})
        frames = []
        for game in games:
            directory = GAMES[game][0]
            frames.append(f'<iframe title="{game}" style="flex:1;width:0;'
                          f'height:100%;border:0" src="{base}/examples/{directory}'
                          f'/emscripten/{game}.html?replay=../replays/demo.replay'
                          '&speed=4"></iframe>')
        layout_page = output / 'columns.html'
        layout_page.write_text('<body style="margin:0;display:flex;height:100vh">'
                               + ''.join(frames) + '</body>')
        relative = layout_page.resolve().relative_to(Path(__file__).resolve().parents[2])
        page.goto(base + '/' + relative.as_posix())
        for frame in page.frames[1:]:
            frame.wait_for_function('typeof Module !== "undefined" && '
                                    'Module.directorProbe && loading.hidden')
        page.wait_for_timeout(5000)
        page.screenshot(path=str(output / 'three-columns.png'))
        for game, frame in zip(games, page.frames[1:]):
            sample = frame.evaluate('Module.directorProbe')
            assert sample['distance'] == distances[game], sample
            assert sample['locked'], sample
        browser.close()
    if report:
        (output / 'director.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--base', default='http://localhost:8765')
    parser.add_argument('--executable')
    parser.add_argument('--output', type=Path, default=Path('tmp/coworld/browser'))
    parser.add_argument('--games', nargs='+', choices=list(GAMES), default=list(GAMES))
    parser.add_argument('--director', action='store_true',
                        help='Test viewers built with -d:directorProbe')
    parser.add_argument('--director-layout', action='store_true',
                        help='Only inspect the three-column director layout')
    args = parser.parse_args()
    if args.director or args.director_layout:
        check_director(args.base, args.executable, args.output, args.games,
                       args.director_layout)
    else:
        check_browser(args.base, args.executable, args.output, args.games)
