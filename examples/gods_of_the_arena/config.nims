import "../../src/polyworld/emscripten.nims"

when not defined(coworldWasm):
  setupEmscripten(thisDir(), "gota")

when defined(coworldWasm):
  when defined(coworld):
    error("Choose either the native Coworld runner or the Wasm runner.")
  switch("define", "emscripten")
  switch("define", "headless")
  switch("define", "useMalloc")
  switch("undef", "nimTypeNames")
  switch("threads", "off")
  switch("os", "linux")
  switch("cpu", "wasm32")
  switch("cc", "clang")
  switch("clang.exe", "emcc")
  switch("clang.linkerexe", "emcc")
  switch("gc", "arc")
  switch("exceptions", "goto")
  switch("define", "noSignalHandler")
  switch("passL", "-O3 -s MODULARIZE=1 -s EXPORT_ES6=1 -s ENVIRONMENT=worker -s ALLOW_MEMORY_GROWTH=1 -s INITIAL_MEMORY=16777216 -s MAXIMUM_MEMORY=100663296 -s EXPORTED_FUNCTIONS=_main,_pw_alloc,_pw_free,_pw_initialize,_pw_advance,_pw_finalize,_pw_output,_pw_output_length -s EXPORTED_RUNTIME_METHODS=HEAPU8 -s FILESYSTEM=0")
