## The browser page's live status line, read by screen readers.

when defined(emscripten):
  {.emit: """
#include <emscripten.h>
EM_JS(void, cac_publish_status, (const char* text), {
  var element = document.getElementById('game-status');
  var value = UTF8ToString(text);
  if (element && element.textContent !== value) element.textContent = value;
});
""".}
  proc cacPublishStatus(text: cstring) {.importc: "cac_publish_status", nodecl.}
  proc publishStatus*(text: cstring) = cacPublishStatus(text)
else:
  proc publishStatus*(text: cstring) = discard
