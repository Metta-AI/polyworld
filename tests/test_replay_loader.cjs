const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const zlib = require('node:zlib');

const Limit = 64 * 1024 * 1024;
const Shell = fs.readFileSync(
  path.join(__dirname, '../src/polyworld/replay.html'), 'utf8'
).match(/<script>([\s\S]*?)<\/script>/)[1];

// Runs the actual browser loader with standard Fetch streams and a mocked VM.
async function load(response, uri = '#replay=fixture') {
  const messages = [], elements = new Map(), files = new Map();
  let finish;
  const complete = new Promise(resolve => { finish = resolve; });
  const window = {
    addEventListener() {},
    parent: {postMessage(value) {
      messages.push(value);
      if (value.type === 'error') finish();
    }}
  };
  const context = vm.createContext({
    console, window, URLSearchParams, Uint8Array, Blob, DecompressionStream,
    location: {hash: uri, search: ''},
    document: {getElementById(id) {
      if (!elements.has(id)) elements.set(id, {addEventListener() {}});
      return elements.get(id);
    }},
    fetch: async () => response,
    addRunDependency() {},
    removeRunDependency() { finish(); },
    FS: {
      mkdirTree() {},
      writeFile(name, bytes) { files.set(name, bytes); }
    },
    setTimeout
  });
  const timer = setTimeout(() => {
    finish();
    throw new Error('Replay loader did not finish.');
  }, 10000);
  try {
    vm.runInContext(Shell, context);
    context.Module.preRun[0]();
    await complete;
  } finally {
    clearTimeout(timer);
  }
  return {context, messages, elements, files};
}

// Confirms failures never install a replay or announce a ready viewer.
function assertFailure(result, expected) {
  assert.match(result.elements.get('status-detail').textContent, expected);
  assert.equal(result.files.size, 0);
  assert.equal(vm.runInContext('failed && !ready', result.context), true);
  result.context.Module.polyworldFrame(0, 0);
  assert.equal(vm.runInContext('ready', result.context), false);
  assert.equal(result.messages.filter(value => value.type === 'error').length, 1);
  assert.equal(result.messages.some(value => value.type === 'ready'), false);
}

// Checks successful decoding, exact limits, early cancellation, and errors.
async function main() {
  const payload = Buffer.from('POLYWORLDREPLAY fixture bytes');
  for (const encoded of [
    payload, zlib.gzipSync(payload), zlib.deflateSync(payload)
  ]) {
    const response = new Response(encoded);
    response.arrayBuffer = () => { throw new Error('Unbounded body read.'); };
    const result = await load(response);
    assert.deepEqual(Buffer.from(result.files.get('/episode.replay')), payload);
    assert.equal(result.messages.some(value => value.type === 'error'), false);
    const fetched = result.messages.find(
      value => value.phase === 'replay_fetch_end'
    );
    assert.equal(fetched.bytes, encoded.length);
    assert.equal(fetched.compressed, encoded !== payload);
  }
  console.log('PASS raw, gzip, and zlib replay streams');

  let index = 0;
  const fragmented = await load(new Response(new ReadableStream({
    pull(controller) {
      if (index === payload.length) controller.close();
      else {
        controller.enqueue(payload.subarray(index, index + 1));
        index++;
      }
    }
  })));
  assert.deepEqual(Buffer.from(fragmented.files.get('/episode.replay')), payload);
  const patterned = Buffer.alloc(100003);
  for (let i = 0; i < patterned.length; i++) patterned[i] = i % 251;
  let position = 0;
  const grown = await load(new Response(new ReadableStream({
    pull(controller) {
      if (position === patterned.length) controller.close();
      else {
        const end = Math.min(patterned.length, position + 4093);
        controller.enqueue(patterned.subarray(position, end));
        position = end;
      }
    }
  })));
  assert.deepEqual(Buffer.from(grown.files.get('/episode.replay')), patterned);
  console.log('PASS fragmented replay downloads');

  for (const total of [Limit, Limit * 16]) {
    const chunk = new Uint8Array(1024 * 1024);
    let transferred = 0, canceled = false, exhausted = false;
    const response = new Response(new ReadableStream({
      pull(controller) {
        if (transferred === total) {
          exhausted = true;
          controller.close();
        } else {
          controller.enqueue(chunk);
          transferred += chunk.length;
        }
      },
      cancel() { canceled = true; }
    }, {highWaterMark: 0}));
    const result = await load(response);
    if (total === Limit) {
      assert.equal(result.files.get('/episode.replay').length, Limit);
      assert.equal(exhausted, true);
      assert.equal(canceled, false);
    } else {
      assertFailure(result, /exceeds the 64 MiB limit/);
      assert.equal(canceled, true);
      assert.equal(exhausted, false);
      assert.equal(transferred, Limit + chunk.length);
    }
  }
  console.log('PASS exact size limit and early oversized download cancellation');

  const oversized = zlib.gzipSync(Buffer.alloc(Limit + 1));
  assertFailure(await load(new Response(oversized)), /64 MiB limit/);
  assertFailure(await load(new Response()), /empty/);
  assertFailure(await load(new Response(null, {status: 404})), /HTTP 404/);
  assertFailure(await load(new Response(), ''), /No replay was supplied/);
  assertFailure(await load(new Response(new ReadableStream({
    pull(controller) { controller.error(new Error('Network interrupted.')); }
  }))), /Network interrupted/);
  console.log('PASS decoded limit and visible loading failures');
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
