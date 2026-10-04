import sys
from PIL import Image, ImageDraw
d = '/tmp/w4-detail/crops'
prefix, value, out = sys.argv[1], sys.argv[2], sys.argv[3]
labels = ['base'] + [f'{t}_t{value}' for t in sys.argv[4].split(',')]
tiles = [Image.open(f'{d}/{prefix}_{l}.png').convert('RGB').crop((50, 50, 350, 350)).resize((600, 600), Image.LANCZOS) for l in labels]
cols = 3
rows = (len(tiles) + cols - 1) // cols
sheet = Image.new('RGB', (604 * cols, 624 * rows), 'white')
draw = ImageDraw.Draw(sheet)
for i, (l, t) in enumerate(zip(labels, tiles)):
    x, y = (i % cols) * 604, (i // cols) * 624
    sheet.paste(t, (x, y + 20)); draw.text((x + 4, y + 4), l, fill='black')
sheet.save(out)
