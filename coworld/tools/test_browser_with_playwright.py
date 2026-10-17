"""Exercise real WASM playback and the iframe readiness/error protocol."""
import argparse
import json
import time
from pathlib import Path
from urllib.parse import quote
from playwright.sync_api import sync_playwright

GAMES = {'gota': ('gods_of_the_arena', 28909), 'lvd': ('light_vs_dark', 28800),
         'cta': ('call_to_adventure', 28800)}


def probe_url(base, game, replay, options=''):
    """Point a test iframe at a static viewer and a public replay file."""
    directory = GAMES[game][0]
    viewer = f'{base}/examples/{directory}/emscripten/{game}.html'
    if replay:
        viewer += '#replay=' + quote(base + '/tmp/coworld/' + replay, safe='')
        viewer += options
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
            if game == 'gota':
                # Replay builds keep looping unless the page opts out.
                frame.wait_for_function('polyworldReplay.ready()')
                assert frame.evaluate('polyworldReplay.state().loop')
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


def wait_seek(frame, tick, seek_id):
    """Wait until the viewer reports a seek as landed, then return its state."""
    frame.wait_for_function(
        f'(s => s.seekId === {seek_id} && !s.seeking && s.tick === {tick})'
        '(polyworldReplay.state())', timeout=600000)
    return frame.evaluate('polyworldReplay.state()')


