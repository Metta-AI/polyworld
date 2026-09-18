"""Extract the generated kind eyes and their independent iris tint mask."""

from PIL import Image

from cut_faces import bounds, components
from export_library import Library

image = Image.open(Library / 'source/gnomes/kind_eyes.png').convert('RGBA')
groups = components(image.width, image.height, list(image.getdata()),
                    lambda pixel: pixel[3] >= 128, minimum=500)
groups.sort(key=len, reverse=True)
assert len(groups) >= 2
alpha = Image.new('L', image.size)
for group in groups[:2]:
  for point in group:
    alpha.putpixel(point, image.getpixel(point)[3])
image.putalpha(alpha)
left, top, right, bottom = bounds(groups[0] + groups[1])
image = image.crop((left - 8, top - 8, right + 8, bottom + 8))
image.thumbnail((384, 384), Image.Resampling.LANCZOS)
image.save(Library / 'eyes/gnome_kind.png')
mask = Image.new('RGBA', image.size, (0, 0, 0, 255))
grays = components(image.width, image.height, list(image.getdata()),
                   lambda pixel: pixel[3] >= 128 and
                   45 < min(pixel[:3]) < 225 and
                   max(pixel[:3]) - min(pixel[:3]) < 25, minimum=100)
grays.sort(key=len, reverse=True)
assert len(grays) >= 2
for group in grays[:2]:
  for point in group:
    mask.putpixel(point, (255, 255, 255, 255))
mask.save(Library / 'eyes/gnome_kind.mask.png')
print('Extracted one kind eye pair:', image.size)
