## Run after building tmp/ui-gallery/atlas.png, with -d:silkyTesting.
import silky, vmath
import polyworld/gameuis
import ../examples/ui_gallery/gallery

let window = newWindow("Gallery test", ivec2(960, 720))
let sk = newSilky(window, "tmp/ui-gallery/atlas.png")
var state = newGalleryState()
window.onFrame = proc() =
  sk.beginUI(window, window.size)
  sk.drawGallery(window, state)
  sk.endUi()
window.pumpFrame(sk)
doAssert sk.semantic.root.findByText("Mira / Pathfinder") != nil
window.clickButton(sk, "Inspect Wayfinder's Compass")
doAssert state.inspected
window.clickButton(sk, "Settings")
doAssert state.tab == 1
window.pumpFrame(sk)
doAssert sk.semantic.root.findByText("Appearance") != nil
window.clickText(sk, "Show interaction hints", "CheckBox")
doAssert not state.showHints
window.clickButton(sk, "Quest")
doAssert state.tab == 2
window.clickButton(sk, "Claim reward")
doAssert state.claimed
window.pumpFrame(sk)
let claim = sk.semantic.root.findByText("Claim reward", "Button")
doAssert claim != nil and not claim.state.enabled
window.clickButton(sk, "Claim reward")
doAssert state.claimed
for size in [vec2(360, 640), vec2(960, 720), vec2(1920, 1080)]:
  let panels = galleryPanels(size)
  doAssert panels.content.inside(size)
  doAssert not panelsOverlap([panels.header, panels.nav, panels.content])
echo "Gallery semantic interaction proof passed"
