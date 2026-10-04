import sys, glob, os
from PIL import Image, ImageDraw
d = '/tmp/w4-detail/crops'; out = '/tmp/w4-detail/sheets'
tags = sys.argv[1].split(',') if len(sys.argv) > 1 else ['p10']
prefixes = sorted({os.path.basename(f).rsplit('_', 1)[0] for f in glob.glob(f'{d}/*_base.png')})
for prefix in prefixes:
    labels = ['base'] + [f'{t}_t{v}' for v in (50, 100, -50) for t in ['p9'] + tags]
    files = [f'{d}/{prefix}_{l}.png' for l in labels]
    files = [(l, f) for l, f in zip(labels, files) if os.path.exists(f)]
    # Centre 200 px at 2x so the texel scale shows.
    tiles = [Image.open(f).convert('RGB').crop((100, 100, 300, 300)).resize((400, 400), Image.NEAREST) for _, f in files]
    sheet = Image.new('RGB', (404 * len(tiles), 424), 'white')
    draw = ImageDraw.Draw(sheet)
    for i, ((l, _), t) in enumerate(zip(files, tiles)):
        sheet.paste(t, (i * 404, 24)); draw.text((i * 404 + 4, 4), l, fill='black')
    sheet.save(f'{out}/{prefix}_{"-".join(tags)}.png')
    print(f'{out}/{prefix}_{"-".join(tags)}.png')