def check_control(base, executable, output, gpu=False):
    """Exercise the GotA replay control API, its postMessage bridge and embed.

    Seek responsiveness depends on frame cost, so it is asserted only with a
    hardware GPU. Software rendering takes seconds per frame late in a match;
    there seeks use one-second slices and the timer gaps are only recorded.
    """
    end_tick = GAMES['gota'][1]
    report = {}
    output.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as p:
        args = (['--use-angle=metal', '--enable-gpu', '--ignore-gpu-blocklist'] if gpu
                else ['--enable-unsafe-swiftshader', '--use-angle=swiftshader'])
        options = {'headless': True, 'args': args}
        if executable:
            options['executable_path'] = executable
        browser = p.chromium.launch(**options)
        page = browser.new_page(viewport={'width': 1280, 'height': 576})
        page.set_default_timeout(120000)
        errors = []
        page.on('pageerror', lambda error: errors.append(str(error)))
        slice_option = '' if gpu else '&seekSlice=1000'
        page.goto(probe_url(base, 'gota', 'gota.replay', '&embed=1&loop=0' + slice_option))
        page.wait_for_function('replayMessages.some(x => x.type === "ready")')
        frame = page.frames[1]
        frame.wait_for_function('polyworldReplay.ready()')
        replay = 'polyworldReplay'
        frame.evaluate('''() => {
          window.nextFrames = count => new Promise(resolve => {
            const stop = polyworldReplay.onFrame(() => { if (--count <= 0) { stop(); resolve(); } });
          });
        }''')
        state = frame.evaluate(replay + '.state()')
        assert not state['loop'] and len(state['viewProjection']) == 16, state
        assert state['endTick'] == end_tick, state
        frame.evaluate(replay + '.pause()')

        # A cold seek to the end runs in slices: page timers keep firing and
        # frames report progress until the seek lands exactly.
        frame.evaluate('''() => {
          window.heartbeat = {last: performance.now(), worst: 0};
          setInterval(() => {
            const now = performance.now();
            heartbeat.worst = Math.max(heartbeat.worst, now - heartbeat.last);
            heartbeat.last = now;
          }, 10);
          window.seekTicks = new Set();
          polyworldReplay.onFrame(s => { if (s.seeking) seekTicks.add(s.tick); });
        }''')
        frame.evaluate('nextFrames(2)')
        frame.evaluate('() => { heartbeat.worst = 0; }')
        started = time.monotonic()
        frame.evaluate(f'{replay}.seek({end_tick}, 1)')
        state = wait_seek(frame, end_tick, 1)
        report['cold_end_seek'] = {
            'seconds': round(time.monotonic() - started, 1),
            'worst_timer_gap_ms': round(frame.evaluate('heartbeat.worst')),
            'progress_frames': frame.evaluate('seekTicks.size')}
        assert not state['playing'], state
        assert report['cold_end_seek']['progress_frames'] >= 3, report
        if gpu:
            # Unsliced, this seek blocked the page for the whole seek.
            assert report['cold_end_seek']['worst_timer_gap_ms'] < 1000, report
            assert report['cold_end_seek']['progress_frames'] >= 100, report
        print('control: cold seek to last tick landed', report['cold_end_seek'], flush=True)

        # Exact seeks in both directions, then cancel a long forward seek.
        for seek_id, tick in enumerate([3000, 12000, 500, end_tick, 1500], start=2):
            frame.evaluate(f'{replay}.seek({tick}, {seek_id})')
            wait_seek(frame, tick, seek_id)
        frame.evaluate(f'{replay}.seek({end_tick}, 9)')
        frame.wait_for_function('(s => s.seeking && s.tick > 1600)(polyworldReplay.state())')
        frame.evaluate(replay + '.cancelSeek()')
        frame.evaluate('nextFrames(1)')
        cancelled = frame.evaluate(replay + '.state()')
        assert not cancelled['seeking'] and cancelled['seekId'] == 9, cancelled
        frame.evaluate('nextFrames(3)')
        state = frame.evaluate(replay + '.state()')
        assert state['tick'] == cancelled['tick'] < end_tick and not state['playing'], state
        report['cancelled_at'] = cancelled['tick']
        print('control: exact seeks, pause and cancel passed', flush=True)

        # Speeds map onto the supported multipliers and playback advances.
        assert frame.evaluate(replay + '.setSpeed(8)') == 4
        assert frame.evaluate(replay + '.setSpeed(2)') == 2
        frame.evaluate(replay + '.play()')
        first = frame.evaluate(replay + '.state().tick')
        page.wait_for_timeout(2000)
        state = frame.evaluate(replay + '.state()')
        frame.evaluate(replay + '.pause()')
        assert state['playing'] and state['speed'] == 2 and state['tick'] > first, state
        report['ticks_per_second_at_2x'] = (state['tick'] - first) / 2
        print('control: speed passed', flush=True)

        # A frozen camera holds still while playing; projection round-trips.
        frame.evaluate(replay + ".camera({mode: 'fixed', x: 0, z: 0, distance: 40})")
        frame.evaluate('nextFrames(2)')
        frame.evaluate(replay + '.freezeCamera()')
        frame.evaluate(replay + '.play()')
        frame.evaluate('nextFrames(1)')
        matrix = frame.evaluate(replay + '.state().viewProjection')
        frame.evaluate('nextFrames(3)')
        assert frame.evaluate(replay + '.state().viewProjection') == matrix
        frame.evaluate(replay + '.pause()')
        errors_px = frame.evaluate('''() => {
          const out = [];
          for (let x = 200; x <= 1080; x += 110) for (let y = 100; y <= 476; y += 94) {
            const world = polyworldReplay.unproject({x, y});
            if (!world) continue;
            const back = polyworldReplay.project(world);
            out.push(Math.hypot(back.x - x, back.y - y));
          }
          return out.sort((a, b) => a - b);
        }''')
        p90 = errors_px[len(errors_px) * 9 // 10]
        assert len(errors_px) >= 30 and p90 < 0.5, errors_px
        report['round_trip_px_p90'] = p90

        # Picking at a projected hero torso returns that hero.
        heroes = [(frame.evaluate(f'{replay}.unit({hero})') or {}) | {'id': hero}
                  for hero in range(100, 110)]
        assert all(h.get('seat') == h['id'] - 100 for h in heroes), heroes
        alive = [h['id'] for h in heroes if h['alive']]
        hits = 0
        for hero in alive:
            unit = frame.evaluate(f'{replay}.unit({hero})')
            frame.evaluate(f"{replay}.camera({{mode: 'fixed', x: {unit['x']}, z: {unit['z']}, distance: 20}})")
            frame.evaluate('nextFrames(2)')
            unit = frame.evaluate(f'{replay}.unit({hero})')
            screen = frame.evaluate(f"{replay}.project({{x: {unit['x']}, y: {unit['y']} + 0.8, z: {unit['z']}}})")
            hits += frame.evaluate(f'{replay}.pick({json.dumps(screen)})') == hero
        report['picks'] = {'alive': len(alive), 'hits': hits}
        assert alive and hits >= len(alive) * 0.6, report['picks']
        print('control: projection and picking passed', report['picks'], flush=True)

        # The same commands work over postMessage, with throttled tick events.
        page.evaluate('''() => {
          replayMessages.length = 0;
          sendReplay({type: 'subscribe', tick: true});
          sendReplay({type: 'seek', tick: 4000, seekId: 20});
          sendReplay({type: 'project', x: 0, y: 0, z: 0, requestId: 'p1'});
        }''')
        page.wait_for_function('replayMessages.some(m => m.type === "tick" && '
                               'm.seekId === 20 && !m.seeking && m.tick === 4000)', timeout=600000)
        page.wait_for_function('replayMessages.some(m => m.requestId === "p1")')
        result = page.evaluate('replayMessages.find(m => m.requestId === "p1")')
        assert result['result'] and 'x' in result['result'], result
        page.evaluate("() => { replayMessages.length = 0; sendReplay({type: 'speed', speed: 16}); sendReplay({type: 'play'}); }")
        page.wait_for_timeout(2000)
        page.evaluate("() => sendReplay({type: 'pause'})")
        page.wait_for_function('replayMessages.some(m => m.type === "tick" && !m.playing)')
        ticks = page.evaluate('replayMessages.filter(m => m.type === "tick")')
        assert 2 <= len(ticks) <= 25 and any(t['speed'] == 16 for t in ticks), ticks
        assert not page.evaluate('replayMessages.some(m => m.type === "frame")')
        print('control: postMessage bridge passed', flush=True)

        # Embedded viewers keep input from the game and forward keys.
        page.evaluate('() => { replayMessages.length = 0; }')
        frame.evaluate(replay + '.freezeCamera()')
        frame.evaluate('nextFrames(2)')
        matrix = frame.evaluate(replay + '.state().viewProjection')
        page.mouse.move(640, 288)
        page.mouse.wheel(0, -600)
        page.mouse.click(640, 288)
        frame.locator('canvas').focus()
        page.keyboard.press('Space')
        frame.evaluate('nextFrames(3)')
        state = frame.evaluate(replay + '.state()')
        assert not state['playing'] and state['viewProjection'] == matrix, state
        keys = page.evaluate('replayMessages.filter(m => m.type === "key")')
        assert any(k['event'] == 'keydown' and k['code'] == 'Space' for k in keys), keys
        page.screenshot(path=str(output / 'gota-embed.png'))
        print('control: embed input and key forwarding passed', flush=True)
        assert not errors, errors
        assert not frame.evaluate('failed')
        browser.close()
    (output / 'control.json').write_text(json.dumps(report, indent=2) + '\n')


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
    parser.add_argument('--control-only', action='store_true',
                        help='Only check the GotA replay control API')
    parser.add_argument('--gpu', action='store_true',
                        help='Check replay control with hardware rendering (macOS Metal)')
    args = parser.parse_args()
    if args.director or args.director_layout:
        check_director(args.base, args.executable, args.output, args.games,
                       args.director_layout)
    elif args.control_only:
        check_control(args.base, args.executable, args.output, args.gpu)
    else:
        check_browser(args.base, args.executable, args.output, args.games)
        if 'gota' in args.games:
            check_control(args.base, args.executable, args.output, args.gpu)
