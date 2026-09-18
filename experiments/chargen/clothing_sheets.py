"""Arrange modeled clothing turnarounds in the approved 4 by 4 layout."""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

Root = Path(__file__).resolve().parents[2]
Output = Root / 'tmp/chargen/clothing_reviews'
Font = str(Root.parent / 'polyworld_data/themes/main/IBMPlexSans-Regular.ttf')
Names = ['Linen tunic', 'Bound blue tunic', 'Belted green tabard', 'Red work shirt',
         'Belted ochre tunic', 'Leather jerkin', 'Blue linen shirt', 'Plum wrap tunic',
         'Brown trousers', 'Loose blue breeches', 'Tan knee breeches',
         'Cuffed charcoal trousers', 'Strapped ankle boots', 'Tan cuff boots',
         'Tall leather boots', 'Folded travel boots']
Width, Height, Gap, Margin, Header, Footer = 1000, 620, 16, 24, 120, 68
sheet = Image.new('RGB', (Margin * 2 + Width * 4 + Gap * 3,
                        Header + 4 * (Height + Footer + Gap) + Margin), '#eeece7')
draw = ImageDraw.Draw(sheet)
draw.text((Margin, 20), 'MODELED CLOTHING / FRONT + BACK',
          font=ImageFont.truetype(Font, 46), fill='#313735')
draw.text((Margin, 77), '16 swappable garments. Cut and extruded from the actual Chargen body, with inherited skin weights.',
          font=ImageFont.truetype(Font, 28), fill='#68706b')
for i, name in enumerate(Names):
  x, y = Margin + i % 4 * (Width + Gap), Header + i // 4 * (Height + Footer + Gap)
  art = Image.open(Output / f'render_{i + 1:02}.png').convert('RGBA')
  tile = Image.new('RGBA', art.size, '#d6d4ce')
  tile.alpha_composite(art)
  sheet.paste(tile.convert('RGB'), (x, y))
  draw.text((x + 14, y + Height + 10), f'{i + 1:02}  {name}',
            font=ImageFont.truetype(Font, 30), fill='#343b38')
sheet.save(Output / 'clothing_models_4x4.png')
print(Output / 'clothing_models_4x4.png')
