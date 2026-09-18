"""Arrange actual Blender facial hair renders in the concept sheet's 4 by 4 layout."""

import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

Root = Path(__file__).resolve().parents[2]
Preview = Root / 'tmp/chargen'
Renders = Preview / 'beard_reviews'
Fonts = Path('/System/Library/Fonts/Supplemental')
Names = ['Split chin tuft', 'Parted chevron', 'Handlebar', 'Anchor goatee',
         'Square jaw', 'Swept chops', 'Rounded beard', 'Fork beard',
         'Tapered wedge', 'Spade beard', 'Van Dyke', 'Single tassel',
         'Twin tassels', 'Tiered fan', 'Tied jaw beard', 'Windswept beard']
Margin, Gap, Header, Caption = 32, 20, 112, 60
Width, Height = 1000, 650
sheet = Image.new('RGB', (Margin * 2 + Width * 4 + Gap * 3,
                        Header + (Height + Caption) * 4 + Gap * 3 + Margin), '#f5f2ec')
draw = ImageDraw.Draw(sheet)
font = ImageFont.truetype(str(Fonts / 'Arial.ttf'), 32)
bold = ImageFont.truetype(str(Fonts / 'Arial Bold.ttf'), 44)
small = ImageFont.truetype(str(Fonts / 'Arial.ttf'), 27)
draw.text((Margin, 20), 'MODELED FACIAL HAIR / FRONT + THREE-QUARTER', fill='#272d31', font=bold)
draw.text((Margin, 75), '16 separate Blender meshes fitted to our character. Each pair shows the same model.', fill='#657077', font=small)
for i, name in enumerate(Names):
  x = Margin + (i % 4) * (Width + Gap)
  y = Header + (i // 4) * (Height + Caption + Gap)
  art = Image.open(Renders / f'render_{i + 1:02}.png').convert('RGBA')
  assert art.size == (Width, Height)
  tile = Image.new('RGBA', art.size, '#e6e2dc')
  tile.alpha_composite(art)
  sheet.paste(tile.convert('RGB'), (x, y))
  draw.text((x + Width / 2, y + Height + 12), f'{i + 1:02}  {name}',
            fill='#3b444b', font=font, anchor='mt')
sheet.save(Preview / 'beard_models_4x4.png')
reports = [json.loads((Renders / f'judge_{i:02}.json').read_text())
           for i in range(1, 17) if (Renders / f'judge_{i:02}.json').exists()]
(Renders / 'reviews.json').write_text(json.dumps(reports, indent=2) + '\n')
print(Preview / 'beard_models_4x4.png')
