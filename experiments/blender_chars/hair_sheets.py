"""Arrange actual Blender hair renders in the concept sheet's 4 by 4 layout."""

import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

Root = Path(__file__).resolve().parents[2]
Preview = Root / 'tmp/blender_chars'
Renders = Preview / 'hair_reviews'
Fonts = Path('/System/Library/Fonts/Supplemental')
Names = ['French crop', 'Bowl cut', 'Flat top', 'Clustered afro',
         'Twist crop', 'Asymmetric bob', 'Dutch braid', 'Braided bun',
         'Twin braids', 'Blunt bob', 'Wavy panels', 'Wolf cut',
         'Pixie', 'Low ponytail', 'Swept locs', 'Side braid']
Margin, Gap, Header, Caption = 32, 20, 112, 60
Width, Height = 1000, 650
sheet = Image.new('RGB', (Margin * 2 + Width * 4 + Gap * 3,
                        Header + (Height + Caption) * 4 + Gap * 3 + Margin), '#f5f2ec')
draw = ImageDraw.Draw(sheet)
font = ImageFont.truetype(str(Fonts / 'Arial.ttf'), 32)
bold = ImageFont.truetype(str(Fonts / 'Arial Bold.ttf'), 44)
small = ImageFont.truetype(str(Fonts / 'Arial.ttf'), 27)
draw.text((Margin, 20), 'MODELED HAIRSTYLES / FRONT + BACK', fill='#272d31', font=bold)
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
sheet.save(Preview / 'hair_models_4x4.png')
reports = [json.loads((Renders / f'judge_{i:02}.json').read_text())
           for i in range(1, 17) if (Renders / f'judge_{i:02}.json').exists()]
(Renders / 'reviews.json').write_text(json.dumps(reports, indent=2) + '\n')
print(Preview / 'hair_models_4x4.png')
