import opengl
var boundTexture = 99.GLuint
proc glBindTexture(target: GLenum; texture: GLuint) =
  doAssert target == GL_TEXTURE_2D_ARRAY
  boundTexture = texture

var generated, definitions, uploads: int
proc glGenTextures(count: GLsizei; textures: ptr GLuint) =
  doAssert count == 1
  inc generated
  textures[] = (100 + generated).GLuint
proc glTexImage3D(target: GLenum; level, internalFormat: GLint;
    width, height, depth: GLsizei; border: GLint; format, pixelType: GLenum;
    pixels: pointer) =
  doAssert target == GL_TEXTURE_2D_ARRAY and internalFormat == GL_RGBA8.GLint
  doAssert pixels.isNil
  inc definitions
proc glTexSubImage3D(target: GLenum; level, x, y, z: GLint;
    width, height, depth: GLsizei; format, pixelType: GLenum; pixels: pointer) =
  doAssert target == GL_TEXTURE_2D_ARRAY and not pixels.isNil
  inc uploads
proc glTexParameteri(target, name: GLenum; value: GLint) = discard
proc glTexParameterf(target, name: GLenum; value: GLfloat) = discard

include ../src/polyworld/quadterrain

let base = newImage(2, 2)
base.fill(rgbx(40, 80, 120, 255))
let tail = newImage(1, 1)
tail.fill(rgbx(40, 80, 120, 255))
let layers = @[@[base, tail]]
let key = propTextureKey(layers, GL_REPEAT.GLint)
doAssert key == propTextureKey(@[@[base.copy(), tail.copy()]], GL_REPEAT.GLint)
doAssert key != propTextureKey(layers, GL_CLAMP_TO_EDGE.GLint)
doAssert key != propTextureKey(@[@[base]], GL_REPEAT.GLint)
doAssert key != propTextureKey(@[@[base, tail], @[base, tail]], GL_REPEAT.GLint)
let changed = tail.copy()
changed.data[0].a = 17
doAssert key != propTextureKey(@[@[base, changed]], GL_REPEAT.GLint),
  "A changed coverage mip must not reuse another atlas"
let reshaped = newImage(1, 4)
reshaped.data = base.data
doAssert key != propTextureKey(@[@[reshaped, tail]], GL_REPEAT.GLint)

let cache = newPropTextureCache()
cache.textures[key] = 73.GLuint
# A cache hit reuses the handle and preserves the uploader's final unbind.
# Stubbed GL calls measure allocations and uploads without a display.
doAssert buildTextureArray(@[@[base.copy(), tail.copy()]], GL_REPEAT.GLint, cache) == 73.GLuint
doAssert boundTexture == 0
doAssert cache.propTextureCacheStats() == (1, 1, 0)
doAssert newPropTextureCache().propTextureCacheStats() == (0, 0, 0)
let fresh = newPropTextureCache()
let first = buildTextureArray(layers, GL_REPEAT.GLint, fresh)
doAssert (generated, definitions, uploads) == (1, 2, 2)
doAssert buildTextureArray(@[@[base.copy(), tail.copy()]], GL_REPEAT.GLint, fresh) == first
doAssert (generated, definitions, uploads) == (1, 2, 2)
doAssert buildTextureArray(layers, GL_CLAMP_TO_EDGE.GLint, fresh) != first
doAssert (generated, definitions, uploads) == (2, 4, 4)
doAssert fresh.propTextureCacheStats() == (2, 1, 2)
# Uncached callers retain their original allocate-on-every-call behavior.
discard buildTextureArray(layers, GL_REPEAT.GLint)
discard buildTextureArray(layers, GL_REPEAT.GLint)
doAssert generated == 4

echo "Prop texture cache preserves pixels, mip shape, wrapping and owner scope"
