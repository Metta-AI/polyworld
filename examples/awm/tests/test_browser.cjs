// End-to-end checks against tools/serve.sh. Requires Playwright and Chrome.
const {chromium} = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const base = process.env.AWM_TEST_URL || 'http://127.0.0.1:8080';
const output = path.resolve(__dirname, '../build/test-output');
fs.mkdirSync(output, {recursive: true});

(async () => {
  const browser = await chromium.launch({
    ...(process.env.CHROME_PATH ? {executablePath: process.env.CHROME_PATH} : {channel: 'chrome'}),
    headless: true,
    args: ['--enable-unsafe-swiftshader'],
  });
  const errors = [];
  async function gamePage(query, deviceScaleFactor = 1, route = null) {
    const page = await browser.newPage({viewport: {width: 1440, height: 900}, deviceScaleFactor});
    page.on('pageerror', e => { errors.push(e.stack || e.message); console.error(e.stack || e.message); });
    page.on('console', msg => { if (msg.type() === 'error') errors.push(msg.text()); });
    const url = route ? `${base}${route}${query ? '?' + query : ''}` : `${base}/awm.html?${query}`;
    await page.goto(url);
    await page.waitForFunction(() => document.querySelector('#game-status').textContent.includes('Turn '), {}, {timeout: 60000});
    console.log('Opened', route || query);
    return page;
  }
  async function waitText(page, text) {
    await page.waitForFunction(value => document.querySelector('#game-status').textContent.includes(value), text, {timeout: 30000});
  }
  const status = page => page.locator('#game-status').textContent();
  try {
    const local = await gamePage('', 1, '/client/player');
    await waitText(local, 'Your turn.');
    await waitText(local, 'Active player 1.');
    // The dealt card must reach the hand before it can be clicked.
    await waitText(local, 'Ready for your action.');
    const opening = await status(local);
    assert.match(opening, /Player 1 Archer: life 20, energy 1\/1/);
    // Human plays Bolt, chooses the opposite hero and pays its energy.
    await local.mouse.click(735, 675);
    await waitText(local, 'highlighted avatar');
    await local.mouse.click(1090, 375);
    await waitText(local, 'Bolt resolves');
    assert.match(await status(local), /Player 2 Mage: life 18/);
    assert.match(await status(local), /Player 1 Archer: life 20, energy 0\/1/);
    await local.screenshot({path: path.join(output, 'local-bolt.png')});
    // Allow VFX to finish before the UI accepts the turn button.
    await waitText(local, 'Ready for your action.');
    await local.mouse.click(1345, 860);
    await waitText(local, 'opponent is thinking');
    await waitText(local, 'Your turn.');
    assert.match(await status(local), /energy 2\/2/);
    await local.screenshot({path: path.join(output, 'local-player.png')});
    await local.close();

    // A new tab creates an independent local deal. No global state is imported.
    const fresh = await gamePage('mode=local&class=warrior&opponent=archer&seed=42');
    assert.match(await status(fresh), /Player 1 Warrior/);
    assert.match(await status(fresh), /Player 2 Archer/);
    await fresh.close();

    // CSS mouse coordinates must still hit cards/HUD on Retina displays.
    const retina = await gamePage('mode=local&opponent=warrior', 2);
    await waitText(retina, 'Ready for your action.');
    await retina.mouse.click(735, 675);
    await waitText(retina, 'highlighted avatar');
    await retina.mouse.click(1090, 375);
    await waitText(retina, 'Bolt resolves');
    assert.match(await status(retina), /Player 2 Warrior: life 18/);
    await waitText(retina, 'Ready for your action.');
    await retina.mouse.click(1345, 860);
    await waitText(retina, 'opponent is thinking');
    await retina.screenshot({path: path.join(output, 'local-retina.png')});
    await retina.close();


    const first = await gamePage('', 1, '/client/global');
    const second = await gamePage('', 1, '/client/global');
    await waitText(first, 'Watching the shared global match');
    await waitText(second, 'Watching the shared global match');
    let synced = false;
    const revision = text => text.match(/Match (.+)\. Revision (\d+)\./)?.slice(1).join(':');
    for (let i = 0; i < 40; i++) {
      const [a, b] = await Promise.all([status(first), status(second)]);
      if (revision(a) && revision(a) === revision(b)) { synced = true; break; }
      await first.waitForTimeout(250);
    }
    assert.ok(synced, 'both spectators receive the same match and revision');
    await first.mouse.click(735, 675);
    await first.mouse.click(1345, 860);
    assert.match(await status(first), /Global spectator\. Watching the shared global match/);
    assert.doesNotMatch(await status(first), /Click the highlighted|Pass to Player/);
    await first.screenshot({path: path.join(output, 'global-spectator.png')});
    await first.close();
    await second.close();
    assert.deepEqual(errors, [], 'browser must not report JS/Wasm/WebGL errors');
    console.log('PASS: local card/target/energy/bot turns, independent deals, Retina picking, shared spectators, read-only controls, no browser errors.');
  } catch (error) {
    for (const [index, page] of browser.contexts().flatMap(context => context.pages()).entries()) {
      console.error('Page state:', await status(page).catch(() => 'unavailable'));
      await page.screenshot({path: path.join(output, `failure-${index}.png`)}).catch(() => {});
    }
    console.error('Browser errors:', errors);
    throw error;
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
