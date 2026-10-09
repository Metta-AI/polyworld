#!/usr/bin/env python3
"""Compare actual primitive assembly against a Git revision, without a GL context.

Native uses the complete production modules. JS/WASM extract unchanged CPU
primitive functions because OpenGL bindings target native/Emscripten, not Nim JS.
"""
import argparse, os, pathlib, subprocess, tempfile
ROOT = pathlib.Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--baseline', required=True)
p.add_argument('--nim', default='nim')
p.add_argument('--backend', choices=['native', 'js', 'wasm'], default='native')
a = p.parse_args()
output = pathlib.Path(tempfile.mkdtemp(prefix='polyworld-shape-verify-'))
old = subprocess.check_output(['git', 'show', a.baseline+':src/polyworld/shapes.nim'], cwd=ROOT, text=True)
new = (ROOT/'src/polyworld/shapes.nim').read_text()
def cpu_only(source):
    constants = source[source.index('  VertexFloats ='):source.index('  ShaderTarget =')]
    functions = source[source.index('proc clear*('):source.index('proc draw*(')]
    return ('import std/math\nimport chroma, vmath\nconst\n'+constants+
            'type ShapeRenderer* = object\n  vertices: seq[float32]\n'+functions)
if a.backend != 'native':
    old = cpu_only(old)
    target = output/'polyworld'
    target.mkdir()
    (target/'shapes.nim').write_text(cpu_only(new))
(output/'shape_reference.nim').write_text(old)
(output/'test_shape_batching.nim').write_text((ROOT/'tests/test_shape_batching.nim').read_text())
command = [a.nim, 'js' if a.backend == 'js' else 'c', '-d:release',
           '--path:'+str(ROOT/'src'), '--path:'+str(output), '--nimcache:'+str(output/'cache'),
           '--out:'+str(output/('test.js' if a.backend != 'native' else 'test'))]
if a.backend == 'wasm':
    command += ['--os:linux', '--cpu:wasm32', '--cc:clang', '--clang.exe:emcc',
                '--clang.linkerexe:emcc', '--threads:off', '--mm:arc',
                '--exceptions:goto', '-d:noSignalHandler',
                '--passL:-sALLOW_MEMORY_GROWTH -sSTACK_SIZE=4194304']
# The temporary main file does not inherit the repository config.
deps = pathlib.Path(os.environ['POLYWORLD_DEPS'])
for line in (ROOT/'coworld/dependencies.lock').read_text().splitlines():
    if not line.strip(): continue
    dep = deps/line.split()[0]
    command.append('--path:'+str(dep/'src' if (dep/'src').is_dir() else dep))
command.append(str(output/'test_shape_batching.nim'))
print('Artifacts:', output, flush=True)
subprocess.run(command, cwd=ROOT, check=True)
subprocess.run(['node', str(output/'test.js')] if a.backend != 'native' else [str(output/'test')], check=True)
