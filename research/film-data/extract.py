#!/usr/bin/env python3
"""Digitise curves from manufacturers' film/paper datasheets into research/film-data/<id>.json.

Requires only the Python standard library and PyMuPDF (`pip install pymupdf`).

    python3 research/film-data/extract.py            # all stocks
    python3 research/film-data/extract.py kodak-portra-400 ...
    python3 research/film-data/extract.py --debug e4050 4 x0 y0 x1 y1   # label every vector path

Source PDFs are NOT part of the repository (they are copyrighted). Download them to
build/film-data/pdf/ using the URLs in SOURCES; the SHA-256 is checked before extraction.
Check overlays (source chart with the extracted samples drawn on top) are written to
build/film-data/check/.

Geometry is handled in PDF page coordinates (points, origin top-left, y down). Bitmap charts
are rendered, traced in pixel space and mapped back to page coordinates, so vector and
raster charts share the same axis calibration and overlay code.
"""
import hashlib
import json
import math
import os
import re
import sys

import pymupdf

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
PDF_DIR = os.path.join(ROOT, 'build', 'film-data', 'pdf')
CHECK_DIR = os.path.join(ROOT, 'build', 'film-data', 'check')
RETRIEVED = '2026-09-30'

# ============================================================================ sources

SOURCES = {
    'e4050': dict(file='e4050_2025.pdf', document='E-4050', edition='Revised 1-25 (January 2025)',
                  title='KODAK PROFESSIONAL PORTRA 400 Film — Technical Data',
                  url='https://kodakprofessional.com/sites/default/files/2025-07/e4050.pdf',
                  sha256='70b15171673c5d01505f58ace448995ad72acbe5e401d1966563a61ac0712838'),
    'e4046': dict(file='e4046_2025.pdf', document='E-4046', edition='Revised 1/25 (January 2025)',
                  title='KODAK PROFESSIONAL EKTAR 100 Film — Technical Data',
                  url='https://kodakprofessional.com/sites/default/files/2025-07/e4046.pdf',
                  sha256='38a41d47ad006cd563793033f83c8f9ef6cdd3c8300695c31facfc71d368f8db'),
    'e7022': dict(file='e7022_gold_200.pdf', document='E-7022', edition='Revised 03-22 (March 2022)',
                  title='KODAK GOLD 200 Film — Technical Data',
                  url='https://kodakprofessional.com/sites/default/files/wysiwyg/E7022-1.pdf',
                  sha256='8e45b8167a365cf961e69192bb3ff7048fff6a14bb9e55cf7c455555614a51b1'),
    'f4017': dict(file='f4017_tri-x.pdf', document='F-4017', edition='Revised 12-16 (December 2016)',
                  title='KODAK PROFESSIONAL TRI-X 320 and 400 Films — Technical Data',
                  url='https://kodakprofessional.com/sites/default/files/wysiwyg/pro/resources/f4017_trix_320400_0.pdf',
                  sha256='9c71b8b077f59bbbc6d941afd26b4b988bd0a28c603a2315e92170091c397c73'),
    'h15219': dict(file='vision3_5219_ti.pdf', document='H-1-5219', edition='Revised 3-26 (March 2026)',
                   title='KODAK VISION3 500T Color Negative Film 5219 / 7219 — Technical Data',
                   url='https://www.kodak.com/content/products-brochures/motion-picture/KODAK-VISION3-5219-7219-technical-information.pdf',
                   sha256='6d037d8090373ee50d10bedfff3df14777a575dd107c50edcafc7ec5862d0972'),
    'h12383': dict(file='kodak_2383.pdf', document='H-1-2383', edition='Revised 8-26 (August 2026)',
                   title='KODAK VISION Color Print Film 2383 / 3383 — Technical Data',
                   url='https://www.kodak.com/content/products-brochures/motion-picture/KODAK-VISION-Color-Print-Film-2383-3383-technical-information.pdf',
                   sha256='a72fa4482ebd891a9ac4a823cafe740e3587c56470f27e4dfd4391f5c3e5a207'),
    'e4070': dict(file='e4070_endura.pdf', document='E-4070', edition='Revised 3-13 (March 2013)',
                  title='KODAK PROFESSIONAL ENDURA Premier Paper — Technical Data',
                  url='https://imaging.kodakalaris.com/sites/default/files/files/resources/paper-endura-techpub-e4070.pdf',
                  sha256='6f632cc5943a4adb8da487b86470ddf51c436a52f313241691b5b8b2bab1718f'),
    'af3-0217e': dict(file='fuji_superia_xtra400.pdf', document='AF3-0217E', edition='KAMIQ-06.10-FP',
                      title='FUJICOLOR SUPERIA X-TRA 400 [CH] — Fujifilm Product Information Bulletin',
                      url='https://asset.fujifilm.com/www/ae/files/2019-09/af234c58ab3d3b67b41cde22b1155309/films_superia-xtra400_datasheet_01.pdf',
                      sha256='7e77f9c3bd3001e40f8cafea55c73cdfda09fd1980b55b73862d6da87f6a11b2'),
    'af3-036e': dict(file='fuji_provia100f_af3-036e.pdf', document='AF3-036E', edition='EIGI-00.10-HB-5-4',
                     title='FUJICHROME PROVIA 100F Professional [RDP III] — Fujifilm Data Sheet',
                     url='https://asset.fujifilm.com/www/us/files/2020-03/dc6e1c21c643f82b7fb393cef94d524a/Provia100FAF3-036E.pdf',
                     sha256='e28d54e76e8fcdf44c8ffacc930b5b8f2ea54a7cdaeedfcc91790e68eb599de8'),
    'af3-0221e2': dict(file='fuji_velvia50_af3-221e.pdf', document='AF3-0221E2', edition='KAMIQ-07.3-FP',
                       title='FUJICHROME Velvia 50 Professional [RVP 50] — Fujifilm Product Information Bulletin',
                       url='https://asset.fujifilm.com/www/us/files/2020-03/742f83fe2440fce58fbcc08f7370a7e6/AF3-0221E2Velvia50PIB.pdf',
                       sha256='bebfb4305fd3edc5e3505a9a0f4a0a1078da1db7672aacb4aa1bac1de3d64cfd'),
    'hp5': dict(file='ilford_hp5_plus.pdf', document='HP5 PLUS Technical Information', edition='Nov 2018',
                title='ILFORD HP5 PLUS — Technical Information (HARMAN technology)',
                url='https://www.ilfordphoto.com/amfile/file/download/file/1903/product/691/',
                sha256='f06f383d714bc9d13033f9e30a6aedf29d9b9f4d25c4a353d69e6526cb2f037f'),
    'mgrc': dict(file='ilford_multigrade_rc.pdf', document='MULTIGRADE RC PAPERS Technical Information',
                 edition='Oct 2020 (file MULTIGRADE_RC_Papers_J20)',
                 title='ILFORD MULTIGRADE RC PAPERS — Technical Information (HARMAN technology)',
                 url='https://www.ilfordphoto.com/amfile/file/download/file/1956/product/1701/',
                 sha256='62c93069b0ae5dc340444651dbbe8e1b17102f7e25f12449297504a8e1d391e1'),
    # ---- batch 2 (retrieved 2026-10-01)
    'e4051': dict(file='e4051_2025.pdf', document='E-4051', edition='Revised 1-25 (January 2025)',
                  title='KODAK PROFESSIONAL PORTRA 160 Film — Technical Data',
                  url='https://kodakprofessional.com/sites/default/files/2025-07/e4051.pdf',
                  sha256='1f3430cd8e1b4ad370d8bbf8c648f6f5871a9911dfd5794613e9bbf3bbf9cb82', retrieved='2026-10-01'),
    'e4040': dict(file='e4040_2025.pdf', document='E-4040', edition='Revised 1-25 (January 2025)',
                  title='KODAK PROFESSIONAL PORTRA 800 Film — Technical Data',
                  url='https://kodakprofessional.com/sites/default/files/2025-07/e4040.pdf',
                  sha256='13581198dffa01c5a2a38ab87d96a73cf2e2755b6514d55c65206fe621a60b5a', retrieved='2026-10-01'),
    'e7023': dict(file='ultramax400.pdf', document='E-7023', edition='Revised 2/16 (February 2016)',
                  title='KODAK ULTRA MAX 400 Film — Technical Data',
                  url='https://kodakprofessional.com/sites/default/files/wysiwyg/KodakUltraMax400TechSheet-1.pdf',
                  sha256='6c22ba6d69e495d3e6f4160889512841b1e85e5007dbb7974446ba564fe41bf3', retrieved='2026-10-01'),
    'e4000': dict(file='e4000_e100.pdf', document='E-4000', edition='Revised 8-18 (August 2018)',
                  title='KODAK PROFESSIONAL EKTACHROME E100 Film — Technical Data',
                  url='https://kodakprofessional.com/sites/default/files/wysiwyg/pro/resources/e4000_ektachrome_100.pdf',
                  sha256='d6e6fa1497c4fc16010997b1a8510d9df3b4692e34c48599c8a4338d5768fab6', retrieved='2026-10-01'),
    'f4016': dict(file='f4016_tmax100.pdf', document='F-4016', edition='Revised 6-18 (June 2018)',
                  title='KODAK PROFESSIONAL T-MAX 100 Film — Technical Data',
                  url='https://kodakprofessional.com/sites/default/files/wysiwyg/pro/resources/f4016_TMax_100.pdf',
                  sha256='00518d7d1e296d6065f6e41ea3db999e5d8714679fb3d2b76d9a49eb207113be', retrieved='2026-10-01'),
    'f4043': dict(file='f4043_tmax400.pdf', document='F-4043', edition='Revised 2-16 (February 2016)',
                  title='KODAK PROFESSIONAL T-MAX 400 Film — Technical Data',
                  url='https://kodakprofessional.com/sites/default/files/wysiwyg/pro/resources/f4043_TMax_400.pdf',
                  sha256='9bd252fdcf37019dc4fb73f40f4d316b28b814190a333b28e7d6c339689c9171', retrieved='2026-10-01'),
    'd100': dict(file='ilford_delta_100.pdf', document='DELTA 100 PROFESSIONAL Technical Information',
                 edition='Apr 2023', title='ILFORD DELTA 100 PROFESSIONAL — Technical Information (HARMAN technology)',
                 url='https://www.ilfordphoto.com/amfile/file/download/file/3/product/679/',
                 sha256='f84dc976c4e879418cbbb5c318e37e8ef1400a7fdd319c1614077d598fe4fe4f', retrieved='2026-10-01'),
    'd3200': dict(file='ilford_delta_3200.pdf', document='DELTA 3200 PROFESSIONAL Technical Information',
                  edition='Jun 2025 (product page: "technical data sheet F25")',
                  title='ILFORD DELTA 3200 PROFESSIONAL — Technical Information (HARMAN technology)',
                  url='https://www.ilfordphoto.com/amfile/file/download/file/1913/product/682/',
                  sha256='049f37bb3c959cee9598bc607d0bb54c614c942928a9b07d4431674c35be1aca', retrieved='2026-10-01'),
    'fp4': dict(file='ilford_fp4_plus.pdf', document='FP4 PLUS Technical Information',
                edition='Nov 2018 (product page: "technical data sheet I19")',
                title='ILFORD FP4 PLUS — Technical Information (HARMAN technology)',
                url='https://www.ilfordphoto.com/amfile/file/download/file/1919/product/688/',
                sha256='466e5b20460b8eb9bc0b989f3244a4526b739ab91bad1368ad0114917b52171f', retrieved='2026-10-01'),
    'panf': dict(file='ilford_panf_plus.pdf', document='PANF PLUS Technical Information',
                 edition='B26 (product page: "technical data sheet 2026")',
                 title='ILFORD PAN F PLUS — Technical Information (HARMAN technology)',
                 url='https://www.ilfordphoto.com/amfile/file/download/file/1905/product/699/',
                 sha256='2e78af92e38eb5bf9a8000c7cc01f714fcaf4d5426fda74c0a23dcfe76569146', retrieved='2026-10-01'),
    'h15207': dict(file='vision3_5207_ti.pdf', document='H-1-5207', edition='Revised 3-26 (March 2026)',
                   title='KODAK VISION3 250D Color Negative Film 5207 / 7207 — Technical Information',
                   url='https://www.kodak.com/content/products-brochures/motion-picture/KODAK-VISION3-250D-5207-7207-technical-information.pdf',
                   sha256='70adb298a7aabb285d986b720e07c87c27eb2361f0925aea2b15903c08282e16', retrieved='2026-10-01'),
    'h15203': dict(file='vision3_5203_ti.pdf', document='H-1-5203', edition='Revised 3-26 (March 2026)',
                   title='KODAK VISION3 50D Color Negative Film 5203 / 7203 — Technical Information',
                   url='https://www.kodak.com/content/products-brochures/motion-picture/KODAK-VISION3-50D-5203-7203-technical-information.pdf',
                   sha256='b4613661abed641671329eff3bd7d5686b268eb26b954ef1c27ea68f363caca6', retrieved='2026-10-01'),
    'rvp100': dict(file='fuji_velvia100_jp.pdf', document='163AR0096C', edition='17.05-FFBX (May 2017), Japanese',
                   title='FUJICHROME Velvia 100 Professional [RVP 100] — Fujifilm data sheet (Japanese)',
                   url='https://asset.fujifilm.com/www/jp/files/2024-04/56c15e414d446997d6d609f5726df093/datasheet_velvia100_01.pdf',
                   sha256='cdf1d8e4c659133f446f04622d1dbf86b2fc44041b976ad4de082c1637548b64', retrieved='2026-10-01'),
    'pro400h': dict(file='fuji_pro400h_jp.pdf', document='013AR0328A', edition='神SF-13.02 (February 2013), Japanese',
                    title='FUJICOLOR PRO 400H Professional — Fujifilm data sheet (Japanese; discontinued product)',
                    url='https://asset.fujifilm.com/www/jp/files/2024-04/198fe31ee57628013d29171770b28218/datasheet_pro400h_01.pdf',
                    sha256='421e625bc24f9d9dfad01edc9d787f192934461e026e1c18527adc165a60229a', retrieved='2026-10-01'),
    'eternav250d': dict(file='fuji_eterna_vivid250d.pdf', document='KB-1009E', edition='©2010 (PDF created 2011-01-28)',
                        title='FUJICOLOR NEGATIVE FILM ETERNA Vivid 250D — Fujifilm motion picture data sheet',
                        url='http://www.fujifilm.com/products/motion_picture/pdf/eterna_vivid250d.pdf',
                        fetchedVia='Internet Archive capture of the manufacturer URL: https://web.archive.org/web/'
                                   '20120216070558id_/http://www.fujifilm.com/products/motion_picture/pdf/eterna_vivid250d.pdf',
                        sha256='54394f704d56f13864e2dec3ab4b39a627b4844cd0b0148600af6dc43f3828af', retrieved='2026-10-01'),
    'e55': dict(file='kodak_e55_kodachrome.pdf', document='E-55', edition='December 1996 (Major Revision 12-96)',
                title='KODACHROME 25, 64, and 200 Professional Film — Kodak technical data',
                url='http://www.kodak.com:80/global/en/professional/support/techPubs/e55/e55.pdf',
                fetchedVia='Internet Archive capture of the manufacturer URL: https://web.archive.org/web/'
                           '20000817190405id_/http://www.kodak.com:80/global/en/professional/support/techPubs/e55/e55.pdf',
                sha256='6fdbfe53b181d34a5aaf6fb57fef90c79c97e7e315179ba22edfb187ca869b4a', retrieved='2026-10-01'),
}

_docs = {}


def doc(key):
    if key not in _docs:
        s = SOURCES[key]
        path = os.path.join(PDF_DIR, s['file'])
        with open(path, 'rb') as f:
            h = hashlib.sha256(f.read()).hexdigest()
        if h != s['sha256']:
            raise SystemExit(f'{path}: sha256 {h} does not match the recorded source')
        _docs[key] = pymupdf.open(path)
    return _docs[key]


def source_block(key, pages):
    s = SOURCES[key]
    return {'title': s['title'], 'document': s['document'], 'edition': s['edition'], 'url': s['url'],
            'fetchedVia': s.get('fetchedVia', 'direct'), 'retrieved': s.get('retrieved', RETRIEVED),
            'sha256': s['sha256'], 'pages': pages}

# ============================================================================ vector geometry


def _bez(p0, p1, p2, p3, n=12):
    out = []
    for i in range(1, n + 1):
        t = i / n
        a, b, c, d = (1 - t) ** 3, 3 * (1 - t) ** 2 * t, 3 * (1 - t) * t * t, t ** 3
        out.append((a * p0.x + b * p1.x + c * p2.x + d * p3.x, a * p0.y + b * p1.y + c * p2.y + d * p3.y))
    return out


def path_polylines(dr):
    """A PyMuPDF drawing → list of polylines [(x, y), ...] in page coordinates."""
    lines, cur, last = [], [], None

    def start(pt):
        nonlocal cur
        if last is None or abs(pt.x - last[0]) > 0.05 or abs(pt.y - last[1]) > 0.05:
            if len(cur) > 1:
                lines.append(cur)
            cur = [(pt.x, pt.y)]
    for it in dr['items']:
        if it[0] == 'l':
            start(it[1])
            cur.append((it[2].x, it[2].y))
            last = cur[-1]
        elif it[0] == 'c':
            start(it[1])
            cur.extend(_bez(*it[1:5]))
            last = cur[-1]
    if len(cur) > 1:
        lines.append(cur)
    return lines


def page_drawings(page):
    """page.get_drawings() in displayed (rotated) page coordinates; PyMuPDF reports them unrotated."""
    ds = page.get_drawings()
    if not page.rotation:
        return ds
    m = page.rotation_matrix
    out = []
    for dr in ds:
        items = []
        for it in dr['items']:
            if it[0] == 're':
                items.append(('re', pymupdf.Rect(it[1]) * m) + tuple(it[2:]))
            elif it[0] == 'qu':
                items.append(('qu', pymupdf.Quad(it[1]) * m))
            else:
                items.append((it[0],) + tuple(pymupdf.Point(p) * m for p in it[1:]))
        out.append(dict(dr, items=items, rect=pymupdf.Rect(dr['rect']) * m))
    return out


def page_segments(page):
    """Straight axis-aligned segments (ticks, grid, frames) as (x0, y0, x1, y1)."""
    segs = []
    for dr in page_drawings(page):
        for it in dr['items']:
            if it[0] == 'l':
                segs.append((it[1].x, it[1].y, it[2].x, it[2].y))
            elif it[0] == 're':
                r = it[1]
                if r.height < 1.5 and r.width >= 1.5:
                    segs.append((r.x0, (r.y0 + r.y1) / 2, r.x1, (r.y0 + r.y1) / 2))
                elif r.width < 1.5 and r.height >= 1.5:
                    segs.append(((r.x0 + r.x1) / 2, r.y0, (r.x0 + r.x1) / 2, r.y1))
                else:
                    segs += [(r.x0, r.y0, r.x1, r.y0), (r.x0, r.y1, r.x1, r.y1),
                             (r.x0, r.y0, r.x0, r.y1), (r.x1, r.y0, r.x1, r.y1)]
    return segs


def vector_curves(page, rect, min_pts=6, stroke_only=True):
    """Stroked subpaths lying inside rect, one entry per subpath (re-join with chain_curves).
    Long axis-aligned polylines (grid lines, frames) are dropped; short ones are kept because
    piecewise-drawn curves can contain flat pieces."""
    rect = pymupdf.Rect(rect)
    out = []
    for i, dr in enumerate(page_drawings(page)):
        if stroke_only and 's' not in dr['type']:
            continue
        for j, poly in enumerate(path_polylines(dr)):
            xs, ys = [p[0] for p in poly], [p[1] for p in poly]
            r = pymupdf.Rect(min(xs), min(ys), max(xs), max(ys))
            if not (rect.x0 - 1 <= r.x0 and r.x1 <= rect.x1 + 1 and rect.y0 - 1 <= r.y0 and r.y1 <= rect.y1 + 1):
                continue
            if len(poly) < min_pts:
                continue
            aligned = all(abs(a[0] - b[0]) < 0.05 or abs(a[1] - b[1]) < 0.05 for a, b in zip(poly, poly[1:]))
            if aligned and (r.width > 0.25 * rect.width or r.height > 0.25 * rect.height):
                continue
            out.append(dict(index=f'{i}.{j}', polys=[poly], color=dr.get('color'), dashes=dr.get('dashes'),
                            width=dr.get('width'), rect=r))
    return out


def _heading(p, end):
    """Direction (radians) of polyline p at its end (end=True) or start, over its last/first ~1.5 pt."""
    pts = p[::-1] if end else p
    a = pts[0]
    b = next((q for q in pts[1:] if math.hypot(q[0] - a[0], q[1] - a[1]) >= 1.5), pts[-1])
    return math.atan2(a[1] - b[1], a[0] - b[0]) if end else math.atan2(b[1] - a[1], b[0] - a[0])


def chain_curves(curves, tol=0.4, min_pts=6, max_turn=math.pi):
    """Join paths whose end point meets another path's start point (curves drawn in pieces). Where several
    same-coloured curves are split at a common point (a crossing), the piece continuing in the most similar
    direction is joined (none if every candidate turns by more than max_turn radians; no limit by default,
    as some charts are drawn as short straight pieces meeting at sharp corners)."""
    items = [dict(c, polys=[list(p) for p in c['polys']]) for c in curves]
    merged = True
    while merged:
        merged = False
        for a in items:
            ea = a['polys'][-1][-1]
            ha = _heading(a['polys'][-1], True)
            best = None
            for b in items:
                if a is b or a['color'] != b['color']:
                    continue
                sb = b['polys'][0][0]
                if abs(ea[0] - sb[0]) < tol and abs(ea[1] - sb[1]) < tol:
                    turn = abs((_heading(b['polys'][0], False) - ha + math.pi) % (2 * math.pi) - math.pi)
                    if turn <= max_turn and (best is None or turn < best[0]):
                        best = (turn, b)
            if best:
                b = best[1]
                a['polys'][-1].extend(b['polys'][0][1:])
                a['polys'].extend(b['polys'][1:])
                a['rect'] = a['rect'] | b['rect']
                a['index'] = f"{a['index']}+{b['index']}"
                items.remove(b)
                merged = True
                break
    out = []
    for c in items:
        if sum(len(p) for p in c['polys']) < min_pts:
            continue
        def probe(k):   # start, middle and end points of a curve
            pts = [q for p in k['polys'] for q in p]
            return pts[0], pts[len(pts) // 2], pts[-1]
        dup = any(abs(c['rect'].x0 - o['rect'].x0) < 0.3 and abs(c['rect'].x1 - o['rect'].x1) < 0.3 and
                  abs(c['rect'].y0 - o['rect'].y0) < 0.3 and abs(c['rect'].y1 - o['rect'].y1) < 0.3 and
                  all(math.hypot(a[0] - b[0], a[1] - b[1]) < 0.3 for a, b in zip(probe(c), probe(o)))
                  for o in out)
        if not dup:
            out.append(c)
    return out

# ============================================================================ axes

NUM = re.compile(r'^-?\d+(\.\d+)?$')


def number_spans(page, rect):
    """Numeric spans whose visual centre lies inside rect: [(value, cx, cy)]."""
    rect = pymupdf.Rect(rect)
    big = pymupdf.Rect(rect.x0 - 30, rect.y0 - 10, rect.x1 + 30, rect.y1 + 10)
    return [t for t in _number_spans(page, big) if rect.x0 <= t[1] <= rect.x1 and rect.y0 <= t[2] <= rect.y1]


def _number_spans(page, rect):
    out = []
    m = page.rotation_matrix
    clip = pymupdf.Rect(rect) * ~m if page.rotation else pymupdf.Rect(rect)
    for b in page.get_text('dict', clip=clip)['blocks']:
        for l in b.get('lines', []):
            spans = []
            for s in l['spans']:   # merge touching spans ("5" + "0" → "50")
                if page.rotation:
                    s = dict(s, bbox=tuple(pymupdf.Rect(s['bbox']) * m))
                if spans and s['bbox'][0] - spans[-1]['bbox'][2] < 0.6 and abs(s['bbox'][1] - spans[-1]['bbox'][1]) < 1:
                    p = spans[-1]
                    spans[-1] = {'text': p['text'] + s['text'], 'size': p['size'],
                                 'bbox': (p['bbox'][0], min(p['bbox'][1], s['bbox'][1]), s['bbox'][2],
                                          max(p['bbox'][3], s['bbox'][3]))}
                else:
                    spans.append(s)
            for s in spans:
                t = s['text'].strip().replace('\u2212', '-').replace('\u2013', '-').replace('\u00b7', '.')
                if NUM.match(t):
                    x0, y0, x1, y1 = s['bbox']
                    # digits occupy the upper ~75% of a span bbox; use their visual centre
                    out.append((float(t), (x0 + x1) / 2, y0 + 0.47 * (y1 - y0)))
    return out


class Axis:
    """Least-squares linear (or log10) map page-coordinate → data value."""

    def __init__(self, pairs, log=False, name=''):
        self.log, self.name = log, name
        self.labels = [(p, v, s) for p, v, s in pairs]
        xs = [p for p, _, _ in pairs]
        vs = [math.log10(v) if log else v for _, v, _ in pairs]
        n = len(xs)
        mx, mv = sum(xs) / n, sum(vs) / n
        self.k = sum((x - mx) * (v - mv) for x, v in zip(xs, vs)) / sum((x - mx) ** 2 for x in xs)
        self.b = mv - self.k * mx
        self.resid = max(abs(self.k * x + self.b - v) for x, v in zip(xs, vs))

    def val(self, p):
        v = self.k * p + self.b
        return 10 ** v if self.log else v

    def pos(self, v):
        return ((math.log10(v) if self.log else v) - self.b) / self.k

    def info(self):
        return {'labels': len(self.labels), 'snappedToTicks': sum(1 for *_, s in self.labels if s),
                'maxResidual': round(self.resid, 4), 'log': self.log}


def axis_from_labels(page, label_rect, orient, values=None, span=None, tol=3.5, log=False, name='',
                     drop=()):
    """Calibrate from numeric labels in label_rect, snapping each to the closest tick/grid line.

    orient 'x': labels along the bottom, tick lines vertical; 'y': labels at the side.
    values: override label values in reading order (e.g. Kodak bar notation 3̄.0 = -3.0).
    span: (lo, hi) in the other coordinate that a tick line must reach.
    """
    labs = [l for l in number_spans(page, label_rect) if l[0] not in drop]
    labs.sort(key=lambda t: t[1] if orient == 'x' else t[2])
    if values is not None:
        assert len(values) == len(labs), (name, [l[0] for l in labs], values)
        labs = [(v, cx, cy) for v, (_, cx, cy) in zip(values, labs)]
    segs = page_segments(page)
    pairs = []
    for v, cx, cy in labs:
        c = cx if orient == 'x' else cy
        best = None
        for x0, y0, x1, y1 in segs:
            if orient == 'x' and abs(x0 - x1) < 0.3 and abs(y0 - y1) > 1:
                if span and (max(y0, y1) < span[0] - 1.5 or min(y0, y1) > span[1] + 1.5):
                    continue
                d, p = abs(x0 - c), x0
            elif orient == 'y' and abs(y0 - y1) < 0.3 and abs(x0 - x1) > 1:
                if span and (max(x0, x1) < span[0] - 1.5 or min(x0, x1) > span[1] + 1.5):
                    continue
                d, p = abs(y0 - c), y0
            else:
                continue
            if d < tol and (best is None or d < best[0]):
                best = (d, p)
        pairs.append((best[1] if best else c, v, best is not None))
    return Axis(pairs, log=log, name=name)


def axis_from_pairs(pairs, log=False, name=''):
    """pairs: [(page_coord, value)] measured by hand or from raster grid lines."""
    return Axis([(p, v, True) for p, v in pairs], log=log, name=name)

# ============================================================================ sampling


def grid(lo, hi, step):
    a, b = math.ceil(lo / step - 1e-6), math.floor(hi / step + 1e-6)
    return [round(i * step, 6) for i in range(a, b + 1)]


def poly_at(poly, x):
    """All y where a page polyline crosses page-x."""
    ys = []
    for (x0, y0), (x1, y1) in zip(poly, poly[1:]):
        if x0 != x1 and (x0 - x) * (x1 - x) <= 0:
            ys.append(y0 + (x - x0) / (x1 - x0) * (y1 - y0))
    return ys


def sample_curve(polys, xa, ya, xs, pick='mean'):
    """Sample a curve made of page polylines at data x values → (ys, folds).

    A 'fold' is a sample where the path crosses the vertical more than once by > 0.6 pt
    (e.g. a curve that doubles back); those samples use `pick` ('mean', 'min', 'max' in data y).
    """
    out, folds = [], 0
    for x in xs:
        ys = [y for p in polys for y in poly_at(p, xa.pos(x))]
        if not ys:
            out.append(None)
            continue
        vals = sorted(ya.val(y) for y in ys)
        if max(ys) - min(ys) > 0.6:
            folds += 1
        v = {'mean': sum(vals) / len(vals), 'min': vals[0], 'max': vals[-1]}[pick]
        out.append(v)
    return out, folds


def curve_range(polys, xa):
    xs = [xa.val(p[0]) for poly in polys for p in poly]
    return min(xs), max(xs)


def interp_points(pts, xs):
    """Linear interpolation of (x, y) data points (sorted by x) at xs; None outside."""
    pts = sorted(pts)
    out = []
    j = 0
    for x in xs:
        if not pts or x < pts[0][0] - 1e-9 or x > pts[-1][0] + 1e-9:
            out.append(None)
            continue
        while j < len(pts) - 2 and pts[j + 1][0] < x:
            j += 1
        (x0, y0), (x1, y1) = pts[j], pts[min(j + 1, len(pts) - 1)]
        if x1 == x0:
            out.append(y0)
        else:
            t = min(max((x - x0) / (x1 - x0), 0), 1)
            out.append(y0 + t * (y1 - y0))
    return out


def rnd(vals, nd=3):
    return [None if v is None else round(v, nd) for v in vals]

# ============================================================================ raster


class Raster:
    """RGB pixels with page↔pixel mapping and simple ink masks — either a rendered page region
    (Raster(page, rect, dpi)) or an embedded bitmap at native resolution (Raster.image(key, pno, xref))."""

    def __init__(self, page=None, rect=None, dpi=None, _raw=None):
        if _raw:
            self.rect, self.w, self.h, self.s = _raw
        else:
            self.rect = pymupdf.Rect(rect)
            pix = page.get_pixmap(dpi=dpi, clip=self.rect, colorspace=pymupdf.csRGB, alpha=False)
            self.w, self.h, self.s = pix.width, pix.height, pix.samples
        self.sx, self.sy = self.w / self.rect.width, self.h / self.rect.height

    @classmethod
    def image(cls, key, pno, xref):
        """Embedded image by xref, mapped through its placement bbox (images here are unrotated).
        1-bit stencil masks (no colour space) become black ink on white."""
        d = doc(key)
        info = next(i for i in d[pno - 1].get_image_info(xrefs=True) if i['xref'] == xref)
        t = info['transform']
        assert abs(t[1]) < 1e-6 and abs(t[2]) < 1e-6 and t[0] > 0 and t[3] > 0, t
        pix = pymupdf.Pixmap(d, xref)
        if pix.colorspace is None:
            s = bytes(255 - v for v in pix.samples)
            s = bytes(b for v in s for b in (v, v, v))
        else:
            if pix.colorspace.n != 3:
                pix = pymupdf.Pixmap(pymupdf.csRGB, pix)
            if pix.alpha:
                pix = pymupdf.Pixmap(pix, 0)
            s = pix.samples
        return cls(_raw=(pymupdf.Rect(info['bbox']), pix.width, pix.height, s))

    def rgb(self, x, y):
        i = (y * self.w + x) * 3
        return self.s[i], self.s[i + 1], self.s[i + 2]

    def to_page(self, px, py):
        return self.rect.x0 + (px + 0.5) / self.sx, self.rect.y0 + (py + 0.5) / self.sy

    def to_px(self, x, y):
        return (x - self.rect.x0) * self.sx - 0.5, (y - self.rect.y0) * self.sy - 0.5

    def mask(self, pred, exclude=()):
        """Boolean mask (list of bytearrays, rows) of pixels where pred(r, g, b) is true.
        exclude: page-coordinate rects blanked out (legends, labels)."""
        rows = []
        s, w = self.s, self.w
        for y in range(self.h):
            row = bytearray(w)
            base = y * w * 3
            for x in range(w):
                i = base + 3 * x
                if pred(s[i], s[i + 1], s[i + 2]):
                    row[x] = 1
            rows.append(row)
        for r in exclude:
            x0, y0 = self.to_px(r[0], r[1])
            x1, y1 = self.to_px(r[2], r[3])
            for y in range(max(0, int(y0)), min(self.h, int(y1) + 2)):
                for x in range(max(0, int(x0)), min(self.w, int(x1) + 2)):
                    rows[y][x] = 0
        return rows

    def lines(self, m, orient, min_frac=0.5, lo=0, hi=None):
        """Long straight lines in mask: orient 'h' → rows (returns page y), 'v' → columns (page x)."""
        res = []
        if orient == 'h':
            hi = hi or self.w
            prof = [sum(m[y][lo:hi]) / (hi - lo) for y in range(self.h)]
        else:
            hi = hi or self.h
            prof = [sum(m[y][x] for y in range(lo, hi)) / (hi - lo) for x in range(self.w)]
        groups = []
        for i, v in enumerate(prof):
            if v >= min_frac:
                if groups and i - groups[-1][-1] <= 1:
                    groups[-1].append(i)
                else:
                    groups.append([i])
        for g in groups:
            c = sum(g) / len(g)
            res.append(self.to_page(0, c)[1] if orient == 'h' else self.to_page(c, 0)[0])
        return res

    def remove_lines(self, m, rows=(), cols=(), halfwidth=1, max_bridge=3.0):
        """Blank grid lines (page coords) from mask; curve pixels crossing them are lost and
        bridged later by interpolation."""
        # A curve crossing a grid line has ink on both sides of the erased band: bridge it back, but
        # only in short stretches (long bridged stretches are remnants of the grid line itself).
        lim = max(4, int(1.5 * max_bridge * self.sx)) if max_bridge else None

        def short(flags):
            out, i, n = bytearray(len(flags)), 0, len(flags)
            while i < n:
                if flags[i]:
                    j = i
                    while j < n and flags[j]:
                        j += 1
                    if lim is None or j - i <= lim:
                        out[i:j] = b'\x01' * (j - i)
                    i = j
                else:
                    i += 1
            return out
        for y in rows:
            py = round(self.to_px(0, y)[1])
            a, b = py - halfwidth - 1, py + halfwidth + 1
            if a < 0 or b >= self.h:
                continue
            keep = short([1 if m[a][x] and m[b][x] else 0 for x in range(self.w)])
            for yy in range(a + 1, b):
                m[yy][:] = keep
        for x in cols:
            px = round(self.to_px(x, 0)[0])
            a, b = px - halfwidth - 1, px + halfwidth + 1
            if a < 0 or b >= self.w:
                continue
            keep = short([1 if m[yy][a] and m[yy][b] else 0 for yy in range(self.h)])
            for yy in range(self.h):
                for xx in range(a + 1, b):
                    m[yy][xx] = keep[yy]

    def column_runs(self, m, px):
        runs, start = [], None
        for y in range(self.h):
            v = m[y][px]
            if v and start is None:
                start = y
            elif not v and start is not None:
                runs.append(((start + y - 1) / 2, y - start))
                start = None
        if start is not None:
            runs.append(((start + self.h - 1) / 2, self.h - start))
        return runs


class Transposed:
    """A Raster seen with x and y swapped (page and pixel), so a curve that is steep in x can be followed
    row by row with the same trackers. Used with an unchanged mask m (rows of the original raster)."""

    def __init__(self, r):
        self.r, self.w, self.h, self.sx, self.sy = r, r.h, r.w, r.sy, r.sx

    def to_page(self, px, py):
        x, y = self.r.to_page(py, px)
        return y, x

    def to_px(self, x, y):
        px, py = self.r.to_px(y, x)
        return py, px

    def column_runs(self, m, px):
        runs, start, row = [], None, m[px]
        for x, v in enumerate(row):
            if v and start is None:
                start = x
            elif not v and start is not None:
                runs.append(((start + x - 1) / 2, x - start))
                start = None
        if start is not None:
            runs.append(((start + len(row) - 1) / 2, len(row) - start))
        return runs


def track(ras, m, seeds, x_lo, x_hi, max_jump=4.0, max_gap=25, max_run=None, step=1, seed_radius=6.0,
          slope_n=12):
    """Follow several curves across columns of mask m.

    seeds: {name: (page_x, page_y)} a point on each curve (near a clean, separated section).
    x_lo/x_hi: {name: page x limit} or scalar. Tracking proceeds right then left from each seed; at each
    column the run nearest the linear prediction (least-squares slope over the last slope_n points) is
    taken. A run much wider than one line (two curves merged/crossing) does not update the slope; the
    curve's own predicted position, clamped inside the merged run, is recorded instead.
    Returns {name: [(page_x, page_y), ...]} of measured points only.
    """
    out = {}
    for name, (sx, sy) in seeds.items():
        lo = x_lo[name] if isinstance(x_lo, dict) else x_lo
        hi = x_hi[name] if isinstance(x_hi, dict) else x_hi
        pts = []
        px0 = round(ras.to_px(sx, sy)[0])
        runs0 = [(c, ln) for c, ln in ras.column_runs(m, px0) if abs(c - ras.to_px(sx, sy)[1]) <= seed_radius * ras.sy]
        if not runs0:
            raise ValueError(f'seed {name} {sx:.1f},{sy:.1f}: no ink within {seed_radius} pt')
        sy_px, t_seed = min(runs0, key=lambda r: abs(r[0] - ras.to_px(sx, sy)[1]))
        for direction in (1, -1):
            hist, hx = [sy_px], [px0]
            t0 = t_seed
            gap = merged = 0
            px = px0
            while 0 <= px < ras.w:
                pxp = ras.to_page(px, 0)[0]
                if pxp < lo or pxp > hi:
                    break
                k = 0.0
                if len(hist) >= 4:
                    hxs, hys = hx[-slope_n:], hist[-slope_n:]
                    mx, my = sum(hxs) / len(hxs), sum(hys) / len(hys)
                    den = sum((a - mx) ** 2 for a in hxs)
                    k = sum((a - mx) * (b - my) for a, b in zip(hxs, hys)) / den if den else 0.0
                pred = hist[-1] + k * (px - hx[-1])
                runs = ras.column_runs(m, px)
                if max_run:
                    runs = [r for r in runs if r[1] <= max_run * ras.sy]
                best = None
                tol = max_jump * ras.sy * min(3.0, 1 + 0.05 * gap)
                for c, ln in runs:
                    d = max(0.0, abs(c - pred) - ln / 2)
                    if d <= tol and (best is None or (d, abs(c - pred)) < best[0]):
                        best = ((d, abs(c - pred)), c, ln)
                if best:
                    _, c, ln = best
                    expect = t0 * math.sqrt(1 + k * k)
                    if ln > 1.4 * expect + 2:
                        half = max(0.0, (ln - t0) / 2)
                        y = min(max(pred, c - half), c + half)
                        merged += 1
                        keep = merged > 6 * t0
                    else:
                        y, merged, keep = c, 0, True
                        t0 = 0.9 * t0 + 0.1 * min(ln / math.sqrt(1 + k * k), 2 * t0)
                    if keep:
                        hist.append(y)
                        hx.append(px)
                    gap = 0
                    if not (direction == -1 and px == px0):
                        pts.append(ras.to_page(px, y))
                else:
                    gap += 1
                    if gap > max_gap:
                        break
                px += direction * step
        pts.sort()
        out[name] = pts
    return out


def dp_track(ras, m, seeds, x_lo, x_hi, stride=2, gap_pt=6.0, max_dtheta=0.6, w_curv=4.0, gap_pen=0.02,
             bonus=0.1, seed_radius=6.0, t0=None, end='furthest', grid_h=(), grid_v=(), grid_hw=0, q_px=0.0, base_pt=0.0,
             keep=8, dev=None, seed_gap=None, seed_slope=2.0, **_):
    """Dynamic-programming curve follower, robust to crossings and merged (overlapping) lines.

    For each curve, columns are visited outward from the seed in both directions (every `stride` px).
    Candidates per column are the centres of ink runs; runs wider than ~1.5 line widths (two curves
    merged, or a steep line) also contribute candidates spaced half a line width apart across the run.
    A path picks one candidate per visited column (or skips columns spanning up to gap_pt points: dashes, grid
    lines) minimising the squared change of a smoothed direction angle; at an X-crossing the
    straight-through continuation is therefore cheaper than switching branch. The path runs to the
    furthest reachable column inside [x_lo, x_hi] (set those to the curve's visible ends).
    q_px adds an angle tolerance of atan(q_px / dx) for pixel quantisation in low-resolution bitmaps;
    base_pt > 0 measures each step's direction from the path point ~base_pt points back instead of from
    the previous column (same purpose). max_dtheta and gap_pt may be {name: value} dicts. keep = states kept per column; dev (line widths), if set, also
    limits each step's vertical offset from the slope-predicted position (blocks near-vertical jumps from a
    steep flank onto another curve, which an angle-only cost allows). seed_gap limits how many columns the first
    step from the seed may skip (the seed has no direction yet, so a long first step can land on a neighbour);
    seed_slope bounds that first step's |dy/dx| (beyond one line width).
    Returns {name: [(page_x, page_y), ...]}.
    """
    out = {}
    for name, (sx, sy) in seeds.items():
        lo = x_lo[name] if isinstance(x_lo, dict) else x_lo
        hi = x_hi[name] if isinstance(x_hi, dict) else x_hi
        mdt = max_dtheta.get(name, 0.6) if isinstance(max_dtheta, dict) else max_dtheta
        gpt = gap_pt.get(name, 6.0) if isinstance(gap_pt, dict) else gap_pt
        px0, py0 = ras.to_px(sx, sy)
        px0 = round(px0)
        runs0 = [(c, ln) for c, ln in ras.column_runs(m, px0) if abs(c - py0) <= seed_radius * ras.sy]
        if not runs0:
            raise ValueError(f'seed {name} {sx:.1f},{sy:.1f}: no ink within {seed_radius} pt')
        y0, tl = min(runs0, key=lambda r: abs(r[0] - py0))
        lw = t0 * ras.sy if t0 else max(2.0, min(tl, 3 * ras.sy))
        max_gap = max(2, int(round(gpt * ras.sx / stride)))
        pts = [(px0, y0)]
        for direction in (1, -1):
            cols = []
            px = px0 + direction * stride
            while 0 <= px < ras.w and lo <= ras.to_page(px, 0)[0] <= hi:
                cols.append(px)
                px += direction * stride
            cand = []
            for px in cols:
                cs = []
                if any(abs(px - g) <= grid_hw for g in grid_v):
                    cand.append(cs)          # vertical grid line: treat the column as a gap
                    continue
                for c, ln in ras.column_runs(m, px):
                    if ln <= 2 * grid_hw + 2 and any(abs(c - g) <= grid_hw for g in grid_h):
                        continue             # just a horizontal grid line
                    if ln <= 1.6 * lw:
                        cs.append(c)
                    else:
                        top, bot = c - ln / 2 + lw / 2, c + ln / 2 - lw / 2
                        n = max(1, int((bot - top) / (lw / 2)))
                        cs += [top + i * (bot - top) / n for i in range(n + 1)]
                cand.append(cs)
            # states[k] = list of (y, cost, slope, back, hist); back = (k', idx) or None for the seed,
            # hist = recent (x, y) path points used for the long-baseline direction
            states = [None] * len(cols)
            seed_state = (y0, 0.0, None, None, ((px0, y0),))
            base = base_pt * ras.sx
            best_end = (0.0, -1, 0)

            def preds(k):
                found = 0
                for g in range(1, max_gap + 2):
                    kk = k - g
                    if kk < -1:
                        break
                    if kk == -1:
                        if seed_gap is None or g <= seed_gap:
                            yield -1, g, [seed_state]
                        break
                    if states[kk]:
                        yield kk, g, states[kk]
                        found += 1
                        if found == 3:
                            break
            for k in range(len(cols)):
                row = []
                for y in cand[k]:
                    best = None
                    for kk, g, sts in preds(k):
                        dx = g * stride
                        for i, (ya, ca, sa, _, hist) in enumerate(sts):
                            th = math.atan2(y - ya, dx)       # direction angle (handles steep flanks)
                            if base:
                                far = [p for p in hist if abs(cols[k] - p[0]) >= base]
                                hx, hy = far[-1] if far else hist[0]
                                th = math.atan2(y - hy, abs(cols[k] - hx))
                            ds = 0.0 if sa is None else th - sa
                            if abs(ds) > mdt * min(1.5, 1 + 0.03 * g) + math.atan2(q_px, dx):
                                continue
                            if sa is None and abs(y - ya) > lw + seed_slope * dx:
                                continue
                            if dev is not None and sa is not None:
                                pred = math.tan(max(-1.5, min(1.5, sa))) * dx
                                if abs((y - ya) - pred) > dev * lw + 0.5 * abs(pred):
                                    continue
                            cost = ca + w_curv * ds * ds + gap_pen * (g - 1) ** 1.5
                            if best is None or cost < best[1]:
                                sn = th if sa is None or base else 0.7 * sa + 0.3 * th
                                h = ()
                                if base:
                                    h = hist + ((cols[k], y),)
                                    far = [j for j, p in enumerate(h) if abs(cols[k] - p[0]) >= base]
                                    h = h[far[-1]:] if far else h
                                best = (y, cost, sn, (kk, i), h)
                    if best:
                        row.append(best)
                if row:
                    # keep the cheapest few states per column
                    row.sort(key=lambda t: t[1])
                    states[k] = row[:keep]
                    if end == 'furthest':
                        best_end = (0.0, k, 0)
                    else:
                        score = row[0][1] - bonus * (k + 1)
                        if score < best_end[0]:
                            best_end = (score, k, 0)
            path = []
            k, i = best_end[1], best_end[2]
            while k >= 0:
                y, _, _, back, _ = states[k][i]
                path.append((cols[k], y))
                k, i = back
            pts += path
        out[name] = sorted(ras.to_page(px, y) for px, y in pts)
    return out


def stencil_colours(key, pno, xrefs, dpi=300):
    """For overlaid 1-bit stencil images (one curve each), return {xref: mean rendered RGB} measured
    where only that stencil has ink — identifies which paint colour each stencil was drawn with."""
    rs = {x: Raster.image(key, pno, x) for x in xrefs}
    ms = {x: r.mask(lambda a, b, c: a < 128) for x, r in rs.items()}
    page = doc(key)[pno - 1]
    r0 = rs[xrefs[0]]
    ren = Raster(page, r0.rect, dpi)
    out = {}
    for x, r in rs.items():
        acc, n = [0, 0, 0], 0
        for py in range(0, r.h, 2):
            for px in range(0, r.w, 2):
                if ms[x][py][px] and not any(ms[o][py][px] for o in xrefs if o != x):
                    qx, qy = ren.to_px(*r.to_page(px, py))
                    qx, qy = int(round(qx)), int(round(qy))
                    if 0 <= qx < ren.w and 0 <= qy < ren.h:
                        c = ren.rgb(qx, qy)
                        for k in range(3):
                            acc[k] += c[k]
                        n += 1
        out[x] = tuple(round(a / max(n, 1)) for a in acc)
    return out


def pts_to_data(pts, xa, ya):
    return sorted((xa.val(x), ya.val(y)) for x, y in pts)


def smooth(pts, half=2):
    """Moving average over ±half neighbouring traced points (removes pixel quantisation)."""
    out = []
    for i in range(len(pts)):
        win = pts[max(0, i - half):i + half + 1]
        out.append((pts[i][0], sum(p[1] for p in win) / len(win)))
    return out


def axis_from_lines(positions, values, log=False, name=''):
    """Pair detected grid-line page positions with their values (same count, same order)."""
    assert len(positions) == len(values), (name, [round(p, 2) for p in positions], values)
    return axis_from_pairs(list(zip(positions, values)), log=log, name=name)


def raster_series(pts_by_name, xa, ya, xs, half=2, nd=3):
    """Traced page points → {name: values on grid xs} (None outside each curve's traced range).
    Gaps (dashes, grid-line crossings) are bridged linearly."""
    out = {}
    for n, pts in pts_by_name.items():
        d = smooth(pts_to_data(pts, xa, ya), half)
        out[n] = rnd(interp_points(d, xs), nd)
    return out


def tick_marks(ras, m, orient, band, min_frac=0.8, span=None):
    """Tick marks along an axis: orient 'x' → short vertical ticks inside the page-y band (y0, y1),
    returned as page x centres; 'y' → horizontal ticks inside the page-x band (x0, x1), page y centres.
    span limits the search along the axis (page coordinates)."""
    if orient == 'x':
        a, b = int(ras.to_px(0, band[0])[1]), int(ras.to_px(0, band[1])[1]) + 1
        n = max(1, b - a)
        prof = [sum(m[y][x] for y in range(a, b)) / n for x in range(ras.w)]
        conv = lambda i: ras.to_page(i, 0)[0]
    else:
        a, b = int(ras.to_px(band[0], 0)[0]), int(ras.to_px(band[1], 0)[0]) + 1
        n = max(1, b - a)
        prof = [sum(m[y][a:b]) / n for y in range(ras.h)]
        conv = lambda i: ras.to_page(0, i)[1]
    groups = []
    for i, v in enumerate(prof):
        if v >= min_frac:
            if groups and i - groups[-1][-1] <= 1:
                groups[-1].append(i)
            else:
                groups.append([i])
    out = []
    for g in groups:
        w = [prof[i] for i in g]
        c = sum(i * wi for i, wi in zip(g, w)) / sum(w)
        p = conv(c)
        if span is None or span[0] <= p <= span[1]:
            out.append(p)
    return out


def uniform_axis(found, v_first, v_last, step, log=False, name=''):
    """Assign values to detected grid lines assumed evenly spaced in (log) value between the first and
    last detected line; lines that do not fall on the pattern raise."""
    f = (lambda v: math.log10(v)) if log else (lambda v: v)
    p0, p1 = found[0], found[-1]
    pairs = []
    for p in found:
        t = f(v_first) + (p - p0) / (p1 - p0) * (f(v_last) - f(v_first))
        i = round((t - f(v_first)) / step)
        v = f(v_first) + i * step
        assert abs(t - v) < 0.3 * step, (name, p, t, v)
        pairs.append((p, 10 ** v if log else round(v, 6)))
    return axis_from_pairs(pairs, log=log, name=name)


def trace_mask(ras, m, seeds, lo, hi, **kw):
    """track() wrapper returning {name: [(page_x, page_y)]} for the given mask."""
    return track(ras, m, seeds, lo, hi, **kw)


def grid_between(pts_by_name, xa, step):
    lo = min(xa.val(p[0][0]) for p in pts_by_name.values() if p)
    hi = max(xa.val(p[-1][0]) for p in pts_by_name.values() if p)
    if lo > hi:
        lo, hi = hi, lo
    return grid(lo, hi, step)

# ============================================================================ overlays

PALETTE = {'red': (0.9, 0.1, 0.1), 'green': (0.0, 0.65, 0.1), 'blue': (0.1, 0.25, 0.95),
           'cyan': (0.0, 0.7, 0.8), 'magenta': (0.85, 0.0, 0.7), 'yellow': (0.85, 0.65, 0.0),
           'minimum': (0.45, 0.45, 0.45), 'midscaleNeutral': (0.1, 0.1, 0.1), 'neutral': (0.9, 0.1, 0.1),
           'visualNeutral': (0.1, 0.1, 0.1)}
CYCLE = [(0.9, 0.1, 0.1), (0.1, 0.25, 0.95), (0.0, 0.65, 0.1), (0.85, 0.0, 0.7), (0.9, 0.5, 0.0),
         (0.0, 0.7, 0.8), (0.5, 0.2, 0.7), (0.4, 0.4, 0.0)]


def overlay(key, pno, rect, xa, ya, curves, name, title, scale=3.0, marks=()):
    """Write build/film-data/check/<name>.png: the source chart (vector-embedded, faded) with
    extracted samples as coloured dots/lines and calibration labels as green ticks.
    curves: [(label, xs, ys)] in data units."""
    os.makedirs(CHECK_DIR, exist_ok=True)
    rect = pymupdf.Rect(rect)
    W, H = rect.width * scale, rect.height * scale
    out = pymupdf.open()
    pg = out.new_page(width=W, height=H + 26)
    tgt = pymupdf.Rect(0, 26, W, 26 + H)
    show_upright(pg, tgt, key, pno, rect)
    pg.draw_rect(tgt, color=None, fill=(1, 1, 1), fill_opacity=0.45)

    def P(x, y):
        return pymupdf.Point((x - rect.x0) * scale, 26 + (y - rect.y0) * scale)
    for p, v, s in xa.labels:
        pg.draw_line(P(p, rect.y1 - 4), P(p, rect.y1), color=(0, 0.6, 0) if s else (1, 0.5, 0), width=1.2)
    for p, v, s in ya.labels:
        pg.draw_line(P(rect.x0, p), P(rect.x0 + 4, p), color=(0, 0.6, 0) if s else (1, 0.5, 0), width=1.2)
    ty = 12
    for i, (lab, xs, ys) in enumerate(curves):
        col = PALETTE.get(lab, CYCLE[i % len(CYCLE)])
        pts = [P(xa.pos(x), ya.pos(y)) for x, y in zip(xs, ys) if y is not None
               and (not ya.log or y > 0) and (not xa.log or x > 0)]
        for a, b in zip(pts, pts[1:]):
            pg.draw_line(a, b, color=col, width=0.8)
        for p in pts:
            pg.draw_circle(p, 1.6, color=col, fill=col)
        pg.insert_text((6 + 70 * (i % 8), ty + 10 * (i // 8)), lab, fontsize=8, color=col)
    for (x, y, lab) in marks:
        pg.draw_circle(P(xa.pos(x), ya.pos(y)), 3.5, color=(0, 0, 0), width=1)
    pg.insert_text((W - 6 - 4.2 * len(title), 22), title, fontsize=7, color=(0, 0, 0))
    pg.get_pixmap(dpi=110).save(os.path.join(CHECK_DIR, name + '.png'))


def show_upright(pg, tgt, key, pno, rect):
    """Embed region rect (displayed page coordinates) of the source page into tgt; show_pdf_page clips in
    unrotated coordinates, ignores /Rotate and intersects the clip with the rotated page rect, so rotated pages
    are embedded from an in-memory copy with /Rotate cleared."""
    src = doc(key)[pno - 1]
    if src.rotation:
        if ('derot', key) not in _docs:
            d = pymupdf.open(stream=doc(key).tobytes(), filetype='pdf')
            for p in d:
                p.set_rotation(0)
            _docs[('derot', key)] = d
        pg.show_pdf_page(tgt, _docs[('derot', key)], pno - 1, clip=pymupdf.Rect(rect) * ~src.rotation_matrix,
                         rotate=-src.rotation)
    else:
        pg.show_pdf_page(tgt, doc(key), pno - 1, clip=rect)


def debug_drawings(key, pno, rect, name):
    """Label every vector path intersecting rect (index + colour) → check/debug-<name>.png."""
    os.makedirs(CHECK_DIR, exist_ok=True)
    page = doc(key)[pno - 1]
    rect = pymupdf.Rect(rect)
    scale = 3.0
    out = pymupdf.open()
    pg = out.new_page(width=rect.width * scale, height=rect.height * scale)
    show_upright(pg, pg.rect, key, pno, rect)
    pg.draw_rect(pg.rect, color=None, fill=(1, 1, 1), fill_opacity=0.6)
    k = 0
    for i, dr in enumerate(page_drawings(page)):
        r = dr['rect']
        if not pymupdf.Rect(r.x0 - .5, r.y0 - .5, r.x1 + .5, r.y1 + .5).intersects(rect) or len(dr['items']) < 3:
            continue
        col = CYCLE[k % len(CYCLE)]
        k += 1
        for poly in path_polylines(dr):
            pts = [pymupdf.Point((x - rect.x0) * scale, (y - rect.y0) * scale) for x, y in poly]
            for a, b in zip(pts, pts[1:]):
                pg.draw_line(a, b, color=col, width=1.2)
            m = pts[len(pts) // 2]
            pg.insert_text(m, str(i), fontsize=9, color=col)
    pg.get_pixmap(dpi=110).save(os.path.join(CHECK_DIR, 'debug-' + name + '.png'))

# ============================================================================ checks


def gamma_fit(logh, dens, lo_frac=0.25, hi_frac=0.75):
    """Slope of the straight-line portion: least squares over the central density range."""
    pts = [(x, y) for x, y in zip(logh, dens) if y is not None]
    ys = [y for _, y in pts]
    dmin, dmax = min(ys), max(ys)
    lo, hi = dmin + lo_frac * (dmax - dmin), dmin + hi_frac * (dmax - dmin)
    sel = [(x, y) for x, y in pts if lo <= y <= hi]
    n = len(sel)
    if n < 3:
        return None
    mx, my = sum(x for x, _ in sel) / n, sum(y for _, y in sel) / n
    return sum((x - mx) * (y - my) for x, y in sel) / sum((x - mx) ** 2 for x, _ in sel)


def peak(wl, vals):
    pts = [(v, w) for w, v in zip(wl, vals) if v is not None]
    return max(pts)[1] if pts else None


def monotonic(vals, sign, tol=0.02):
    """True if vals never move against `sign` by more than tol."""
    v = [x for x in vals if x is not None]
    return all(sign * (b - a) >= -tol for a, b in zip(v, v[1:]))


# ============================================================================ output

STOCKS = {}


def stock(fn):
    STOCKS[fn.__name__.replace('_', '-')] = fn
    return fn


def to_json(v, ind=0):
    """JSON with scalar arrays kept on one line."""
    pad, pad1 = '  ' * ind, '  ' * (ind + 1)
    if isinstance(v, dict):
        if not v:
            return '{}'
        items = [f'{pad1}{json.dumps(k)}: {to_json(x, ind + 1)}' for k, x in v.items()]
        return '{\n' + ',\n'.join(items) + '\n' + pad + '}'
    if isinstance(v, (list, tuple)):
        if all(not isinstance(x, (dict, list, tuple)) for x in v):
            return '[' + ', '.join(json.dumps(x, ensure_ascii=False) for x in v) + ']'
        return '[\n' + ',\n'.join(pad1 + to_json(x, ind + 1) for x in v) + '\n' + pad + ']'
    return json.dumps(v, ensure_ascii=False)


def write(data):
    path = os.path.join(HERE, data['id'] + '.json')
    with open(path, 'w') as f:
        f.write(to_json(data) + '\n')
    return path


def main(argv):
    if argv and argv[0] == '--debug':
        key, pno = argv[1], int(argv[2])
        rect = tuple(map(float, argv[3:7]))
        debug_drawings(key, pno, rect, f'{key}-p{pno}-{int(rect[0])}-{int(rect[1])}')
        return
    names = argv or list(STOCKS)
    for n in names:
        data = STOCKS[n]()
        print(write(data))
        for line in data.get('extraction', {}).get('checks', []):
            print('   ', line)


# ============================================================================ chart helpers

MTF_FREQS = [1, 1.5, 2, 2.5, 3, 4, 5, 6, 7, 8, 10, 12, 15, 20, 25, 30, 35, 40, 50, 60, 70, 80, 100,
             120, 150, 200, 250, 300]


def frame_axes(page, F, xvalues=None, yvalues=None, xlog=False, ylog=False, xlab=None, ylab=None,
               xdrop=(), ydrop=()):
    """Axes for a vector chart with plot frame F, labels below and to the left."""
    F = pymupdf.Rect(F)
    xlab = xlab or (F.x0 - 5, F.y1 + 2, F.x1 + 8, F.y1 + 15)
    ylab = ylab or (F.x0 - 26, F.y0 - 5, F.x0 - 1, F.y1 + 4)
    xa = axis_from_labels(page, xlab, 'x', values=xvalues, span=(F.y0, F.y1 + 6), log=xlog, name='x', drop=xdrop)
    ya = axis_from_labels(page, ylab, 'y', values=yvalues, span=(F.x0 - 6, F.x1), log=ylog, name='y', drop=ydrop)
    return xa, ya


def sample_named(named, xa, ya, xs, pick='mean'):
    """named: {label: [polylines]} → ({label: ys}, folds)."""
    res, folds = {}, {}
    for lab, polys in named.items():
        lo, hi = curve_range(polys, xa)
        sub = [x for x in xs if lo - 1e-6 <= x <= hi + 1e-6]
        ys, f = sample_curve(polys, xa, ya, sub, pick=pick)
        m = dict(zip(sub, ys))
        res[lab] = [m.get(x) for x in xs]
        folds[lab] = f
    return res, folds


def union_grid(named, xa, step):
    lo = min(curve_range(p, xa)[0] for p in named.values())
    hi = max(curve_range(p, xa)[1] for p in named.values())
    return grid(lo, hi, step)


def mtf_grid(lo, hi):
    return [f for f in MTF_FREQS if lo - 1e-6 <= f <= hi + 1e-6]


def by_peak(curves, xa, ya, bands, extra=None):
    """Assign curves to names by the x of their maximum data y. bands: {name: (lo, hi)}.
    extra: {name: (lo, hi)} — a further piece lying wholly inside x-range (lo, hi) is appended to name
    (e.g. a secondary lobe drawn as a separate path)."""
    out = {}
    rest = []
    for c in curves:
        pts = [(ya.val(y), xa.val(x)) for p in c['polys'] for x, y in p]
        pk = max(pts)[1]
        x0, x1 = curve_range(c['polys'], xa)
        ex = [n for n, (lo, hi) in (extra or {}).items() if lo <= x0 and x1 <= hi]
        if ex:
            rest.append((ex[0], c))
            continue
        for n, (lo, hi) in bands.items():
            if lo <= pk <= hi:
                assert n not in out, (n, pk)
                out[n] = c['polys']
    for n, c in rest:
        out[n] = out[n] + c['polys']
    assert set(out) == set(bands), (list(out), [max((ya.val(y), xa.val(x)) for p in c['polys'] for x, y in p)[1] for c in curves])
    return out


def by_order_at(curves, xa, ya, xdata, names, reverse=False):
    """Assign names top→bottom (highest data value first) by the value at xdata (or nearest end)."""
    vals = []
    for c in curves:
        v, _ = sample_curve(c['polys'], xa, ya, [xdata])
        if v[0] is None:
            pts = [(abs(xa.val(x) - xdata), ya.val(y)) for p in c['polys'] for x, y in p]
            v = [min(pts)[1]]
        vals.append((v[0], c))
    vals.sort(key=lambda t: t[0], reverse=not reverse)
    assert len(vals) == len(names), (len(vals), names)
    return {n: c['polys'] for n, (_, c) in zip(names, vals)}


def vchart(key, pno, F, assign, step, slug, title, xvalues=None, yvalues=None, xlog=False, ylog=False,
           nd=3, floor=None, pick='mean', min_width=15, max_width_frac=1.01, xlab=None, ylab=None,
           order=None, xdrop=(), ydrop=(), yaxis=None, xaxis=None):
    """Extract one vector chart. assign(curves, xa, ya) → {name: polylines}.
    step: sampling step in data x, or 'mtf' for the standard log-spaced frequency list.
    floor: drop samples within 0.015 of the chart bottom (curves clipped onto the frame).
    Returns dict(x=[...], ys={name: [...]}, axes=(xa, ya), folds={...})."""
    page = doc(key)[pno - 1]
    if yaxis is None or xaxis is None:
        xa, ya = frame_axes(page, F, xvalues=xvalues, yvalues=yvalues, xlog=xlog, ylog=ylog, xlab=xlab,
                            ylab=ylab, xdrop=xdrop, ydrop=ydrop)
    xa, ya = xaxis or xa, yaxis or ya
    W = F[2] - F[0]
    cs = [c for c in chain_curves(vector_curves(page, F, min_pts=2))
          if min_width < c['rect'].width <= max_width_frac * W]
    named = assign(cs, xa, ya)
    if step == 'mtf':
        lo = min(curve_range(p, xa)[0] for p in named.values())
        hi = max(curve_range(p, xa)[1] for p in named.values())
        xs = mtf_grid(lo, hi)
    else:
        xs = union_grid(named, xa, step)
    ys, folds = sample_named(named, xa, ya, xs, pick=pick)
    if floor:
        fl = ya.val(F[3])
        ys = {k: [None if v is not None and v < fl + 0.015 else v for v in vs] for k, vs in ys.items()}
    ys = {k: rnd(v, nd) for k, v in ys.items()}
    names = order or list(named)
    overlay(key, pno, F, xa, ya, [(k, xs, ys[k]) for k in names], slug, title)
    return dict(x=xs, ys=ys, axes=(xa, ya), folds=folds)


def hi_x(cs, xa):
    return max(curve_range(c['polys'], xa)[1] for c in cs)


def lo_x(cs, xa):
    return min(curve_range(c['polys'], xa)[0] for c in cs)


BANDS_RGB = {'blue': (380, 495), 'green': (500, 595), 'red': (600, 720)}
BANDS_DYE = {'yellow': (400, 495), 'magenta': (500, 595), 'cyan': (600, 720)}


class Checks(list):
    def add(self, s):
        self.append(s)


def kodak_colour_negative(key, pno, char_F, sens_F, dye_F, mtf_F, slug, char_xvalues=None,
                          dye_names=None, mtf_names=('blue', 'green', 'red'), sens_extra=None, pages=None):
    """Kodak Alaris still-film layout (Portra/Ektar/Gold): four vector charts, on page pno unless
    pages = {'char'|'sens'|'dye'|'mtf': page} says otherwise."""
    pages, pno0 = pages or {}, pno

    def pg(n):
        return doc(key)[pages.get(n, pno0) - 1], pages.get(n, pno0)
    chk = Checks()
    out = {}

    # characteristic curves
    page, pno = pg('char')
    xa, ya = frame_axes(page, char_F, xvalues=char_xvalues)
    cs = chain_curves(vector_curves(page, char_F, min_pts=2))
    named = by_order_at(cs, xa, ya, curve_range(cs[0]['polys'], xa)[0] + 0.05, ['blue', 'green', 'red'])
    xs = union_grid(named, xa, 0.05)
    ys, folds = sample_named(named, xa, ya, xs)
    out['char'] = dict(logExposure=xs, **{k: rnd(v) for k, v in ys.items()})
    out['char_axes'] = (xa, ya)
    for c in ('red', 'green', 'blue'):
        g = gamma_fit(xs, ys[c])
        chk.add(f'characteristic {c}: gamma {g:.3f}, D-min {ys[c][0]:.3f}, monotonic {monotonic(ys[c], 1)}')
        out.setdefault('gamma', {})[c] = round(g, 3)
    overlay(key, pno, char_F, xa, ya, [(k, xs, out['char'][k]) for k in ('red', 'green', 'blue')],
            f'{slug}-characteristic', f'{SOURCES[key]["document"]} p{pno} characteristic curves')

    # spectral sensitivity
    page, pno = pg('sens')
    xa, ya = frame_axes(page, sens_F)
    cs = [c for c in vector_curves(page, sens_F, min_pts=2) if c['rect'].width < 0.8 * (sens_F[2] - sens_F[0])]
    cs = chain_curves(cs)
    named = by_peak(cs, xa, ya, {'blue': (380, 490), 'green': (500, 590), 'red': (600, 700)}, extra=sens_extra)
    wl = union_grid(named, xa, 5)
    ys, folds = sample_named(named, xa, ya, wl)
    floor = ya.val(sens_F[3])
    ys = {k: [None if v is not None and v < floor + 0.015 else v for v in vs] for k, vs in ys.items()}
    out['sens'] = dict(wavelength=wl, **{k: rnd(v) for k, v in ys.items()})
    for c in ('red', 'green', 'blue'):
        chk.add(f'sensitivity {c}: peak {peak(wl, ys[c])} nm, folds {folds[c]}')
    out['sens_peaks'] = {c: peak(wl, ys[c]) for c in ('red', 'green', 'blue')}
    overlay(key, pno, sens_F, xa, ya, [(k, wl, out['sens'][k]) for k in ('red', 'green', 'blue')],
            f'{slug}-sensitivity', f'{SOURCES[key]["document"]} p{pno} spectral sensitivity')

    # spectral dye density
    page, pno = pg('dye')
    xa, ya = frame_axes(page, dye_F)
    cs = [c for c in chain_curves(vector_curves(page, dye_F, min_pts=2)) if c['rect'].width > 20]
    names = dye_names or ['midscaleNeutral', 'minimum']
    named = by_order_at(cs, xa, ya, 550, names)
    wl = union_grid(named, xa, 5)
    ys, folds = sample_named(named, xa, ya, wl)
    out['dye'] = dict(wavelength=wl, **{k: rnd(v) for k, v in ys.items()})
    for n in names:
        chk.add(f'dye {n}: peak {peak(wl, ys[n])} nm, range {min(v for v in ys[n] if v is not None):.3f}..'
                f'{max(v for v in ys[n] if v is not None):.3f}')
    overlay(key, pno, dye_F, xa, ya, [(k, wl, out['dye'][k]) for k in names],
            f'{slug}-dye-density', f'{SOURCES[key]["document"]} p{pno} spectral dye density')

    # MTF
    if mtf_F:
        page, pno = pg('mtf')
        xa, ya = frame_axes(page, mtf_F, xlog=True, ylog=True)
        cs = [c for c in chain_curves(vector_curves(page, mtf_F, min_pts=2)) if 15 < c['rect'].width < 0.9 * (mtf_F[2] - mtf_F[0])]
        hi = max(curve_range(c['polys'], xa)[1] for c in cs)
        named = by_order_at(cs, xa, ya, hi - 0.01, list(mtf_names))
        lo = min(curve_range(c['polys'], xa)[0] for c in cs)
        fr = mtf_grid(lo, hi)
        ys, folds = sample_named(named, xa, ya, fr)
        out['mtf'] = dict(frequency=fr, **{k: rnd(v, 1) for k, v in ys.items()})
        chk.add('mtf: ' + ', '.join(f'{k} {v[-1] if v else None}% at {fr[-1]} c/mm' for k, v in out['mtf'].items()
                                   if k != 'frequency'))
        overlay(key, pno, mtf_F, xa, ya, [(k, fr, out['mtf'][k]) for k in mtf_names],
                f'{slug}-mtf', f'{SOURCES[key]["document"]} p{pno} MTF')
    out['checks'] = chk
    return out


def base_record(id_, name, manufacturer, type_, process, ei, key, pages):
    return {'schemaVersion': 1, 'id': id_, 'name': name, 'manufacturer': manufacturer, 'type': type_,
            'process': process, 'exposureIndex': ei, 'source': source_block(key, pages)}


def pgi_table(rows):
    """rows: [(negative format, print size, magnification, value-as-printed)]"""
    return [{'negativeFormat': f, 'printSize': p, 'magnification': m, 'printGrainIndex': v} for f, p, m, v in rows]


PGI_NOTE = ('Kodak Print Grain Index: perceptual graininess of a print made with diffuse printing '
            'illumination viewed at 14 in; 25 is the approximate visual threshold, 4 units is one just-'
            'noticeable difference. Not comparable with rms granularity. Values as printed ("<25" = less than 25).')

LOGH_UNITS = 'log10 exposure in lux-seconds'
LOGS_UNITS = ('log10 spectral sensitivity; sensitivity = reciprocal of the exposure (erg/cm^2) required to '
              'produce the stated density')


def derived_block(char=None, sens=None, dye=None, reversal=False):
    d = {'note': 'Computed by extract.py from the digitised curves as sanity checks; not published values.'}
    if char:
        keys = [k for k in ('red', 'green', 'blue', 'neutral') if k in char and char[k] is not None]
        span = {k: max(v for v in char[k] if v is not None) - min(v for v in char[k] if v is not None) for k in keys}
        d['gamma'] = {k: (round(gamma_fit(char['logExposure'], char[k]), 3) if span[k] > 0.6 * max(span.values())
                          else None) for k in keys}
        d['gammaMethod'] = 'least-squares slope over the central 25-75% of each curve\'s density range'
        d['monotonic'] = {k: monotonic(char[k], -1 if reversal else 1) for k in keys}
    if sens:
        d['sensitivityPeakNm'] = {k: peak(sens['wavelength'], sens[k]) for k in ('red', 'green', 'blue', 'neutral')
                                  if sens.get(k)}
    if dye:
        d['dyePeakNm'] = {k: peak(dye['wavelength'], dye[k]) for k in ('cyan', 'magenta', 'yellow')
                          if dye.get(k)}
    return d


def kodak_cn_record(r, id_, name, ei, key, pages, logh_ref, char_exposure, sens_exposure, pgi, mtf=True,
                    notes=(), dye_note=None):
    rec = base_record(id_, name, 'Kodak Alaris (KODAK PROFESSIONAL / KODAK brand)', 'negative',
                      'C-41 (KODAK FLEXICOLOR chemicals)', ei, key, pages)
    rec['characteristicCurves'] = {
        'densityType': 'status-M', 'exposure': char_exposure, 'logHRef': logh_ref,
        'logExposureUnits': LOGH_UNITS, 'logExposure': r['char']['logExposure'],
        'red': r['char']['red'], 'green': r['char']['green'], 'blue': r['char']['blue'],
        'dMin': {c: r['char'][c][0] for c in ('red', 'green', 'blue')},
        'notes': 'Status M densities of the processed negative (includes the orange mask). dMin = density at the '
                 'lowest plotted exposure (base + fog + mask). "Log H Ref" is printed on the chart.'}
    rec['spectralSensitivity'] = {
        'units': LOGS_UNITS, 'densityCriterion': '0.2 above D-min (Status M)', 'exposure': sens_exposure,
        'wavelength': r['sens']['wavelength'], 'red': r['sens']['red'], 'green': r['sens']['green'],
        'blue': r['sens']['blue'],
        'notes': 'red = red-sensitive (cyan-forming) layer, green = green-sensitive (magenta-forming), '
                 'blue = blue-sensitive (yellow-forming). Curves end where the published curves end.'}
    rec['dyeDensity'] = {
        'units': 'diffuse spectral density', 'wavelength': r['dye']['wavelength'],
        'cyan': None, 'magenta': None, 'yellow': None,
        'minimum': r['dye']['minimum'], 'midscaleNeutral': r['dye']['midscaleNeutral'],
        'notes': dye_note or ('Not published per dye: the datasheet shows only "typical densities for a midscale '
                              'neutral subject and D-min". cyan/magenta/yellow are therefore null.')}
    rec['granularity'] = {'rmsDiffuse': None, 'printGrainIndex': pgi_table(pgi), 'notes': PGI_NOTE +
                          ' Kodak no longer publishes rms granularity for this film.'}
    if mtf:
        rec['mtf'] = {'units': 'percent response', 'frequencyUnits': 'cycles/mm', 'exposure': 'Daylight',
                      'process': 'C-41', 'frequency': r['mtf']['frequency'], 'red': r['mtf']['red'],
                      'green': r['mtf']['green'], 'blue': r['mtf']['blue']}
    else:
        rec['mtf'] = None
    rec['interlayer'] = None
    rec['notes'] = list(notes)
    rec['derived'] = derived_block(rec['characteristicCurves'], rec['spectralSensitivity'])
    rec['extraction'] = {'method': 'vector', 'tool': 'research/film-data/extract.py',
                         'notes': 'All charts are vector paths in the PDF; curves were sampled directly from '
                                  'the path geometry (Bezier segments flattened), axes calibrated by snapping '
                                  'tick labels to the tick marks (max calibration residual < 0.002 units).',
                         'confidence': 'high', 'checks': list(r['checks'])}
    return rec

# ============================================================================ stocks


@stock
def kodak_portra_400():
    r = kodak_colour_negative('e4050', 4, (81.2, 102.9, 265.6, 287.4), (76.2, 343.1, 276.7, 494.6),
                              (357.1, 103.7, 541.8, 288.1), (348.4, 345.4, 551.7, 511.2), 'kodak-portra-400')
    pgi = [('135 (24x36 mm)', '4x6 in', '4.4X', 37), ('135 (24x36 mm)', '8x10 in', '8.8X', 59),
           ('135 (24x36 mm)', '16x20 in', '17.8X', 89),
           ('120 (6x6 cm)', '4x6 in', '2.6X', 25), ('120 (6x6 cm)', '8x10 in', '4.4X', 37),
           ('120 (6x6 cm)', '16x20 in', '8.8X', 59),
           ('4x5 in sheet', '4x6 in', '1.2X', '<25'), ('4x5 in sheet', '8x10 in', '2X', '<25'),
           ('4x5 in sheet', '16x20 in', '4X', 36)]
    return kodak_cn_record(r, 'kodak-portra-400', 'KODAK PROFESSIONAL PORTRA 400 Film', 400, 'e4050', [3, 4],
                           -1.44, 'Daylight', 'Daylight, effective exposure 1/50 s', pgi)


@stock
def kodak_ektar_100():
    r = kodak_colour_negative('e4046', 4, (81.2, 107.9, 265.7, 292.4), (74.2, 356.6, 274.7, 508.0),
                              (357.5, 106.0, 541.8, 290.4), (347.6, 358.2, 550.1, 511.2), 'kodak-ektar-100')
    pgi = [('135 (24x36 mm)', '4x6 in', '4.4X', '<25'), ('135 (24x36 mm)', '8x10 in', '8.8X', 38),
           ('135 (24x36 mm)', '16x20 in', '17.8X', 66),
           ('120 (6x6 cm)', '4x6 in', '2.6X', '<25'), ('120 (6x6 cm)', '8x10 in', '4.4X', '<25'),
           ('120 (6x6 cm)', '16x20 in', '8.8X', 38),
           ('4x5 in sheet', '4x6 in', '1.2X', '<25'), ('4x5 in sheet', '8x10 in', '4X (as printed)', '<25'),
           ('4x5 in sheet', '16x20 in', '8X (as printed)', '<25'),
           ('8x10 in sheet', '4x6 in', '0.6X', '<25'), ('8x10 in sheet', '8x10 in', '1X', '<25'),
           ('8x10 in sheet', '16x20 in', '2X', '<25')]
    return kodak_cn_record(r, 'kodak-ektar-100', 'KODAK PROFESSIONAL EKTAR 100 Film', 100, 'e4046', [3, 4],
                           -0.84, 'Daylight', 'Daylight, effective exposure 1/25 s', pgi)


@stock
def kodak_endura_premier():
    slug, key = 'kodak-endura-premier', 'e4070'
    doc_ = SOURCES[key]['document']
    ch = vchart(key, 4, (364.7, 72.5, 549.2, 257.2),
                lambda cs, xa, ya: by_order_at(cs, xa, ya, hi_x(cs, xa) - 0.05, ['red', 'green', 'blue']),
                0.05, slug + '-characteristic', f'{doc_} p4 characteristic curves', min_width=40)
    se = vchart(key, 4, (350.6, 315.7, 551.1, 467.3), lambda cs, xa, ya: by_peak(cs, xa, ya, BANDS_RGB),
                5, slug + '-sensitivity', f'{doc_} p4 spectral sensitivity', max_width_frac=0.8)
    dy = vchart(key, 5, (76.8, 86.6, 261.3, 270.9), lambda cs, xa, ya: by_peak(cs, xa, ya, BANDS_DYE),
                5, slug + '-dye-density', f'{doc_} p5 spectral dye density')
    rec = base_record(slug, 'KODAK PROFESSIONAL ENDURA Premier Paper', 'Eastman Kodak Company', 'print',
                      'RA-4 (KODAK EKTACOLOR RA chemicals)', None, key, [1, 3, 4, 5])
    rec['support'] = 'resin-coated colour paper (reflection print material)'
    rec['characteristicCurves'] = {
        'densityType': 'status-A (reflection)', 'exposure': '0.5 second', 'process': 'RA-4, 95°F (35°C), 45 s',
        'logExposureUnits': LOGH_UNITS, 'logExposure': ch['x'], **ch['ys'],
        'dMin': {c: ch['ys'][c][0] for c in ('red', 'green', 'blue')},
        'notes': 'Status A reflection densities as printed. The chart does not state the exposing illuminant.'}
    rec['spectralSensitivity'] = {
        'units': LOGS_UNITS, 'densityCriterion': None, 'exposure': 'effective exposure 0.5 s', 'process': 'RA-4',
        'wavelength': se['x'], **se['ys'],
        'notes': 'The chart does not state the density at which sensitivity is defined (densityCriterion null). '
                 'red = red-sensitive (cyan-forming), green = magenta-forming, blue = yellow-forming layer.'}
    rec['dyeDensity'] = {
        'units': 'diffuse spectral density', 'process': 'RA-4', 'wavelength': dy['x'],
        'cyan': dy['ys']['cyan'], 'magenta': dy['ys']['magenta'], 'yellow': dy['ys']['yellow'],
        'minimum': None, 'midscaleNeutral': None,
        'notes': 'Each dye curve peaks at 1.00; the curves appear peak-normalised although the chart does not '
                 'say so. No D-min or neutral curve is published.'}
    rec['granularity'] = None
    rec['mtf'] = None
    rec['interlayer'] = None
    rec['notes'] = ['Exposure index is not applicable to paper (null). E-4070 publishes no granularity, '
                    'sharpness or MTF data.',
                    'Selected as the RA-4 paper because it publishes spectral sensitivity and spectral dye '
                    'density curves as vector graphics.']
    rec['derived'] = derived_block(rec['characteristicCurves'], rec['spectralSensitivity'], rec['dyeDensity'])
    rec['extraction'] = {'method': 'vector', 'tool': 'research/film-data/extract.py',
                         'notes': 'All three charts are vector paths; sampled from path geometry with tick-snapped '
                                  'axes. The three characteristic curves overlap through the straight line; they '
                                  'are separate paths, labelled R/G/B by their order at D-max (R highest).',
                         'confidence': 'high', 'checks': []}
    return rec


FUJI_GRAIN_NOTE = ('Fujifilm diffuse rms granularity (x1000), 48 µm aperture, at density 1.0 above D-min; '
                   'Fujifilm notes it cannot be compared with colour reversal film values.')


@stock
def fuji_superia_xtra_400():
    slug, key = 'fuji-superia-xtra-400', 'af3-0217e'
    doc_ = SOURCES[key]['document']
    page = doc(key)[5]
    ch = vchart(key, 6, (85.1, 104.5, 280.8, 277.5),
                lambda cs, xa, ya: by_order_at(cs, xa, ya, lo_x(cs, xa) + 0.05, ['blue', 'green', 'red']),
                0.05, slug + '-characteristic', f'{doc_} p6 characteristic curves', min_width=60)
    # Relative log sensitivity: the only scale is a "1.0" bar spanning the two horizontal grid lines.
    rel = axis_from_pairs([(219.1, 0.0), (161.9, 1.0)], name='relative log S')
    xs_ = axis_from_labels(page, (334, 277, 540, 292), 'x', span=(104.8, 281))
    se = vchart(key, 6, (339.1, 104.8, 533.6, 275.6), lambda cs, xa, ya: by_peak(cs, xa, ya, BANDS_RGB),
                5, slug + '-sensitivity', f'{doc_} p6 spectral sensitivity (relative)', yaxis=rel, xaxis=xs_,
                min_width=30, max_width_frac=0.8)
    dy = vchart(key, 6, (333.5, 388.4, 538.7, 536.8),
                lambda cs, xa, ya: by_order_at(cs, xa, ya, 550, ['midscaleNeutral', 'minimum']),
                5, slug + '-dye-density', f'{doc_} p6 spectral dye density')
    mt = vchart(key, 6, (93.4, 389.5, 270.7, 537.3), lambda cs, xa, ya: {'neutral': cs[0]['polys']},
                'mtf', slug + '-mtf', f'{doc_} p6 MTF', xlog=True, ylog=True, nd=1, max_width_frac=0.9)
    rec = base_record(slug, 'FUJICOLOR SUPERIA X-TRA 400 [CH]', 'FUJIFILM Corporation', 'negative',
                      'CN-16 family (CN-16, CN-16Q, CN-16FA, CN-16L, CN-16S) or C-41', 400, key, [1, 3, 5, 6])
    rec['characteristicCurves'] = {
        'densityType': 'status-M', 'exposure': 'Daylight, 1/125 s', 'process': 'CN-16',
        'logExposureUnits': LOGH_UNITS, 'logExposure': ch['x'], **ch['ys'],
        'dMin': {c: ch['ys'][c][0] for c in ('red', 'green', 'blue')},
        'notes': 'Status M densities including the orange mask; dMin = density at the lowest plotted exposure.'}
    rec['spectralSensitivity'] = {
        'units': 'relative log10 spectral sensitivity (arbitrary common offset); sensitivity = reciprocal of the '
                 'exposure (J/cm^2) required to produce the stated density',
        'densityCriterion': '1.0 above D-min (Status M)', 'process': 'CN-16', 'wavelength': se['x'], **se['ys'],
        'notes': 'The chart has no absolute log-sensitivity scale, only a 1.0 log-unit scale bar spanning two grid '
                 'lines; values are relative to the lower of those lines (0.0). Inter-layer offsets are as '
                 'published; the absolute level is unknown.'}
    rec['dyeDensity'] = {
        'units': 'spectral diffuse density', 'wavelength': dy['x'], 'cyan': None, 'magenta': None, 'yellow': None,
        'minimum': dy['ys']['minimum'], 'midscaleNeutral': dy['ys']['midscaleNeutral'],
        'notes': 'Only "typical densities for a mid-scale neutral subject and for D-min" are published; '
                 'per-dye curves are not, so cyan/magenta/yellow are null.'}
    rec['granularity'] = {'rmsDiffuse': 4, 'printGrainIndex': None, 'notes': FUJI_GRAIN_NOTE}
    rec['resolvingPower'] = {'linesPerMm': {'1.6:1': 50, '1000:1': 125}, 'notes': 'Test-object contrast ratios.'}
    rec['mtf'] = {'units': 'percent response', 'frequencyUnits': 'cycles/mm', 'exposure': 'Daylight',
                  'process': 'CN-16', 'frequency': mt['x'], 'neutral': mt['ys']['neutral'],
                  'notes': 'A single curve is published; the layer/colour it refers to is not stated.'}
    rec['interlayer'] = ('Layer structure (p5): blue-sensitive layer with colourless yellow coupler, yellow filter '
                         'layer, green-sensitive layer with yellow-coloured magenta coupler, red-sensitive layer '
                         'with red-coloured cyan coupler, antihalation layer. The coloured couplers form the '
                         'integral mask. No interimage data are published.')
    rec['notes'] = ['ISO 400/27° daylight; ISO 100/21° under 3200 K tungsten with Wratten 80A.']
    rec['derived'] = derived_block(rec['characteristicCurves'], rec['spectralSensitivity'])
    rec['extraction'] = {'method': 'vector', 'tool': 'research/film-data/extract.py',
                         'notes': 'All four charts are vector paths (each chart\'s curves are sub-paths of one '
                                  'path); sampled from path geometry with tick-snapped axes.',
                         'confidence': 'high', 'checks': []}
    return rec


@stock
def fuji_pro_400h():
    slug, key = 'fuji-pro-400h', 'pro400h'
    doc_ = SOURCES[key]['document']
    # Axis numbers on this page are glyph outlines, not text: axes are taken from the grid lines.
    ch = vchart(key, 6, (82.2, 216.4, 286.9, 384.4),
                lambda cs, xa, ya: by_order_at(cs, xa, ya, lo_x(cs, xa) + 0.05, ['blue', 'green', 'red']),
                0.05, slug + '-characteristic', f'{doc_} p6 characteristic curves', min_width=60,
                xaxis=axis_from_pairs([(82.2 + i * (286.9 - 82.2) / 10, -4.0 + 0.5 * i) for i in range(11)],
                                      name='logH'),
                yaxis=axis_from_pairs([(216.4, 3.5), (240.0, 3.0), (264.5, 2.5), (288.0, 2.0), (312.2, 1.5),
                                       (336.3, 1.0), (360.1, 0.5), (384.4, 0.0)], name='D'))
    rel = axis_from_pairs([(328.7, 0.0), (272.6, 1.0)], name='relative log S')
    wl = axis_from_pairs([(345.2, 400), (402.8, 500), (460.6, 600), (518.3, 700)], name='nm')

    def sens_assign(cs, xa, ya):
        solid = [c for c in cs if dash_key(c) == 'solid']
        dashed = [c for c in cs if dash_key(c) != 'solid']
        out = by_peak(solid, xa, ya, BANDS_RGB)
        assert len(dashed) == 1, [dash_key(c) for c in cs]
        out['fourthLayer'] = dashed[0]['polys']
        return out
    se = vchart(key, 6, (334.0, 216.5, 530.6, 384.9), sens_assign, 5, slug + '-sensitivity',
                f'{doc_} p6 spectral sensitivity (relative)', yaxis=rel, xaxis=wl, min_width=10, max_width_frac=0.8)
    dy = vchart(key, 6, (331.2, 462.3, 530.4, 627.5),
                lambda cs, xa, ya: by_order_at(cs, xa, ya, 550, ['midscaleNeutral', 'minimum']),
                5, slug + '-dye-density', f'{doc_} p6 spectral dye density',
                xaxis=axis_from_pairs([(331.4, 400), (393.8, 500), (456.3, 600), (519.3, 700)], name='nm'),
                yaxis=axis_from_pairs([(474.1, 2.0), (512.3, 1.5), (551.0, 1.0), (590.8, 0.5)], name='D'))
    mt = vchart(key, 6, (83.0, 462.8, 286.4, 626.9), lambda cs, xa, ya: {'neutral': cs[0]['polys']},
                'mtf', slug + '-mtf', f'{doc_} p6 MTF', nd=1, max_width_frac=0.9,
                xaxis=axis_from_pairs([(148.2, 5), (173.5, 10), (199.3, 20), (231.3, 50), (257.7, 100),
                                       (286.4, 200)], log=True, name='c/mm'),
                yaxis=axis_from_pairs([(462.8, 150), (478.1, 100), (491.9, 70), (504.2, 50), (523.6, 30),
                                       (539.8, 20), (565.4, 10), (578.7, 7), (591.8, 5), (611.3, 3), (626.9, 2)],
                                      log=True, name='%'))
    rec = base_record(slug, 'FUJICOLOR PRO400H Professional', 'FUJIFILM Corporation', 'negative',
                      'CN-16 family or C-41', 400, key, [1, 2, 3, 5, 6])
    rec['characteristicCurves'] = {
        'densityType': 'status-M equivalent', 'exposure': 'Daylight, 1/125 s', 'process': 'CN-16',
        'logExposureUnits': LOGH_UNITS, 'logExposure': ch['x'], **ch['ys'],
        'dMin': {c: ch['ys'][c][0] for c in ('red', 'green', 'blue')},
        'notes': 'Status M (equivalent) densities including the orange mask; dMin = density at the lowest plotted '
                 'exposure. The chart\'s axis numbers are drawn as outlines, so axes were calibrated on the grid '
                 'lines (-4.0..+1.0 log H in 0.5 steps; 0..3.5 D in 0.5 steps).'}
    rec['spectralSensitivity'] = {
        'units': 'relative log10 spectral sensitivity (arbitrary common offset); sensitivity = reciprocal of the '
                 'exposure (J/cm^2) required to produce the stated density',
        'densityCriterion': '1.0 above D-min (Status M equivalent)', 'process': 'CN-16', 'wavelength': se['x'],
        **se['ys'],
        'notes': 'The chart has no absolute log-sensitivity scale, only a "1.0" scale bar between two horizontal '
                 'lines; values are relative to the lower line (0.0). fourthLayer is the dashed curve labelled '
                 '"第4の感色層" (fourth colour-sensitive layer). Fujifilm\'s layer diagram places it between the '
                 'green- and red-sensitive layers and says it forms a light magenta image; it is not one of the '
                 'three image-forming channels and its role (interimage/colour correction) is only described '
                 'qualitatively. Inter-layer offsets are as published; the absolute level is unknown.'}
    rec['dyeDensity'] = {
        'units': 'spectral diffuse density', 'wavelength': dy['x'], 'cyan': None, 'magenta': None, 'yellow': None,
        'minimum': dy['ys']['minimum'], 'midscaleNeutral': dy['ys']['midscaleNeutral'],
        'notes': 'Only "densities given by a neutral subject and minimum density (example measurement)" are '
                 'published (中間濃度 / 最小濃度); per-dye curves are not, so cyan/magenta/yellow are null.'}
    rec['granularity'] = {'rmsDiffuse': 4, 'printGrainIndex': None, 'notes': FUJI_GRAIN_NOTE}
    rec['resolvingPower'] = {'linesPerMm': {'1.6:1': 50, '1000:1': 125}, 'notes': 'Test-object contrast ratios.'}
    rec['mtf'] = {'units': 'percent response', 'frequencyUnits': 'cycles/mm', 'exposure': 'Daylight',
                  'process': 'CN-16', 'frequency': mt['x'], 'neutral': mt['ys']['neutral'],
                  'notes': 'A single curve is published; the layer/colour it refers to is not stated. The '
                           'frequency grid lines are drawn unevenly (least-squares fit on 5-200 c/mm, residual up '
                           'to ~2 pt ≈ 0.02 decade).'}
    rec['interlayer'] = ('Layer structure (p5): blue-sensitive layer (colourless yellow coupler), yellow filter '
                         'layer, green-sensitive layer (yellow-coloured magenta coupler), fourth colour-sensitive '
                         'layer (forms a light magenta image), intermediate layer, red-sensitive layer (red-coloured '
                         'cyan coupler), intermediate layer, anti-halation layer. Fujifilm cites an optimised '
                         'interimage ("重層効果") effect; no interimage data are published.')
    rec['notes'] = ['DISCONTINUED. Fetched from Fujifilm\'s own asset server (Fujifilm Japan datasheet index); '
                    'Japanese-language datasheet, labels translated here.',
                    'ISO 400/27° daylight; ISO 125/22° under 3200 K tungsten with Fuji LBB-12 (≈ Wratten 80A).',
                    'Reciprocity: no correction from 1/4000 s to 2 s; at 4 s give +1/2 stop. No filter correction '
                    'is needed from 1/4000 s to 4 s.',
                    'Base: cellulose triacetate, 135 122 µm, 120 98 µm. Process CN-16 family or C-41.']
    rec['derived'] = derived_block(rec['characteristicCurves'], rec['spectralSensitivity'])
    rec['extraction'] = {'method': 'vector', 'tool': 'research/film-data/extract.py',
                         'notes': 'All four p6 charts are vector paths; sampled from path geometry. Axes from grid '
                                  'lines (the numbers are outlines, not text).',
                         'confidence': 'high (characteristic, dye), medium (sensitivity: relative scale; MTF: '
                                       'uneven grid)', 'checks': []}
    return rec


def dash_key(c):
    d = (c['dashes'] or '').split(']')[0].strip(' [')
    return 'solid' if not d else ' '.join(f'{float(v):.1f}' for v in d.split())


@stock
def kodak_tri_x_400():
    slug, key = 'kodak-tri-x-400', 'f4017'
    bar = [-4.0, -3.0, -2.0, -1.0, 0.0, 1.0]
    sets = [  # (page, frame, format, developer, agitation, times low→high, legend dash styles low→high)
        (8, (81.4, 66.5, 265.8, 251.0), '135 (35 mm)', 'KODAK PROFESSIONAL D-76', 'large tank, agitation at 1-minute intervals, 20°C (68°F)', [6, 8, 10, 12]),
        (8, (81.4, 334.3, 265.8, 518.8), '120', 'KODAK PROFESSIONAL D-76', 'large tank, agitation at 1-minute intervals, 20°C (68°F)', [6, 8, 10, 12]),
        (7, (366.4, 69.5, 550.9, 254.0), '135 (35 mm)', 'KODAK PROFESSIONAL T-MAX Developer', 'small tank, agitation at 30-second intervals, 20°C (68°F)', [6, 7, 9, 11]),
        (7, (367.2, 333.7, 551.6, 518.2), '120', 'KODAK PROFESSIONAL T-MAX Developer', 'small tank, agitation at 30-second intervals, 20°C (68°F)', [6, 7, 9, 11]),
    ]
    legend = ['solid', '3.2 1.6', '6.5 3.2', '16.2 3.2 3.2 3.2 3.2 3.2']
    variants, checks = [], []
    for pno, F, fmt, dev, agit, times in sets:
        names = [f'{t} min' for t in times]
        tag = f"{'d76' if 'D-76' in dev else 'tmax'}-{fmt.split()[0]}"
        got = {}

        def assign(cs, xa, ya, names=names, got=got):
            named = by_order_at(cs, xa, ya, hi_x(cs, xa) - 0.02, names[::-1])
            for c in cs:
                for n, p in named.items():
                    if p is c['polys']:
                        got[n] = dash_key(c)
            return named
        r = vchart(key, pno, F, assign, 0.05, f'{slug}-characteristic-{tag}',
                   f'F-4017 p{pno} {fmt} {dev.split()[-1] if "T-MAX" not in dev else "T-MAX Dev"}',
                   xvalues=bar, min_width=60, order=names)
        ok = [got[n] for n in names] == legend
        checks.append(f'{fmt} {dev}: curve order by D-max matches legend dash styles: {ok}')
        for t, n in zip(times, names):
            variants.append({'format': fmt, 'developer': dev, 'agitation': agit, 'timeMin': t,
                             'logExposure': [x for x, y in zip(r['x'], r['ys'][n]) if y is not None],
                             'neutral': [y for y in r['ys'][n] if y is not None],
                             'gamma': round(gamma_fit(r['x'], r['ys'][n]), 3)})
    primary = next(v for v in variants if v['format'].startswith('135') and 'D-76' in v['developer'] and v['timeMin'] == 8)
    # spectral sensitivity: two density criteria
    se = vchart(key, 7, (86.9, 291.7, 287.4, 443.0),
                lambda cs, xa, ya: {('D=1.0' if dash_key(c) == 'solid' else 'D=0.3'): c['polys'] for c in cs},
                5, slug + '-sensitivity', 'F-4017 p7 spectral sensitivity', floor=True, max_width_frac=0.9)
    mt = vchart(key, 7, (84.8, 81.0, 287.3, 233.8), lambda cs, xa, ya: {'neutral': cs[0]['polys']}, 'mtf',
                slug + '-mtf', 'F-4017 p7 MTF', xlog=True, ylog=True, nd=1, max_width_frac=0.9,
                xlab=(80, 238, 294, 248), ylab=(60, 74, 84, 240))
    rec = base_record(slug, 'KODAK PROFESSIONAL TRI-X 400 Film / 400TX', 'Kodak Alaris (KODAK PROFESSIONAL)',
                      'bw-negative', 'Black-and-white developer (D-76, T-MAX, XTOL, HC-110 ... see variants)', 400,
                      key, [1, 3, 6, 7, 8])
    rec['characteristicCurves'] = {
        'densityType': 'diffuse visual', 'logExposureUnits': LOGH_UNITS,
        'condition': f"{primary['format']}, {primary['developer']} {primary['timeMin']} min, {primary['agitation']}",
        'logExposure': primary['logExposure'], 'neutral': primary['neutral'],
        'dMin': primary['neutral'][0],
        'variants': variants,
        'notes': 'Primary curve: 35 mm in D-76, large tank, 8 min at 20°C (the recommended large-tank D-76 time '
                 'is 7 3/4 min at 20°C). All published 400TX development series are in variants; each variant '
                 'carries its own logExposure grid. dMin = gross fog + base at the lowest plotted exposure. '
                 'Log-exposure labels are printed in bar notation (4̄.0 = -4.0).'}
    rec['spectralSensitivity'] = {
        'units': LOGS_UNITS, 'densityType': 'diffuse visual', 'exposure': 'effective exposure 0.5 s',
        'wavelength': se['x'], 'neutral': se['ys']['D=1.0'], 'neutralD03': se['ys']['D=0.3'],
        'densityCriterion': {'neutral': '1.0 above gross fog', 'neutralD03': '0.3 above gross fog'},
        'notes': 'Two curves as labelled in the legend (solid = D=1.0 > gross fog, dashed = D=0.3 > gross fog). '
                 'As published the D=1.0 curve lies ~1.2 log units ABOVE the D=0.3 curve, which is the opposite '
                 'of what reaching a lower density should require; the legend may be swapped. Stored as labelled. '
                 'Samples on the chart floor (log S = 0) are null.'}
    rec['dyeDensity'] = None
    rec['granularity'] = {'rmsDiffuse': 17, 'printGrainIndex': None,
                          'notes': 'Diffuse rms granularity 17 ("fine"), read at a net diffuse density of 1.0 with a '
                                   '48 µm aperture, 12x magnification; HC-110 (Dilution B), 20°C.'}
    rec['mtf'] = {'units': 'percent response', 'frequencyUnits': 'cycles/mm', 'process':
                  'KODAK PROFESSIONAL Developer D-76, large tank', 'densityType': 'diffuse visual',
                  'frequency': mt['x'], 'neutral': mt['ys']['neutral']}
    rec['interlayer'] = None
    rec['notes'] = ['Datasheet covers TRI-X 320 (320TXP) as well; only the TRI-X 400 (400TX) curves are extracted '
                    'here. Contrast-index-vs-time charts are not digitised.']
    rec['derived'] = derived_block(rec['characteristicCurves'], rec['spectralSensitivity'])
    rec['derived']['gammaByVariant'] = {f"{v['format']} {'D-76' if 'D-76' in v['developer'] else 'T-MAX'} {v['timeMin']} min": v['gamma']
                                        for v in variants}
    for v in variants:
        del v['gamma']
    rec['extraction'] = {'method': 'vector', 'tool': 'research/film-data/extract.py',
                         'notes': 'Vector paths; development-time curves identified by dash style (checked against '
                                  'the legend) and by their order at maximum exposure.',
                         'confidence': 'high', 'checks': checks}
    return rec


def kodak_bw_series(key, pno, F, fmt, dev, agit, times, slug, tag, xvalues, legend=True):
    """One Kodak B&W development-time chart: curves ordered by density where all are still drawn (longest
    time highest). legend: compare each curve's dash style with the legend samples (listed top→bottom from
    the longest time) and record the result."""
    names = [f'{t} min' for t in times]
    got, leg = {}, []

    def assign(cs, xa, ya):
        x = min(curve_range(c['polys'], xa)[1] for c in cs) - 0.02
        named = by_order_at(cs, xa, ya, x, names[::-1])
        for c in cs:
            for n, p in named.items():
                if p is c['polys']:
                    got[n] = dash_key(c)
        return named
    page = doc(key)[pno - 1]
    r = vchart(key, pno, F, assign, 0.05, f'{slug}-characteristic-{tag}',
               f'{SOURCES[key]["document"]} p{pno} {dev.replace("KODAK PROFESSIONAL ", "")}', xvalues=xvalues,
               min_width=60, order=names)
    if legend:
        leg = [dash_key(c) for c in sorted(vector_curves(page, F, min_pts=2), key=lambda c: c['rect'].y0)
               if 8 < c['rect'].width < 40 and c['rect'].height < 1.5]
    mine = [got[n] for n in names]
    ok = None if not leg else leg == mine[::-1]
    variants = []
    for t, n in zip(times, names):
        variants.append({'format': fmt, 'developer': dev, 'agitation': agit, 'timeMin': t,
                         'logExposure': [x for x, y in zip(r['x'], r['ys'][n]) if y is not None],
                         'neutral': [y for y in r['ys'][n] if y is not None],
                         'gamma': round(gamma_fit(r['x'], r['ys'][n]), 3)})
    chk = (f'{dev} ({agit}): curve dash styles by time {mine}; legend {leg}; match {ok}' if legend else
           f'{dev} ({agit}): curves labelled by text beside each curve; ordered by density')
    return variants, chk


def kodak_bw_record(slug, name, key, pages, ei, variants, checks, primary, se, mt, grain, resolving, notes,
                    sens_exposure, mtf_exposure):
    rec = base_record(slug, name, 'Kodak Alaris (KODAK PROFESSIONAL)', 'bw-negative',
                      'Black-and-white developer (D-76, T-MAX, T-MAX RS, XTOL, HC-110 ... see variants)', ei, key, pages)
    p = next(v for v in variants if v['developer'] == primary[0] and v['timeMin'] == primary[1])
    rec['characteristicCurves'] = {
        'densityType': 'diffuse visual', 'logExposureUnits': LOGH_UNITS, 'exposure': 'Daylight',
        'condition': f"{p['developer']} {p['timeMin']} min, {p['agitation']}",
        'logExposure': p['logExposure'], 'neutral': p['neutral'], 'dMin': p['neutral'][0], 'variants': variants,
        'notes': 'All published development series are in variants (each with its own logExposure grid); the '
                 'primary curve is the one nearest the recommended time in D-76. dMin = gross fog + base at the '
                 'lowest plotted exposure. Log-exposure labels in bar notation (3̄.0 = -3.0) where printed so.'}
    rec['spectralSensitivity'] = {
        'units': LOGS_UNITS, 'densityType': 'diffuse visual', 'exposure': sens_exposure,
        'process': 'KODAK PROFESSIONAL Developer D-76, 20°C', 'wavelength': se['x'],
        'neutral': se['ys']['D=1.0'], 'neutralD03': se['ys']['D=0.3'],
        'densityCriterion': {'neutral': '1.0 above D-min', 'neutralD03': '0.3 above D-min'},
        'notes': 'Two curves as labelled on the chart; the D=0.3 curve lies above the D=1.0 curve (less exposure '
                 'is needed for the lower density), as expected. Curves end where the published curves end.'}
    rec['dyeDensity'] = None
    rec['granularity'] = grain
    rec['resolvingPower'] = {'linesPerMm': resolving, 'notes': 'Test-object contrast (TOC) ratios; method similar '
                                                                'to ISO 6328; D-76, 20°C.'}
    rec['mtf'] = {'units': 'percent response', 'frequencyUnits': 'cycles/mm', 'exposure': mtf_exposure,
                  'process': 'KODAK PROFESSIONAL Developer D-76, small tank, 20°C', 'densityType': 'diffuse visual',
                  'frequency': mt['x'], 'neutral': mt['ys']['neutral']}
    rec['interlayer'] = None
    rec['notes'] = list(notes)
    rec['derived'] = derived_block(rec['characteristicCurves'], rec['spectralSensitivity'])
    rec['derived']['gammaByVariant'] = {f"{v['developer'].replace('KODAK PROFESSIONAL ', '')} {v['timeMin']} min":
                                        v['gamma'] for v in variants}
    for v in variants:
        del v['gamma']
    rec['extraction'] = {'method': 'vector', 'tool': 'research/film-data/extract.py',
                         'notes': 'Vector paths; development-time curves identified by their order in density '
                                  'where all are drawn (longest time densest), checked against the legend dash '
                                  'styles or the time labels printed beside the curves.',
                         'confidence': 'high', 'checks': checks}
    return rec


def bw_sens(key, pno, F, slug, title, yvalues=None):
    return vchart(key, pno, F, lambda cs, xa, ya: by_order_at(cs, xa, ya, 500, ['D=0.3', 'D=1.0']), 5,
                  slug + '-sensitivity', title, floor=True, max_width_frac=0.9, yvalues=yvalues)


@stock
def kodak_t_max_100():
    slug, key = 'kodak-t-max-100', 'f4016'
    bar = [-4.0, -3.0, -2.0, -1.0, 0.0, 1.0]
    variants, checks = [], []
    for F, dev, agit, times, tag in (
            ((355.6, 57.0, 540.0, 241.5), 'KODAK PROFESSIONAL Developer D-76', 'small tank, 20°C (68°F)',
             [6, 7.5, 10], 'd76'),
            ((354.2, 289.7, 538.6, 474.2), 'KODAK PROFESSIONAL T-MAX RS Developer and Replenisher',
             'large tank, 20°C (68°F)', [8, 10.5, 13, 15], 'tmaxrs'),
            ((355.8, 519.8, 540.3, 704.3), 'KODAK PROFESSIONAL T-MAX Developer', 'small tank, 20°C (68°F)',
             [6, 7, 10, 12], 'tmax')):
        v, c = kodak_bw_series(key, 8, F, '135 / 120 / sheet (not stated)', dev, agit, times, slug, tag, bar)
        variants += v
        checks.append(c)
    # log-sensitivity labels in bar notation: 2.0, 1.0, 0.0, 1̄.0, 2̄.0 (top to bottom)
    se = bw_sens(key, 8, (74.6, 498.5, 275.1, 650.0), slug, 'F-4016 p8 spectral sensitivity',
                 yvalues=[2.0, 1.0, 0.0, -1.0, -2.0])
    mt = vchart(key, 8, (71.2, 260.1, 273.7, 413.1), lambda cs, xa, ya: {'neutral': cs[0]['polys']}, 'mtf',
                slug + '-mtf', 'F-4016 p8 MTF', xlog=True, ylog=True, nd=1, max_width_frac=0.9)
    return kodak_bw_record(
        slug, 'KODAK PROFESSIONAL T-MAX 100 Film / TMX', key, [1, 2, 3, 5, 8], 100, variants, checks,
        ('KODAK PROFESSIONAL Developer D-76', 7.5), se, mt,
        {'rmsDiffuse': 8, 'printGrainIndex': None,
         'notes': 'Diffuse rms granularity 8, read at a net diffuse density of 1.00 with a 48 µm aperture, 12x '
                  'magnification; D-76, 20°C.'},
        {'1.6:1': 63, '1000:1': 200},
        ['EI 100 (ISO 100/21° in most developers).',
         'Push (T-MAX or T-MAX RS developer): EI 200 = normal processing (1-stop under is within latitude), EI 400 '
         '= 2-stop push, EI 800 = 3-stop push. Small-tank times at 20°C: T-MAX 7½ min (EI 200) / 12¼ min (EI 400); '
         'XTOL 7½ / 9½; D-76 6½ / 8¼; HC-110 (B) 6 / 11½. EI 800: T-MAX 11¾ min at 24°C (D-76 and HC-110 not '
         'recommended). Pushing raises contrast and graininess and loses shadow detail.',
         'Reciprocity: +1/3 stop at 1/10,000 s; none 1/1,000-1/10 s; +1/3 stop at 1 s; +1/2 stop (or 15 s) at 10 s; '
         '+1 stop (or 200 s) at 100 s.',
         'Contrast-index-vs-time charts (p9) and development tables (p3-6) are not digitised; the characteristic '
         'variants cover D-76 (small tank), T-MAX RS (large tank) and T-MAX Developer (small tank).',
         'Chart 3 (T-MAX Developer): the 10 and 12 min curves leave the top of the chart (D 3.0) before log H 0.3; '
         'they end there.'], 'effective exposure 1.4 s', 'Tungsten')


@stock
def kodak_t_max_400():
    slug, key = 'kodak-t-max-400', 'f4043'
    variants, checks = [], []
    for F, dev, agit, times, tag in (
            ((83.9, 56.5, 268.3, 241.0), 'KODAK PROFESSIONAL Developer D-76', 'small tank, 20°C (68°F)',
             [6, 8, 11], 'd76'),
            ((356.7, 55.8, 541.2, 240.3), 'KODAK PROFESSIONAL T-MAX Developer', 'small tank, 24°C (75°F)',
             [5, 7, 9], 'tmax'),
            ((83.2, 308.4, 267.7, 493.0), 'KODAK PROFESSIONAL T-MAX RS Developer and Replenisher',
             'large tank, 24°C (75°F)', [5, 7, 9], 'tmaxrs')):
        v, c = kodak_bw_series(key, 8, F, '135 / 120 / sheet (not stated)', dev, agit, times, slug, tag,
                               [-4.0, -3.0, -2.0, -1.0, 0.0, 1.0], legend=False)
        variants += v
        checks.append(c)
    se = bw_sens(key, 7, (361.6, 469.9, 562.1, 621.7), slug, 'F-4043 p7 spectral sensitivity')
    mt = vchart(key, 7, (360.9, 248.6, 563.4, 401.6), lambda cs, xa, ya: {'neutral': cs[0]['polys']}, 'mtf',
                slug + '-mtf', 'F-4043 p7 MTF', xlog=True, ylog=True, nd=1, max_width_frac=0.9)
    return kodak_bw_record(
        slug, 'KODAK PROFESSIONAL T-MAX 400 Film / TMY-2', key, [1, 2, 3, 7, 8], 400, variants, checks,
        ('KODAK PROFESSIONAL Developer D-76', 8), se, mt,
        {'rmsDiffuse': 10, 'printGrainIndex': None,
         'notes': 'Diffuse rms granularity 10, read at a net diffuse density of 1.00 with a 48 µm aperture, 12x '
                  'magnification; D-76, 20°C.'},
        {'1.6:1': 50, '1000:1': 200},
        ['EI 400 (ISO 400/27°) in T-MAX, T-MAX RS, XTOL, XTOL 1:1, D-76 and D-76 1:1; EI 320 in HC-110 (B).',
         'Latitude: EI 800 with normal development still gives high quality (slight loss of shadow detail, about '
         '½ paper grade less printing contrast). Push (T-MAX, T-MAX RS or XTOL): EI 1600 = 2-stop push, EI 3200 '
         '= 3-stop push. Small-tank EI 1600 times at 20°C: T-MAX 8½ min, T-MAX RS 8½, XTOL 8½, XTOL 1:1 12¼, '
         'D-76 9¼, HC-110 (B) 7½; EI 3200 at 24°C: T-MAX 8¼, T-MAX RS 7¼, XTOL 7¼, XTOL 1:1 10 (D-76 and HC-110 '
         'not recommended).',
         'Reciprocity: no correction 1/10,000 s to 1 s; +1/3 stop at 10 s; +1½ stops (or 300 s) at 100 s.',
         'Characteristic variants: D-76 small tank 20°C (6/8/11 min), T-MAX Developer small tank 24°C (5/7/9 min), '
         'T-MAX RS large tank 24°C (5/7/9 min). The time of each curve is printed beside it. Contrast-index '
         'charts are not digitised.'], 'Daylight (effective exposure not stated)', 'Tungsten')


def stencil_trace(key, pno, xref, seed, lo, hi, exclude=(), max_gap=60, max_jump=3.0, remove_grid=None):
    """Trace one curve drawn as its own 1-bit stencil image → [(page_x, page_y)]."""
    r = Raster.image(key, pno, xref)
    m = r.mask(lambda a, b, c: a < 128, exclude=exclude)
    if remove_grid:
        r.remove_lines(m, rows=remove_grid[0], cols=remove_grid[1], halfwidth=remove_grid[2])
    return track(r, m, {'c': seed}, lo, hi, max_gap=max_gap, max_jump=max_jump)['c']


def mtf_by_runs(key, pno, xref, xa, ya, regions, slug, title, exclude=(), pred=None, nd=1, vrange=(5, 130)):
    """MTF curves read column by column where the curves cross too tightly for a tracker: at each standard
    frequency the ink runs between grid lines are listed top→bottom and named by the region's order
    (regions: [(f_lo, f_hi, [name or (names merged in one line), ...])]). A column whose run count does not
    match the region's order (curves touching at a crossing) is left null. Grid-line rows are removed from
    each run; a run that is only grid line plus curve keeps its full centre. Columns within 1 pt of a
    vertical grid line are read 1.5 pt to the side."""
    r = Raster.image(key, pno, xref)
    m = r.mask(pred or DARK, exclude=exclude)
    hl, vl = r.lines(m, 'h', 0.3), r.lines(m, 'v', 0.3)
    names = sorted({n for *_, order in regions for e in order for n in (e if isinstance(e, tuple) else (e,))})
    xs = mtf_grid(regions[0][0], regions[-1][1])
    ys = {n: [] for n in names}
    for f in xs:
        order = next((o for a, b, o in regions if a <= f <= b), None)
        x = xa.pos(f)
        near = [v for v in vl if abs(v - x) < 1.0]
        if near:
            x = near[0] + (1.5 if x >= near[0] else -1.5)
        px = int(round(r.to_px(x, 0)[0]))
        grid_rows = {yy for h in hl for yy in range(int(r.to_px(0, h - 0.6)[1]), int(r.to_px(0, h + 0.6)[1]) + 1)}
        runs, cur = [], []
        for yy in range(int(r.to_px(0, min(hl) + 0.8)[1]), int(r.to_px(0, max(hl) - 0.8)[1])):
            if m[yy][px]:
                cur.append(yy)
            elif cur:
                runs.append(cur)
                cur = []
        if cur:
            runs.append(cur)
        def centre(run):
            # a curve lying on a grid line shows as a run clearly thicker than the bare line
            k = [yy for yy in run if yy not in grid_rows]
            if len(run) > 8 * r.sy:
                return None
            if len(k) >= 2:
                return sum(k) / len(k)
            if len(k) < len(run) and len(run) >= 4:
                return sum(run) / len(run)
            return None
        runs = [r.to_page(0, c)[1] for c in map(centre, runs) if c is not None]
        runs = [p for p in runs if vrange[0] <= ya.val(p) <= vrange[1]]
        vals = {}
        if order and len(runs) == len(order):
            for p, e in zip(runs, order):
                for n in (e if isinstance(e, tuple) else (e,)):
                    vals[n] = round(ya.val(p), nd)
        for n in names:
            ys[n].append(vals.get(n))
    overlay(key, pno, r.rect, xa, ya, [(k, xs, v) for k, v in ys.items()], slug, title)
    return dict(x=xs, ys=ys, axes=(xa, ya), pts={})


def curves_by_columns(key, pno, xref, xa, ya, regions, xs, slug, title, exclude=(), pred=None, nd=3,
                      max_run_pt=30.0, gap_pt=2.5, frame=None):
    """Curves read from every image column between the grid lines, for bitmaps whose curves and grid share
    one colour. Each column's ink runs (grid rows removed) are named top→bottom by the first order in the
    region (regions: [(x_lo, x_hi, [order, ...])], names starting with '_' are read but discarded) whose
    length matches; other columns stay unnamed. Steep segments give long runs whose centre is used. A sample
    on a vertical grid line is linearly interpolated between the nearest named columns on both sides, if
    both lie within gap_pt of it; otherwise it is null. frame: plot frame (page coords) bounding the grid.
    Returns dict(x, ys, axes, interpolated={name: [x]})."""
    r = Raster.image(key, pno, xref)
    m = r.mask(pred or DARK, exclude=exclude)
    hl, vl = r.lines(m, 'h', 0.3), r.lines(m, 'v', 0.3)
    if frame:
        hl = [h for h in hl if frame[1] - 1 <= h <= frame[3] + 1]
        vl = [v for v in vl if frame[0] - 1 <= v <= frame[2] + 1]
    grid_rows = {yy for h in hl for yy in range(int(r.to_px(0, h - 0.6)[1]), int(r.to_px(0, h + 0.6)[1]) + 1)}
    grid_cols = {xx for v in vl for xx in range(int(r.to_px(v - 0.75, 0)[0]), int(r.to_px(v + 0.75, 0)[0]) + 1)}
    fx0, fy0, fx1, fy1 = frame or (min(vl), min(hl), max(vl), max(hl))
    y_lo, y_hi = int(r.to_px(0, fy0 + 0.8)[1]), int(r.to_px(0, fy1 - 0.8)[1])
    px_lo, px_hi = int(r.to_px(fx0 + 1.2, 0)[0]), int(r.to_px(fx1 - 1.2, 0)[0])
    names = sorted({n for *_, orders in regions for o in orders for n in o if not n.startswith('_')})
    cols = {n: {} for n in names}
    for px in range(px_lo, px_hi + 1):
        if px in grid_cols:
            continue
        xv = xa.val(r.to_page(px + 0.5, 0)[0])
        orders = next((o for a, b, o in regions if a <= xv < b), None)
        if not orders:
            continue
        runs, cur = [], []
        for yy in range(y_lo, y_hi + 1):
            if m[yy][px]:
                cur.append(yy)
            elif cur:
                runs.append(cur)
                cur = []
        if cur:
            runs.append(cur)
        cen = []
        for run in runs:
            k = [yy for yy in run if yy not in grid_rows]
            if len(run) > max_run_pt * r.sy:
                continue
            if len(k) >= 2:
                cen.append(sum(k) / len(k))
            elif len(k) < len(run) and len(run) >= 4:
                cen.append(sum(run) / len(run))
        order = next((o for o in orders if len(o) == len(cen)), None)
        if order:
            for n, c in zip(order, cen):
                if not n.startswith('_'):
                    cols[n][px] = r.to_page(0, c + 0.5)[1]
    ys = {n: [] for n in names}
    interp = {n: [] for n in names}
    gap = gap_pt * r.sx
    for x in xs:
        px = int(r.to_px(xa.pos(x), 0)[0])
        for n in names:
            c = cols[n]
            if px in c:
                ys[n].append(round(ya.val(c[px]), nd))
                continue
            v = None
            if px in grid_cols:
                left = [p for p in c if px - gap <= p < px]
                right = [p for p in c if px < p <= px + gap]
                if left and right:
                    a, b = max(left), min(right)
                    v = round(ya.val(c[a] + (c[b] - c[a]) * (px - a) / (b - a)), nd)
                    interp[n].append(x)
            ys[n].append(v)
    overlay(key, pno, r.rect, xa, ya, [(k, xs, v) for k, v in ys.items()], slug, title)
    return dict(x=xs, ys=ys, axes=(xa, ya), interpolated=interp)


def raster_overlay(key, pno, rect, xa, ya, series, xs, name, title):
    overlay(key, pno, rect, xa, ya, [(k, xs, v) for k, v in series.items()], name, title)


@stock
def fuji_provia_100f():
    slug, key, pno = 'fuji-provia-100f', 'af3-036e', 6
    # --- characteristic curves: base grid stencil 50, one stencil per curve (51 green, 52 red, 53 blue)
    base = Raster.image(key, pno, 50)
    bm = base.mask(lambda a, b, c: a < 128)
    xa = uniform_axis(base.lines(bm, 'v', 0.6), -3.5, 1.0, 0.5, name='logH')
    ya = uniform_axis(base.lines(bm, 'h', 0.3)[:9], 4.0, 0.0, 0.5, name='D')
    legend = [(83, 300, 125, 332)]
    col = stencil_colours(key, pno, [51, 52, 53])
    names = {x: max(zip(c, ('red', 'green', 'blue')))[1] for x, c in col.items()}
    pts = {names[x]: stencil_trace(key, pno, x, (xa.pos(-3.0), ya.pos(3.35)), xa.pos(-3.5), xa.pos(1.0),
                                   exclude=legend) for x in (51, 52, 53)}
    xs = grid_between(pts, xa, 0.05)
    ch = raster_series(pts, xa, ya, xs)
    rect = base.rect
    raster_overlay(key, pno, rect, xa, ya, ch, xs, slug + '-characteristic', 'AF3-036E p6 characteristic curves')
    # --- spectral dye density: base 55, 56 yellow, 57 magenta, 58 cyan
    base = Raster.image(key, pno, 55)
    bm = base.mask(lambda a, b, c: a < 128)
    v = base.lines(bm, 'v', 0.6)[1:5]
    h = base.lines(bm, 'h', 0.6)[1:4]
    wa = axis_from_lines(v, [400, 500, 600, 700], name='nm')
    da = axis_from_lines(h, [1.0, 0.5, 0.0], name='D')
    col = stencil_colours(key, pno, [56, 57, 58])
    hue = {x: ('yellow' if c[2] < 100 else 'magenta' if c[1] < 100 else 'cyan') for x, c in col.items()}
    seeds = {'yellow': (445, 1.0), 'magenta': (545, 1.0), 'cyan': (650, 1.0)}
    pts = {}
    for x in (56, 57, 58):
        n = hue[x]
        pts[n] = stencil_trace(key, pno, x, (wa.pos(seeds[n][0]), da.pos(seeds[n][1])), base.rect.x0 + 1,
                               base.rect.x1 - 1)
    wl = grid_between(pts, wa, 5)
    dy = raster_series(pts, wa, da, wl)
    raster_overlay(key, pno, base.rect, wa, da, dy, wl, slug + '-dye-density', 'AF3-036E p6 spectral dye density')
    # --- MTF: single stencil 54 containing grid + curve
    r = Raster.image(key, pno, 54)
    m = r.mask(lambda a, b, c: a < 128)
    hl, vl = r.lines(m, 'h', 0.5), r.lines(m, 'v', 0.5)
    fa = axis_from_lines(vl, [1, 5, 10, 20, 50, 100, 200], log=True, name='c/mm')
    ra = axis_from_lines(hl[1:], [100, 70, 50, 30, 20, 10, 7, 5, 2], log=True, name='%')
    r.remove_lines(m, rows=hl, cols=vl, halfwidth=2)
    mp = track(r, m, {'neutral': (fa.pos(3), ra.pos(110))}, fa.pos(1.02), fa.pos(190), max_gap=30,
               max_jump=2.5)
    fr = mtf_grid(fa.val(mp['neutral'][0][0]), fa.val(mp['neutral'][-1][0]))
    mt = raster_series(mp, fa, ra, fr, nd=1)
    raster_overlay(key, pno, r.rect, fa, ra, mt, fr, slug + '-mtf', 'AF3-036E p6 MTF')
    # --- spectral sensitivity: vector
    se = vchart(key, pno, (338.2, 172.0, 538.3, 348.9), lambda cs, xa_, ya_: by_peak(cs, xa_, ya_, BANDS_RGB),
                5, slug + '-sensitivity', 'AF3-036E p6 spectral sensitivity', max_width_frac=0.9)
    return reversal_record(slug, 'FUJICHROME PROVIA 100F Professional [RDP III]', 100, key, [1, 5, 6], xs, ch, se,
                           wl, dy, fr, mt, dict(
        extraction_note='Characteristic, dye-density and MTF charts are 1-bit stencil bitmaps: each curve is its '
                        'own stencil (identified by its paint colour on the rendered page) and was traced '
                        'column by column; axes from the stencil grid lines. The sensitivity chart is vector.',
        char_exposure='Daylight, 1/50 s', process='E-6 / CR-56', densitometry='Fuji FAD-30S (Status A)',
        sens_criterion='1.0 above D-min (Fuji FAD-30S, Status A)',
        grain={'rmsDiffuse': 8, 'printGrainIndex': None, 'notes': 'Fujifilm diffuse rms granularity (x1000), 48 µm '
               'aperture, at density 1.0 above minimum density.'},
        resolving={'1.6:1': 60, '1000:1': 140},
        char_note='Curves traced from three overlaid 1-bit stencil images (one per colour), so overlapping curves '
                  'are separated exactly. The green and blue curves are DRAWN ONLY through the shoulder (green to '
                  'D≈1.9 at log H≈-1.5, blue to D≈3.0 at log H≈-2.2); below that the chart shows only the red line, '
                  'i.e. the three coincide within the line width. Those green/blue samples are null (not published '
                  'separately); substituting red there is the natural reading of the chart but is an inference.',
        notes=['ISO 100/21° daylight; ISO 32/16° under 3200 K tungsten with Wratten 80A (or LBB-12).',
               'Derived gamma is computed only for curves spanning most of the density range (red); green and blue '
               'are partial as published.'],
        dye_note='Exposure: separated light, process E-6/CR-56. Each dye curve is normalised to a peak of 1.0 '
                 '(as drawn). Curves traced from separate stencil images; the wavelength grid lines are drawn '
                 'unevenly by ~1 pt (~2 nm), absorbed by the least-squares axis fit.'))


def reversal_record(slug, name, ei, key, pages, xs, ch, se, wl, dy, fr, mt, meta):
    rec = base_record(slug, name, 'FUJIFILM Corporation', 'reversal', meta['process'], ei, key, pages)
    rgb = ('red', 'green', 'blue')
    idx = {c: [i for i, v in enumerate(ch[c]) if v is not None] for c in rgb}
    first, last = min(i[0] for i in idx.values()), max(i[-1] for i in idx.values())
    rec['characteristicCurves'] = {
        'densityType': 'status-A (' + meta['densitometry'] + ')', 'exposure': meta['char_exposure'],
        'process': meta['process'], 'logExposureUnits': LOGH_UNITS, 'logExposure': xs, **ch,
        'dMax': {c: ch[c][idx[c][0]] if idx[c][0] <= first + 2 else None for c in rgb},
        'dMin': {c: ch[c][idx[c][-1]] if idx[c][-1] >= last - 2 else None for c in rgb},
        'notes': 'Reversal: density falls with exposure. dMax = density at the lowest plotted exposure, dMin = at '
                 'the highest; null for a curve that is not drawn to that end of the exposure range. ' +
                 meta['char_note']}
    rec['spectralSensitivity'] = {
        'units': LOGS_UNITS.replace('erg/cm^2', 'J/cm^2'), 'densityCriterion': meta['sens_criterion'],
        'process': meta['process'], 'wavelength': se['x'], **se['ys'],
        'notes': 'The datasheet footnote defines sensitivity with the exposure in J/cm^2 (Kodak sheets use erg/cm^2; '
                 'the difference is a constant 7.0 in log S). Curves end where the published curves end.'}
    rec['dyeDensity'] = {'units': 'spectral diffuse density (peak-normalised)', 'wavelength': wl,
                         'cyan': dy['cyan'], 'magenta': dy['magenta'], 'yellow': dy['yellow'], 'minimum': None,
                         'midscaleNeutral': None, 'notes': meta['dye_note']}
    rec['granularity'] = meta['grain']
    rec['resolvingPower'] = {'linesPerMm': meta['resolving'], 'notes': 'Chart (test-object) contrast ratios.'}
    rec['mtf'] = {'units': 'percent response', 'frequencyUnits': 'cycles/mm', 'exposure': 'Daylight',
                  'process': meta['process'], 'frequency': fr, 'neutral': mt['neutral'],
                  'notes': 'A single curve is published; the layer/colour it refers to is not stated.'}
    rec['interlayer'] = None
    rec['notes'] = list(meta.get('notes', []))
    rec['derived'] = derived_block(rec['characteristicCurves'], rec['spectralSensitivity'], rec['dyeDensity'],
                                   reversal=True)
    rec['derived']['gammaNote'] = 'Reversal: gamma is the magnitude of the (negative) slope.'
    rec['extraction'] = {'method': meta.get('method', 'mixed: raster (characteristic, dye, MTF) + vector '
                                                      '(sensitivity)'),
                         'tool': 'research/film-data/extract.py', 'notes': meta.get('extraction_note', ''),
                         'confidence': meta.get('confidence', 'high'), 'checks': []}
    return rec


def raster_chart(key, pno, xref, xaxis, yaxis, seeds, step, slug, title, exclude=(), lo=None, hi=None,
                 max_jump=1.2, max_gap=30, grid_halfwidth=4, thresh=128, half=3, nd=3, xs=None, dpi=None,
                 rect=None, pred=None, grid=True, line_frac=0.35, slope_n=12, tracker='dp', track_kw=None,
                 clip_frame=True, drop_lines=(), transpose=False):
    """Trace several black curves in one bitmap chart.
    xaxis/yaxis: (orient, found-line filter fn, values-or-(v_first, v_last, step), log) or an Axis.
    seeds: {name: (x_data, y_data)}; lo/hi: data-x limits (scalar or per-name dict).
    drop_lines: [('h'|'v', data value)] detected "grid lines" that are really long flat curve segments."""
    if xref is not None:
        r = Raster.image(key, pno, xref)
    else:
        r = Raster(doc(key)[pno - 1], rect, dpi)
    m = r.mask(pred or (lambda a, b, c: a < thresh), exclude=exclude)
    hl, vl = r.lines(m, 'h', line_frac), r.lines(m, 'v', line_frac)

    def mk(spec, found):
        if isinstance(spec, Axis):
            return spec
        _, sel, vals, log = spec
        f = sel(found)
        if isinstance(vals, tuple):
            return uniform_axis(f, *vals, log=log)
        return axis_from_lines(f, vals, log=log)
    xa, ya = mk(xaxis, vl), mk(yaxis, hl)
    frame_h, frame_v = list(hl), list(vl)
    for o, v in drop_lines:
        ax, ls = (ya, hl) if o == 'h' else (xa, vl)
        ls[:] = [p for p in ls if abs(p - ax.pos(v)) > 1.0]
    if clip_frame and hl and vl:
        # blank everything outside the outermost grid/frame lines (axis labels, titles)
        y0, y1 = r.to_px(0, min(frame_h) - 1.0)[1], r.to_px(0, max(frame_h) + 1.0)[1]
        x0, x1 = r.to_px(min(frame_v) - 1.0, 0)[0], r.to_px(max(frame_v) + 1.0, 0)[0]
        for yy in range(r.h):
            if yy < y0 or yy > y1:
                m[yy][:] = bytearray(r.w)
            else:
                for xx in list(range(0, max(0, int(x0)))) + list(range(min(r.w, int(x1) + 1), r.w)):
                    m[yy][xx] = 0
    gkw = {}
    if grid and tracker == 'dp':
        gkw = dict(grid_h=[r.to_px(0, y)[1] for y in hl], grid_v=[r.to_px(x, 0)[0] for x in vl],
                   grid_hw=grid_halfwidth)
    elif grid:
        r.remove_lines(m, rows=hl, cols=vl, halfwidth=grid_halfwidth)
    tr = dp_track if tracker == 'dp' else track
    if transpose:
        # follow steep curves row by row: lo/hi are then data-y limits
        lim = lambda v, n: ya.pos(v[n] if isinstance(v, dict) else v)
        lo_ = {n: min(lim(lo, n), lim(hi, n)) for n in seeds}
        hi_ = {n: max(lim(lo, n), lim(hi, n)) for n in seeds}
        if gkw:
            gkw = dict(grid_h=gkw['grid_v'], grid_v=gkw['grid_h'], grid_hw=gkw['grid_hw'])
        tp = tr(Transposed(r), m, {n: (ya.pos(y), xa.pos(x)) for n, (x, y) in seeds.items()}, lo_, hi_,
                max_jump=max_jump, max_gap=max_gap, slope_n=slope_n, **gkw, **(track_kw or {}))
        pts = {n: sorted((b, a) for a, b in p) for n, p in tp.items()}
    else:
        lo_ = {n: xa.pos(lo[n] if isinstance(lo, dict) else lo) for n in seeds} if lo is not None else r.rect.x0
        hi_ = {n: xa.pos(hi[n] if isinstance(hi, dict) else hi) for n in seeds} if hi is not None else r.rect.x1
        pts = tr(r, m, {n: (xa.pos(x), ya.pos(y)) for n, (x, y) in seeds.items()}, lo_, hi_,
                 max_jump=max_jump, max_gap=max_gap, slope_n=slope_n, **gkw, **(track_kw or {}))
    if xs is None:
        xs = grid_between(pts, xa, step) if step != 'mtf' else None
    if step == 'mtf':
        xs = mtf_grid(min(xa.val(p[0][0]) for p in pts.values()), max(xa.val(p[-1][0]) for p in pts.values()))
    ys = raster_series(pts, xa, ya, xs, half=half, nd=nd)
    # seeds named 'curve+piece' are extra pieces of 'curve' (traced separately where a single trace
    # cannot pass a crossing or a peak on a grid line); pieces fill the gaps, one-sample seams are bridged
    for n in [n for n in ys if '+' in n]:
        a = n.split('+')[0]
        v = [u if u is not None else w for u, w in zip(ys[a], ys.pop(n))]
        for i in range(1, len(v) - 1):
            if v[i] is None and v[i - 1] is not None and v[i + 1] is not None:
                v[i] = round((v[i - 1] + v[i + 1]) / 2, nd)
        ys[a] = v
    overlay(key, pno, r.rect, xa, ya, [(k, xs, v) for k, v in ys.items()], slug, title)
    return dict(x=xs, ys=ys, axes=(xa, ya), pts=pts)


@stock
def fuji_velvia_50():
    slug, key, pno = 'fuji-velvia-50', 'af3-0221e2', 8
    doc_ = SOURCES[key]['document']
    ident = lambda f: f
    ch = raster_chart(key, pno, 68, ('v', ident, (-3.0, 1.5, 0.5), False), ('h', ident, (4.0, 0.0, 0.5), False),
                      {'red': (-2.6, 3.33), 'green': (-2.6, 3.78), 'blue': (-2.6, 3.69)}, 0.05,
                      slug + '-characteristic', f'{doc_} p8 characteristic curves',
                      exclude=[(170, 111, 284, 143), (87, 240, 120, 266)], lo=-2.85, hi=1.15)
    se = raster_chart(key, pno, 69, ('v', lambda f: [p for p in f if 340 < p < 525], [400, 500, 600, 700], False),
                      ('h', ident, [2.0, 1.0, 0.0, -1.0], False),
                      {'blue': (430, 0.52), 'green': (548, 0.55), 'red': (650, 0.55)}, 5,
                      slug + '-sensitivity', f'{doc_} p8 spectral sensitivity',
                      exclude=[(425, 112, 530, 144), (355, 229, 390, 254), (419, 229, 452, 254), (471, 229, 505, 256)],
                      lo={'blue': 385, 'green': 483, 'red': 575}, hi={'blue': 495, 'green': 588, 'red': 695},
                      track_kw={'max_dtheta': 1.0})
    dy = raster_chart(key, pno, 67, ('v', lambda f: [p for p in f if 340 < p < 525], [400, 500, 600, 700], False),
                      ('h', lambda f: f[1:], [1.0, 0.5, 0.0], False),
                      {'yellow': (425, 0.852), 'magenta': (520, 0.855), 'cyan': (620, 0.812)}, 5,
                      slug + '-dye-density', f'{doc_} p8 spectral dye density',
                      exclude=[(433, 408, 530, 432), (362, 462, 389, 476), (415, 462, 446, 476), (490, 462, 509, 476)],
                      lo={'yellow': 396, 'magenta': 383, 'cyan': 414}, hi={'yellow': 597, 'magenta': 719, 'cyan': 719},
                      track_kw={'gap_pt': 9.0})
    mt = raster_chart(key, pno, 66, ('v', ident, [1, 5, 10, 20, 50, 100, 200], True),
                      ('h', lambda f: [f[i] for i in (1, 2, 3, 5, 6, 7, 8, 9, 10)], [100, 70, 50, 20, 10, 7, 5, 3, 2], True),
                      {'neutral': (7, 118)}, 'mtf', slug + '-mtf', f'{doc_} p8 MTF', nd=1, lo=1.0, hi=66,
                      track_kw={'max_dtheta': 0.25})
    return reversal_record(slug, 'FUJICHROME Velvia 50 Professional [RVP 50]', 50, key, [1, 7, 8],
                           ch['x'], ch['ys'], se, dy['x'], dy['ys'], mt['x'], mt['ys'], dict(
        method='raster', char_exposure='Daylight', process='E-6 / CR-56 (or Fuji Hunt PR06)',
        densitometry='Status A', sens_criterion='1.0 above D-min (Status A)',
        grain={'rmsDiffuse': 9, 'printGrainIndex': None, 'notes': 'Fujifilm diffuse rms granularity (x1000), 48 µm '
               'aperture, at density 1.0 above minimum density.'},
        resolving={'1.6:1': 80, '1000:1': 160},
        char_note='All four charts are 1-bit scanned bitmaps (~8 px/pt) with black curves (R solid, G dash-dot, '
                  'B dashed). Curves were traced column by column with slope prediction after removing grid lines. '
                  'Between log H ≈ -1.6 and +0.3 the three curves overlap within the line width and the traced '
                  'values there are effectively a shared centreline (±0.03 D).',
        dye_note='Exposure: separated; process E-6/CR-56. Each dye curve is normalised to a peak of 1.0 (as drawn). '
                 'The curves are published from ~381 nm; the short-wavelength tails where they cross near the '
                 'chart frame could not be traced reliably and are omitted: yellow starts at 396 nm and cyan at '
                 '414 nm (magenta from 383 nm).',
        extraction_note='Raster tracing of 1-bit bitmaps; grid lines used for calibration (uneven by up to ~1 pt '
                        'in the scan, absorbed by least-squares fits).',
        confidence='medium',
        notes=['ISO 50/18° daylight; ISO 16/13° under 3200 K tungsten with Wratten 80A.',
               'The exposure time for the characteristic curves is not stated on the chart (only "Daylight").']))


@stock
def fuji_velvia_100():
    slug, key, pno = 'fuji-velvia-100', 'rvp100', 6
    doc_ = SOURCES[key]['document']
    ink = lambda a, b, c: a < 50   # black ink on a mid-grey (127) image background
    ident = lambda f: f
    ch = raster_chart(key, pno, 778, ('v', ident, (-3.5, 1.0, 0.5), False),
                      L_([144.3, 166.3, 188.2, 209.6, 231.4, 253.2, 274.9], [3.5, 3.0, 2.5, 2.0, 1.5, 1.0, 0.5],
                         name='D'),
                      {'red': (-2.63, 3.383), 'green': (-2.63, 3.821), 'blue': (-2.63, 3.684)}, 0.05,
                      slug + '-characteristic', f'{doc_} p6 characteristic curves', pred=ink,
                      exclude=[(181, 125.5, 271, 163.5), (89, 254, 125, 274.5), (61, 122, 85.5, 297)],
                      lo=-3.35, hi=0.95, clip_frame=False)
    se = raster_chart(key, pno, 764, L_([347.7, 407.0, 465.9, 524.9], [400, 500, 600, 700], name='nm'),
                      L_([152.1, 211.4, 270.9], [1.0, 0.0, -1.0], name='logS'),
                      {'blue': (431, 0.953), 'green': (545, 1.0), 'red': (640, 1.04)}, 5,
                      slug + '-sensitivity', f'{doc_} p6 spectral sensitivity', pred=ink,
                      exclude=[(408.5, 255, 533, 294.5), (364.5, 189, 388, 196.5), (425, 189, 447, 196.5),
                               (475.5, 189, 497, 196.5), (307, 120, 335, 297)], clip_frame=False,
                      lo={'blue': 394, 'green': 482, 'red': 549}, hi={'blue': 522, 'green': 602, 'red': 690},
                      track_kw={'max_dtheta': 1.0})
    dy = raster_chart(key, pno, 781, L_([348.3, 407.9, 466.7, 525.5], [400, 500, 600, 700], name='nm'),
                      L_([404.1, 463.6, 523.2], [1.0, 0.5, 0.0], name='D'),
                      {'yellow': (445, 0.99), 'magenta': (552, 0.99), 'cyan': (660, 0.99)}, 5,
                      slug + '-dye-density', f'{doc_} p6 spectral dye density', pred=ink,
                      exclude=[(469, 382, 519.5, 396.5), (357, 441, 382, 448.5), (425, 441, 449.5, 448.5),
                               (489, 441, 508.5, 448.5), (307, 375, 336, 546), (307, 524.5, 539, 546)],
                      clip_frame=False,
                      lo={'yellow': 397, 'magenta': 397, 'cyan': 397}, hi={'yellow': 640, 'magenta': 700, 'cyan': 710})
    mt = raster_chart(key, pno, 779, L_([83.2, 138.6, 161.9, 186.3, 216.5, 240.0, 264.1], [1, 5, 10, 20, 50, 100, 200],
                                        log=True),
                      L_([375.5, 390.0, 402.0, 413.6, 430.2, 444.7, 468.6, 480.3, 492.3, 508.5, 522.6],
                         [150, 100, 70, 50, 30, 20, 10, 7, 5, 3, 2], log=True),
                      {'neutral': (7, 109)}, 'mtf', slug + '-mtf', f'{doc_} p6 MTF', pred=ink, nd=1, lo=1.0, hi=100,
                      exclude=[(88, 497.5, 154, 516.5)], track_kw={'max_dtheta': 0.25}, drop_lines=[('h', 108)])
    return reversal_record(slug, 'FUJICHROME Velvia 100 Professional [RVP 100]', 100, key, [1, 2, 3, 5, 6],
                           ch['x'], ch['ys'], se, dy['x'], dy['ys'], mt['x'], mt['ys'], dict(
        method='raster', char_exposure='Daylight', process='CR-56 (or Kodak E-6)',
        densitometry='Fuji FAD-30S, Status A equivalent', sens_criterion='1.0 above D-min (Status A equivalent)',
        grain={'rmsDiffuse': 8, 'printGrainIndex': None, 'notes': 'Fujifilm diffuse rms granularity (x1000), 48 µm '
               'aperture, at density 1.0 above minimum density.'},
        resolving={'1.6:1': 80, '1000:1': 160},
        char_note='All four charts are scanned bitmaps (~8 px/pt) on a mid-grey background with black curves '
                  '(R solid, G dash-dot, B dashed); axis labels are separate bitmaps, so x was tied to the '
                  'label positions (-3.0 and 1.0) and the 0.5 log H grid. Between log H ≈ -1.6 and +0.3 the three '
                  'curves overlap within the line width and the traced values there are effectively a shared '
                  'centreline (±0.03 D). The chart axis is "relative exposure [log H (lux-seconds)]".',
        dye_note='Exposure: separated; process CR-56. Each dye curve is normalised to a peak of 1.0 (as drawn). The '
                 'curves run from ~397 nm (yellow, magenta, cyan) to ~710 nm (cyan); tails lying on the 0.0 frame '
                 'line cannot be separated from it and are null or approximate there.',
        extraction_note='Raster tracing of the p6 bitmaps (Japanese datasheet; there is no English edition with '
                        'curves on the Fujifilm site). Grid lines used for calibration.',
        confidence='medium',
        notes=['ISO 100 daylight; ISO 32 under 3200 K tungsten with Fuji LBB-12 (Wratten 80A).',
               'Push/pull: Fujifilm states colour and tone change little from -1/2 stop (pull) to +1 stop (push) '
               'and that up to +2 stops (EI 400) is possible for some scenes. No push curves are published.',
               'Reciprocity: no correction from 1/4000 s to 1 min; 2 min: CC2.5M +1/3 stop; 4 min: CC2.5M +1/2 '
               'stop; 8 min: CC2.5M +2/3 stop.',
               'Base: 135 cellulose triacetate 127 µm; 120/220 98 µm; sheet polyester 175 µm.',
               'Source is the Japanese-language datasheet (Fujifilm Japan datasheet index); labels were '
               'translated here.']))


L_ = axis_from_lines
DARK = lambda a, b, c: (a + b + c) < 420   # anti-aliased black ink on white (mean < 140)
LOWRES = {'base_pt': 2.0, 'keep': 32, 'dev': 1.5, 'max_dtheta': 0.8, 'gap_pen': 0.25}      # dp_track settings for ~2 px/pt bitmaps
LIGHT = lambda a, b, c: (a + b + c) < 600  # thin grey anti-aliased lines in low-resolution bitmaps
MTF_Y = [200, 100, 70, 50, 30, 20, 10, 7, 5, 3, 2, 1]
MTF_X = [1, 2, 3, 4, 5, 10, 20, 50, 100, 200, 600]


def _vision3():
    key = 'h15219'
    k = dict(pred=DARK, grid_halfwidth=2, line_frac=0.3)
    # Characteristic: tick marks of the top log-exposure axis (irregular by up to ~2 pt; LS fit).
    xa = L_([376.4, 411.7, 445.6, 480.7, 519.8, 554.2], [-4, -3, -2, -1, 0, 1], name='logH')
    ya = L_([531.5, 590.8, 649.9, 709.1], [3, 2, 1, 0], name='D')
    ch = raster_chart(key, 3, 9, xa, ya, {'blue': (-3.5, 0.849), 'green': (-3.5, 0.597), 'red': (-3.5, 0.205)},
                      0.05, 'kodak-vision3-500t-characteristic', 'H-1-5219 p3 characteristic curves',
                      exclude=[(380, 533, 482, 563), (545, 538, 557, 547.5), (545, 562.5, 557, 569.5),
                               (545, 603, 557, 610.5)], lo=-3.98, hi=0.98, **k)
    wa = L_([384.1, 404.7, 425.3, 446.1, 466.8, 487.4, 508.0, 528.7, 549.5], list(range(400, 801, 50)), name='nm')
    da = L_([120.7, 137.3, 153.7, 170.3, 186.8, 203.4, 220.0, 236.5, 253.0, 269.7, 286.0],
            [1.8, 1.6, 1.4, 1.2, 1.0, 0.8, 0.6, 0.4, 0.2, 0.0, -0.2], name='D')
    dy = raster_chart(key, 4, 16, wa, da, {'yellow': (445, 1.002), 'magenta': (540, 1.002), 'cyan': (685, 1.002),
                                           'midscaleNeutral': (445, 1.71), 'minimum': (445, 0.868),
                                           'minimum+r': (555, 0.525), 'minimum+rr': (700, 0.13),
                                           'yellow+r': (640, 0.005), 'magenta+uv': (430, -0.015)}, 5,
                      'kodak-vision3-500t-dye-density', 'H-1-5219 p4 spectral dye density',
                      exclude=[(386.5, 123.3, 491.4, 131.2), (390, 160.7, 437.3, 168.6), (392.9, 177.7, 412.5, 185),
                               (426.5, 177.1, 453.4, 184.4), (492.9, 177.1, 509, 184.4), (485.9, 247.9, 535.3, 255.7)],
                      lo={'yellow': 400.5, 'magenta': 457, 'cyan': 400.5, 'midscaleNeutral': 400.5,
                          'minimum': 400.5, 'minimum+r': 486, 'minimum+rr': 610, 'yellow+r': 562,
                          'magenta+uv': 400.5},
                      hi={'yellow': 553, 'magenta': 799.5, 'cyan': 799.5, 'midscaleNeutral': 799.5,
                          'minimum': 470, 'minimum+r': 578, 'minimum+rr': 790, 'yellow+r': 799.5,
                          'magenta+uv': 455}, track_kw=LOWRES, drop_lines=[('h', 0.0)], **k)
    sa = L_([82.1, 102.5, 122.8, 143.1, 163.6, 184.0, 204.3, 224.6, 245.0, 265.3, 285.6], list(range(250, 751, 50)))
    la = L_([116.5, 154.8, 193.4, 231.7, 270.3], [4, 3, 2, 1, 0])
    se = raster_chart(key, 4, 17, sa, la, {'blue': (420, 3.17), 'green': (545, 2.76), 'red': (655, 2.45),
                                           'red+uv': (515, 0.67)}, 5,
                      'kodak-vision3-500t-sensitivity', 'H-1-5219 p4 spectral sensitivity',
                      exclude=[(83, 233, 181, 269), (141, 155, 170, 177)],
                      lo={'blue': 368, 'green': 448, 'red': 528, 'red+uv': 508},
                      hi={'blue': 530, 'green': 602, 'red': 680, 'red+uv': 527},
                      track_kw=dict(LOWRES, max_dtheta=1.0), **k)
    fa = L_([81.1, 102.7, 115.3, 124.1, 131.2, 152.6, 174.2, 202.7, 224.3, 246.0, 280.2], MTF_X, log=True)
    ra = L_([227.4, 247.1, 257.1, 266.7, 281.1, 292.6, 312.3, 322.6, 332.0, 346.6, 357.9, 377.6], MTF_Y, log=True)
    # below ~8 c/mm the three curves merge into one line: that shared envelope is stored in each channel
    mt = raster_chart(key, 3, 10, fa, ra, {'red': (60, 50.3), 'green': (60, 43.2), 'blue': (60, 25.55),
                                           **{c + '+low': (3.5, 103.1) for c in ('red', 'green', 'blue')}}, 'mtf',
                      'kodak-vision3-500t-mtf', 'H-1-5219 p3 MTF', nd=1,
                      exclude=[(90, 340, 205, 365), (219, 270, 230, 305)],
                      lo={'red': 8.6, 'green': 8.6, 'blue': 8.6, 'red+low': 2.4, 'green+low': 2.4, 'blue+low': 2.4},
                      hi={'red': 81, 'green': 81, 'blue': 81, 'red+low': 8.5, 'green+low': 8.5, 'blue+low': 8.5},
                      track_kw=dict(LOWRES, max_dtheta=0.35), **k)
    return ch, dy, se, mt


AHU_NOTE = ('The current Kodak datasheet (Revised 3-26) states that "an Anti-halation undercoat replaces the '
            'traditional remjet backing layer"; the curves are for that construction.')


def cinestill_notes(cs, kodak, kodak_ei, ei, tungsten):
    return [
        f'CineStill {cs} is sold as KODAK {kodak} with the rem-jet anti-halation backing removed; CineStill '
        f'publishes no sensitometric data of its own. All curves are copied from the Kodak datasheet.',
        'Kodak\'s current (Revised 3-26) VISION3 datasheets say an anti-halation undercoat (AHU) now replaces the '
        'rem-jet backing. CineStill\'s "rem-jet removed" description refers to the rem-jet construction; no '
        'manufacturer document found here says which construction current CineStill stock is made from or what '
        'anti-halation protection it retains. The curves are Kodak\'s AHU-era data either way.',
        'Model as having NO effective anti-halation layer (CineStill\'s stated product): strong halation (red/orange '
        'glow around highlights, from light reflected at the base/back surface re-exposing mainly the '
        'red-sensitive layer) should be modelled separately; it is not represented in these curves.',
        (f'Rated EI {ei} by CineStill (Kodak: EI {kodak_ei}); the characteristic curves are unchanged and EI {ei} '
         f'is an exposure-placement choice of {math.log2(ei / kodak_ei):.2f} stop less exposure.' if ei != kodak_ei
         else f'Rated EI {ei} by CineStill, the same as Kodak\'s rating.') +
        (' The stock is tungsten balanced (3200 K).' if tungsten else ' The stock is daylight balanced (5500 K).'),
        'CineStill markets it for C-41 processing; the curves here are for ECN-2 as published by Kodak, so a '
        'C-41 processed negative will differ (contrast, D-min) in ways not documented by either maker.']


V3_500T = dict(
    key='h15219', ei=500, char_exposure='3200 K tungsten, 1/50 s',
    density_type='status-M (chart label: "Densitometry: ECN-2")', sens_exposure='effective exposure 1/25 s',
    mtf_exposure='3200 K tungsten', doc='H-1-5219',
    char_note='The bitmap chart has two x scales that disagree by ~4%: the log-exposure labels (-4.0..+1.0) span '
              'the frame (5.0 log H) while the camera-stop ticks (-8..+8 stops = 4.82 log H) span the same '
              'frame. Calibrated on the log-exposure ticks (least-squares, max residual 0.05 log H because '
              'those ticks are drawn unevenly). If the stop scale is right, gammas are ~4% higher.',
    sens_note='The red (cyan-forming) curve includes its secondary green-region lobe (~510-548 nm, log S '
              '0.6-0.75) which joins the main curve. Curves end where the published curves end.',
    dye_note='Traced from a bitmap; where the dashed minimum curve crosses the yellow (~475-500 nm) and magenta '
             '(~580-620 nm) flanks it is null. The yellow curve continues as the flat ~0.00 line from ~620 nm and '
             'magenta as the slightly negative (-0.02..-0.04) line below 455 nm.',
    mtf_note='Below ~8 c/mm the three curves are drawn as one line (~102-104 %); that shared value is '
             'stored in all three channels at 3-4 c/mm. From there until the curves separate (blue at '
             '~12 c/mm, red and green at ~20 c/mm) the values are null.',
    notes=['EI 500 under 3200 K tungsten (EI 320 daylight with a WRATTEN 85 filter per the datasheet).', AHU_NOTE],
    cinestill=dict(cs='800T', kodak='VISION3 500T 5219', ei=800, tungsten=True))


def vision3_record(slug, name, parts, cinestill=False, cfg=V3_500T):
    ch, dy, se, mt = parts
    key = cfg['key']
    rec = base_record(slug, name, 'Eastman Kodak Company' if not cinestill else
                      'CineStill Film (film manufactured by Eastman Kodak)', 'negative',
                      'ECN-2' if not cinestill else 'C-41 (as marketed by CineStill); the published curves are for ECN-2',
                      cfg['ei'] if not cinestill else cfg['cinestill']['ei'], key, [1, 2, 3, 4])
    rec['characteristicCurves'] = {
        'densityType': cfg.get('density_type', 'status-M (chart label: "Densitometry: Status M")'),
        'exposure': cfg['char_exposure'],
        'process': 'ECN-2', 'logExposureUnits': cfg.get('char_units', LOGH_UNITS), 'logExposure': ch['x'], **ch['ys'],
        'dMin': {c: next(v for v in ch['ys'][c] if v is not None) for c in ('red', 'green', 'blue')},
        'notes': cfg['char_note']}
    rec['spectralSensitivity'] = {
        'units': LOGS_UNITS, 'densityCriterion': '0.2 above D-min (Status M)',
        'exposure': cfg['sens_exposure'], 'process': 'ECN-2', 'wavelength': se['x'], **se['ys'],
        'notes': cfg['sens_note']}
    rec['dyeDensity'] = {
        'units': 'diffuse spectral density', 'process': 'ECN-2; D-mins subtracted', 'wavelength': dy['x'],
        'cyan': dy['ys']['cyan'], 'magenta': dy['ys']['magenta'], 'yellow': dy['ys']['yellow'],
        'minimum': dy['ys']['minimum'], 'midscaleNeutral': dy['ys']['midscaleNeutral'],
        'notes': 'Cyan, magenta and yellow curves are peak-normalised (1.0) per the datasheet note. midscaleNeutral '
                 'and minimum are as drawn ("D-mins subtracted" per the chart label). ' + cfg['dye_note']}
    rec['granularity'] = {'rmsDiffuse': None, 'printGrainIndex': None,
                          'notes': 'Published only as "Diffuse rms Granularity Curves" (granularity sigma-D vs log '
                                   'relative exposure, 48 µm aperture, ECN-2) on p3; not digitised here.'}
    rec['mtf'] = {'units': 'percent response', 'frequencyUnits': 'cycles/mm', 'exposure': cfg['mtf_exposure'],
                  'process': 'ECN-2', 'densityType': 'status-M', 'frequency': mt['x'],
                  'red': mt['ys']['red'], 'green': mt['ys']['green'], 'blue': mt['ys']['blue'],
                  'notes': cfg['mtf_note']}
    rec['interlayer'] = None
    rec['notes'] = list(cfg['notes'])
    if cinestill:
        c = cfg['cinestill']
        rec['exposureIndex'] = c['ei']
        rec['notes'] = cinestill_notes(c['cs'], c['kodak'], cfg['ei'], c['ei'], c['tungsten'])
    rec['derived'] = derived_block(rec['characteristicCurves'], rec['spectralSensitivity'], rec['dyeDensity'])
    rec['extraction'] = {'method': 'raster', 'tool': 'research/film-data/extract.py',
                         'notes': f'All {cfg["doc"]} charts are embedded ~3 px/pt anti-aliased bitmaps. Axes were '
                                  'calibrated on detected tick marks / grid lines; curves traced with a '
                                  'dynamic-programming follower that keeps each curve\'s direction through '
                                  'crossings.', 'confidence': cfg.get('confidence', 'medium'), 'checks': []}
    return rec


def _vision3_d(cfg, slug):
    """VISION3 daylight stocks (5207, 5203): same four bitmap charts as 5219, own calibration in cfg['charts']."""
    key, doc_ = cfg['key'], cfg['doc']
    k = dict(pred=DARK, grid_halfwidth=2, line_frac=0.3)
    out = []
    for part, (pno, xref, xa, ya, seeds, step, extra) in cfg['charts'].items():
        if 'runs' in extra:
            out.append(mtf_by_runs(key, pno, xref, xa, ya, extra['runs'], f'{slug}-{part}', f'{doc_} p{pno} {part}',
                                   exclude=extra.get('exclude', ())))
            continue
        kw = dict(k)
        kw.update(extra)
        out.append(raster_chart(key, pno, xref, xa, ya, seeds, step, f'{slug}-{part}', f'{doc_} p{pno} {part}', **kw))
    return out


V3_250D = dict(
    key='h15207', doc='H-1-5207', ei=250, char_exposure='5500 K daylight, 1/50 s',
    sens_exposure='effective exposure 0.02 s', mtf_exposure='5500 K daylight',
    char_units='log exposure (lux-seconds assumed: the 5207 chart prints the top-axis values -3.7..1.1 without a '
               'unit; the 5203 chart labels the same axis "LOG EXPOSURE (lux-seconds)")',
    char_note='Top axis -3.7..+1.1 in 0.6 steps (2 stops) and camera stops -8..+8 (16 stops = 4.82 log H) span the '
              'same frame (4.8 log H) and agree to 0.4%. Camera stop 0 (normal exposure at EI 250) = -1.3 log H. '
              'Curve ends at the right frame edge are under the B/G/R labels and stop at +1.0.',
    sens_note='The green (magenta-forming) curve includes its blue-region tail (400-470 nm, log S 0.3-0.6) which '
              'rises into the main curve. The red curve starts at ~533 nm where it leaves the frame floor. Curves '
              'end where the published curves end.',
    dye_note='The dashed minimum curve is traced where its dashes are resolvable; nulls are where it crosses the '
             'solid curves.',
    mtf_note='Read column by column at the standard frequencies (B above G above R wherever they are separate) '
             'rather than traced. Below ~8 c/mm the three curves are one line and B and G are one line up to ~20 '
             'c/mm: those columns store the shared value in each merged channel. Columns where the run count does '
             'not match (curves just touching) are null.',
    notes=['Daylight balanced (5500 K): EI 250 daylight; EI 64 under 3200 K / 3000 K tungsten with a WRATTEN 2 '
           'Optical Filter No. 80A. Metal halide / HMI / KINO FLO 55: no filter, EI 250. Fluorescent: warm white '
           'CC20M + CC05R EI 125; cool white CC40B EI 100.',
           'Reciprocity: no filter or exposure correction for 1/1000 s to 1 s.',
           'Acetate safety base. Process ECN-2.', AHU_NOTE],
    charts={
        'characteristic': (3, 9, L_([378.1, 399.7, 421.2, 442.7, 464.3, 485.8, 507.2, 528.9, 550.2],
                                    [round(-3.7 + 0.6 * i, 1) for i in range(9)], name='logH'),
                           L_([534.1, 591.5, 648.9, 706.1], [3, 2, 1, 0], name='D'),
                           {'blue': (-1.3, 1.63), 'green': (-1.3, 1.41), 'red': (-1.3, 0.94)}, 0.05,
                           dict(exclude=[(381, 540, 467, 567), (539.5, 542.5, 548, 550), (539.5, 563.5, 548, 570.5),
                                         (539.5, 602.5, 548, 610)], lo=-3.68, hi=1.0)),
        'dye-density': (4, 16, L_([371.3, 409.0, 446.8, 484.6, 522.3], [400, 500, 600, 700, 800], name='nm'),
                        L_([128.5 + 15.1 * i for i in range(11)], [round(1.8 - 0.2 * i, 1) for i in range(11)],
                           name='D'),
                        {'yellow': (445, 1.0), 'magenta': (540, 1.0), 'cyan': (685, 1.0),
                         'midscaleNeutral': (445, 1.57), 'minimum': (445, 0.89), 'yellow+r': (700, -0.002),
                         'midscaleNeutral+r': (700, 0.804), 'minimum+m': (520, 0.622), 'minimum+r': (700, 0.211),
                         'magenta+uv': (420, -0.008)}, 5,
                        dict(exclude=[(379, 137.5, 423.5, 145), (379, 180, 398, 186), (408, 180.5, 431.5, 187.5),
                                      (470.5, 180, 485, 186), (456.5, 240, 502, 246.5), (373.5, 267.5, 468.5, 275)],
                             lo={'yellow': 400.5, 'magenta': 465, 'cyan': 400.5, 'midscaleNeutral': 400.5,
                                 'minimum': 400.5, 'yellow+r': 600, 'midscaleNeutral+r': 612, 'minimum+m': 505,
                                 'minimum+r': 625, 'magenta+uv': 400.5},
                             hi={'yellow': 562, 'magenta': 799.5, 'cyan': 799.5, 'midscaleNeutral': 612,
                                 'minimum': 470, 'yellow+r': 799.5, 'midscaleNeutral+r': 799.5, 'minimum+m': 572,
                                 'minimum+r': 799.5, 'magenta+uv': 465},
                             track_kw=dict(LOWRES, max_dtheta={'yellow': 0.8, 'magenta': 0.8, 'cyan': 0.8,
                                                              'midscaleNeutral': 0.8, 'minimum': 0.8,
                                                              'yellow+r': 0.2, 'midscaleNeutral+r': 0.8,
                                                              'minimum+m': 0.8, 'minimum+r': 0.8,
                                                              'magenta+uv': 0.8}), drop_lines=[('h', 0.0)])),
        'sensitivity': (4, 17, L_([91.5, 109.3, 127.2, 144.8, 162.7, 180.6, 198.5, 216.4, 234.0, 251.9, 269.8],
                                  list(range(250, 751, 50)), name='nm'),
                        L_([140.5, 174.2, 207.9, 241.5, 275.4], [4, 3, 2, 1, 0], name='logS'),
                        {'blue': (440, 2.42), 'green': (545, 2.38), 'red': (655, 2.38), 'green+r': (590, 1.263),
                         'red+l': (570, 0.534)}, 5,
                        dict(exclude=[(95.5, 145, 175, 176), (146, 201.5, 164, 221.5), (184, 212.5, 206.5, 233.5),
                                      (217, 204.5, 241.5, 226)],
                             lo={'blue': 358, 'green': 400.5, 'red': 598, 'green+r': 578, 'red+l': 532},
                             hi={'blue': 522, 'green': 578, 'red': 702, 'green+r': 602, 'red+l': 598},
                             track_kw=dict(LOWRES, max_dtheta=1.0))),
        'mtf': (3, 10, L_([80.1, 101.7, 114.4, 123.3, 130.4, 152.0, 173.9, 202.4, 224.1, 245.7, 280.1], MTF_X,
                          log=True),
                L_([227.4, 247.3, 257.4, 267.2, 281.7, 293.2, 313.1, 323.2, 332.8, 347.5, 358.9, 378.8], MTF_Y,
                   log=True),
                None, 'mtf',
                dict(exclude=[(216.5, 266, 224, 305), (87, 347.5, 171.5, 371.5)],
                     runs=[(2.5, 7, [('red', 'green', 'blue')]), (8, 20, [('blue', 'green'), 'red']),
                           (25, 80, ['blue', 'green', 'red'])])),
    },
    cinestill=None)

V3_50D = dict(
    key='h15203', doc='H-1-5203', ei=50, char_exposure='5500 K daylight, 1/50 s',
    sens_exposure='effective exposure 1/10 s', mtf_exposure='5500 K daylight', confidence='medium (sensitivity: '
    'medium-low, see its notes)',
    char_note='The bitmap chart has two x scales that disagree by ~4.6%: the "LOG EXPOSURE (lux-seconds)" labels '
              '(-3.03, -0.515, 2.006) span the frame (5.04 log H) while the camera-stop ticks (-8..+8 stops = 4.82 '
              'log H) span the same frame. Calibrated on the log-exposure labels (as for 5219); camera stop 0 '
              '(normal exposure at EI 50) = -0.515 log lux-s. If the stop scale is right, gammas are ~4.6% higher. '
              'The red curve is drawn dotted.',
    sens_note='The printed log-sensitivity labels are misregistered with the grid: "4.0" sits on the frame top, but '
              '"3.0", "2.0" and "1.0" sit ~6-8 pt above the next grid line down and "0.0" falls below the frame. '
              'Calibrated on the grid (frame top 4.0, 1.0 per grid line, frame floor 0.0). On this reading the '
              'peaks (~1.6-1.8) are ~0.7 log below 5207 (250D), matching the 5x speed ratio; on the label reading '
              'they would equal 250D. The green curve includes its blue-region rise from the frame floor at '
              '~473 nm. Curves are clipped at the frame floor (0.0).',
    dye_note='The dashed minimum curve is traced where its dashes are resolvable; nulls are where it crosses the '
             'solid curves and beyond 697 nm, where its sparse dashes (~0.12-0.14) could not be followed reliably '
             'next to the "Minimum Density" label. The published curves end at ~760 nm.',
    mtf_note='The curves cross tightly (B is the shallowest: lowest from ~8 to ~36 c/mm, crossing R at ~36 and G '
             'at ~59 c/mm), so values were read column by column at the standard frequencies and named by that '
             'order rather than traced; columns where a curve lies on a grid line or at a crossing are null. Below '
             '~8 c/mm the three curves are one line (shared value), and R and G are one line up to ~15 c/mm. The '
             'chart has no grid line at 100 c/mm (frequency axis calibrated on the 1-50, 200 and 700 lines).',
    notes=['Daylight balanced (5500 K): EI 50 daylight; EI 12 under 3200 K / 3000 K tungsten with a WRATTEN 2 '
           'Optical Filter No. 80A. Metal halide / HMI / KINO FLO 55: no filter, EI 50. Fluorescent: warm white '
           'CC20M + CC05R EI 25; cool white CC40B EI 20.',
           'Reciprocity: no filter or exposure correction for 1/1000 s to 1 s.',
           'Acetate safety base. Process ECN-2.', AHU_NOTE],
    charts={
        'characteristic': (3, 11, L_([383.4, 466.4, 549.4], [-3.03, -0.515, 2.006], name='logH'),
                           L_([528.2, 582.4, 638.2, 694.1], [3, 2, 1, 0], name='D'),
                           {'blue': (-0.45, 1.721), 'green': (-0.45, 1.48), 'red': (-0.45, 0.964)}, 0.05,
                           dict(exclude=[(386, 530, 490, 556), (540.5, 532, 549, 538.5), (540.5, 543.5, 549, 549.5),
                                         (540.5, 582, 549, 588.5)], lo=-3.0, hi=1.95,
                                track_kw=dict(LOWRES, gap_pen=0.1))),
        'dye-density': (4, 18, L_([372.4, 409.7, 446.9, 484.2, 521.4], [400, 500, 600, 700, 800], name='nm'),
                        L_([131.8, 146.9, 161.6, 176.6, 191.5, 206.4, 221.3, 236.2, 251.1, 266.0, 280.9],
                           [round(1.8 - 0.2 * i, 1) for i in range(11)], name='D'),
                        {'yellow': (445, 1.0), 'magenta': (537, 1.0), 'cyan': (683, 1.0),
                         'midscaleNeutral': (445, 1.56), 'minimum': (445, 0.85), 'yellow+r': (640, 0.024),
                         'midscaleNeutral+r': (700, 0.836), 'minimum+m': (525, 0.577), 'minimum+r': (700, 0.143),
                         'magenta+uv': (420, 0.0)}, 5,
                        dict(exclude=[(374.5, 132, 481.5, 139.5), (397, 150, 440, 156.5), (383, 182, 400.5, 188.5),
                                      (409, 184, 431.5, 190), (469.5, 179, 484.5, 185.5), (468, 248, 512.5, 253.5)],
                             lo={'yellow': 400.5, 'magenta': 465, 'cyan': 400.5, 'midscaleNeutral': 400.5,
                                 'minimum': 400.5, 'yellow+r': 580, 'midscaleNeutral+r': 612, 'minimum+m': 505,
                                 'minimum+r': 625, 'magenta+uv': 400.5},
                             hi={'yellow': 580, 'magenta': 758, 'cyan': 758, 'midscaleNeutral': 612,
                                 'minimum': 470, 'yellow+r': 758, 'midscaleNeutral+r': 758, 'minimum+m': 572,
                                 'minimum+r': 697, 'magenta+uv': 465},
                             track_kw=dict(LOWRES, max_dtheta={n: 0.2 if n == 'minimum+r' else 0.8 for n in (
                                 'yellow', 'magenta', 'cyan', 'midscaleNeutral', 'minimum', 'yellow+r',
                                 'midscaleNeutral+r', 'minimum+m', 'minimum+r', 'magenta+uv')}),
                             drop_lines=[('h', 0.0)])),
        'sensitivity': (4, 19, L_([86.8, 105.4, 123.6, 142.1, 160.7, 179.2, 197.8, 216.0, 234.5, 253.1, 271.6],
                                  list(range(250, 751, 50)), name='nm'),
                        L_([138.4, 173.0, 207.9, 242.8, 277.8], [4, 3, 2, 1, 0], name='logS'),
                        {'blue': (430, 1.6), 'green': (545, 1.6), 'red': (645, 1.55), 'green+l': (480, 0.11),
                         'green+r': (580, 1.106), 'red+l': (580, 0.366)}, 5,
                        dict(exclude=[(87, 142.5, 179.5, 171.5), (124, 196, 156, 219), (182, 194.5, 214, 217),
                                      (226, 197.5, 249, 219.5)],
                             lo={'blue': 358, 'green': 498, 'red': 598, 'green+l': 473, 'green+r': 575, 'red+l': 570},
                             hi={'blue': 498, 'green': 575, 'red': 678, 'green+l': 498, 'green+r': 593, 'red+l': 598},
                             track_kw=dict(LOWRES, max_dtheta=1.0))),
        'mtf': (3, 12, L_([85.2, 105.5, 117.5, 125.9, 132.4, 152.8, 173.3, 200.2, 240.8, 277.8],
                          [1, 2, 3, 4, 5, 10, 20, 50, 200, 700], log=True),
                L_([229.9, 249.0, 258.8, 267.8, 281.8, 293.2, 312.0, 321.7, 331.1, 345.1, 356.1, 375.2], MTF_Y,
                   log=True),
                None, 'mtf',
                # B is the shallowest curve: lowest from ~8 to ~36 c/mm, then crosses R (~36) and G (~59);
                # R and G run as one line up to ~15 c/mm, all three below ~8 c/mm
                dict(exclude=[(214.5, 285, 223, 314), (89, 344.5, 170.5, 367.5)],
                     runs=[(2.5, 7, [('red', 'green', 'blue')]), (8, 20, [('red', 'green'), 'blue']),
                           (25, 35, ['green', 'red', 'blue']), (40, 50, ['green', 'blue', 'red']),
                           (60, 70, ['blue', 'green', 'red'])])),
    },
    cinestill=dict(cs='50D', kodak='VISION3 50D 5203', ei=50, tungsten=False))


@stock
def kodak_vision3_250d():
    slug = 'kodak-vision3-250d'
    ch, dy, se, mt = _vision3_d(V3_250D, slug)
    return vision3_record(slug, 'KODAK VISION3 250D Color Negative Film 5207 / 7207', (ch, dy, se, mt), cfg=V3_250D)


@stock
def kodak_vision3_50d():
    slug = 'kodak-vision3-50d'
    return vision3_record(slug, 'KODAK VISION3 50D Color Negative Film 5203 / 7203', _vision3_d(V3_50D, slug),
                          cfg=V3_50D)


@stock
def cinestill_50d():
    return vision3_record('cinestill-50d', 'CineStill 50D (KODAK VISION3 50D 5203 without rem-jet)',
                          _vision3_d(V3_50D, 'kodak-vision3-50d'), cinestill=True, cfg=V3_50D)


@stock
def kodak_vision3_500t():
    return vision3_record('kodak-vision3-500t', 'KODAK VISION3 500T Color Negative Film 5219 / 7219', _vision3())


@stock
def cinestill_800t():
    import copy
    parts = _vision3()
    rec = vision3_record('cinestill-800t', 'CineStill 800T (KODAK VISION3 500T 5219 without rem-jet)',
                         copy.deepcopy(parts), cinestill=True)
    return rec


@stock
def kodak_2383():
    key, slug = 'h12383', 'kodak-2383'
    k = dict(pred=LIGHT, grid_halfwidth=2, line_frac=0.3, half=1)
    xa = L_([69.6, 100.3, 131.0, 161.8, 192.5, 223.2, 253.9], [-3, -2, -1, 0, 1, 2, 3], name='logH')
    ya = L_([78.4, 109.4, 139.9, 170.8, 201.6, 232.3, 263.0], [6, 5, 4, 3, 2, 1, 0], name='D')
    ch = raster_chart(key, 4, 15, xa, ya, {'blue': (0.5, 1.445), 'green': (0.8, 1.461), 'red': (1.0, 0.953)}, 0.05,
                      slug + '-characteristic', 'H-1-2383 p4 characteristic curves',
                      exclude=[(70, 80, 250, 112)], lo={'blue': -1.0, 'green': -0.5, 'red': -0.05}, hi=2.6,
                      track_kw={'max_dtheta': 1.0}, **k)
    wa = L_([362.5, 380.2, 398.0, 415.9, 433.7, 451.6, 469.6, 487.3, 505.3, 523.0, 541.0], list(range(250, 751, 50)))
    da = L_([92.2, 117.7, 143.1, 168.6, 194.2, 219.7, 245.1], [1.2, 1.0, 0.8, 0.6, 0.4, 0.2, 0.0])
    # the short-wavelength ends of yellow (dip at ~368 nm) and of the neutral (steep rise below the
    # ~378 nm minimum) are traced from their own seeds and joined: crossings there confuse a single trace
    dy = raster_chart(key, 5, 24, wa, da, {'yellow': (445, 0.814), 'magenta': (545, 0.878), 'cyan': (655, 1.085),
                                           'visualNeutral': (545, 1.125), 'yellow+uv': (368, 0.19),
                                           'visualNeutral+uv': (362, 1.0)}, 5,
                      slug + '-dye-density', 'H-1-2383 p5 spectral dye density',
                      exclude=[(367, 67, 526, 89.5), (446, 93, 486, 100.3), (422, 171.5, 443, 178.5),
                               (450.5, 184.5, 477.5, 191), (501, 117.5, 514, 124)],
                      lo={'yellow': 383, 'magenta': 351, 'cyan': 351, 'visualNeutral': 379, 'yellow+uv': 351,
                          'visualNeutral+uv': 351},
                      hi={'yellow': 714, 'magenta': 749, 'cyan': 749, 'visualNeutral': 749, 'yellow+uv': 382,
                          'visualNeutral+uv': 378},
                      track_kw=dict(LOWRES, max_dtheta={'yellow': 0.6, 'magenta': 0.6, 'cyan': 0.6,
                                                        'visualNeutral': 0.8, 'yellow+uv': 1.0,
                                                        'visualNeutral+uv': 0.8}),
                      **k)
    sa = L_([76.5, 95.9, 115.9, 135.4, 155.1, 174.8, 194.2, 214.3, 233.7, 253.7, 273.1], list(range(250, 751, 50)))
    la = L_([59.6, 96.9, 134.3, 171.4, 208.5], [1, 0, -1, -2, -3])
    # Read column by column: the green peak (550 nm) and red curve (700-705 nm) sit on vertical grid lines,
    # where samples are interpolated between the clean columns either side (≤ 2.5 pt away).
    box = lambda n0, n1, v0, v1: (sa.pos(n0), la.pos(v0), sa.pos(n1), la.pos(v1))
    se = curves_by_columns(
        key, 5, 23, sa, la,
        [(355, 367, [['blue']]), (367, 406, [['blue'], ['blue', '_f'], ['blue', '_f', '_f']]),
         (406, 449, [['blue']]), (449, 492, [['blue', 'green']]), (494, 513, [['green', 'blue']]),
         (513, 584, [['green']]),
         (592, 735, [['red']])],
        grid(355, 735, 5), slug + '-sensitivity', 'H-1-2383 p5 spectral sensitivity (column read)',
        exclude=[box(252, 605, 1.0, 0.72), box(252, 405, 0.72, 0.18), (141, 108, 168, 133),
                 box(565, 656, -0.06, -0.78), box(655, 712, -1.81, -2.42)], pred=LIGHT,
        frame=(76.5, 59.6, 273.1, 208.2))
    fa = L_([73.9, 95.5, 108.5, 117.4, 124.3, 146.4, 168.2, 197.0, 218.9, 240.7, 275.5], MTF_X, log=True)
    ra = L_([381.6, 401.2, 411.8, 421.4, 436.0, 447.8, 467.7, 477.8, 487.6, 502.3, 514.0, 533.7], MTF_Y, log=True)
    mt = raster_chart(key, 4, 17, fa, ra, {'green': (60, 79.7), 'red': (60, 61.0), 'blue': (60, 35.2)}, 'mtf',
                      slug + '-mtf', 'H-1-2383 p4 MTF', nd=1,
                      exclude=[(85, 480, 205, 520)] + [(fa.pos(74.5), ra.pos(hi_), fa.pos(92), ra.pos(lo_))
                                                       for lo_, hi_ in ((79.4, 95), (38.8, 48), (22, 28))],
                      lo={'green': 2.9, 'red': 42, 'blue': 21}, hi=82,
                      track_kw=dict(LOWRES, max_dtheta=0.35, gap_pt={'blue': 12.0}),
                      drop_lines=[('h', 81.8)], **k)
    rec = base_record(slug, 'KODAK VISION Color Print Film 2383 / 3383', 'Eastman Kodak Company', 'print',
                      'ECP-2D', None, key, [1, 2, 3, 4, 5])
    rec['characteristicCurves'] = {
        'densityType': 'status-A', 'exposure': '1/500 s tungsten plus KODAK Heat Absorbing Glass No. 2043 (plus '
                                              'Series 1700 filter)', 'process': 'ECP-2D',
        'logExposureUnits': LOGH_UNITS, 'logExposure': ch['x'], **ch['ys'],
        'dMin': {c: next(v for v in ch['ys'][c] if v is not None) for c in ('red', 'green', 'blue')},
        'notes': 'Status A densities of the print film. dMin = density at the lowest traced exposure of each curve.'}
    rec['spectralSensitivity'] = {
        'units': LOGS_UNITS, 'densityCriterion': 'D = 1.0', 'exposure': 'tungsten, 1/50 s', 'process': 'ECP-2D',
        'wavelength': se['x'], **se['ys'],
        'interpolatedSamples': {k: v for k, v in se['interpolated'].items() if v},
        'notes': 'Re-traced 2026-10-01 (batch 2). The datasheet (Revised 8-26, the current and only revision found) '
                 'carries this chart only as a 428x397 px bitmap (1.7 px/pt); no vector or higher-resolution '
                 'version is published. Curves and grid share one colour, so the chart is read column by column '
                 '(curves_by_columns): every image column between grid lines, ink runs named by their top-to-bottom '
                 'order, steep segments taken at the run centre. Samples falling on a vertical grid line '
                 '(interpolatedSamples) are linear interpolations between the nearest clean columns on both '
                 'sides, ≤ 2.5 pt (≈ 6 nm) away; none is interpolated across a longer gap. The magenta-forming '
                 '(green) peak is a cusp on the 550 nm line: its interpolated value (≈ -0.27) may sit up to ~0.1 '
                 'below the drawn tip. Still null: blue 355-370 nm (lies along the 0.0 grid line), the green '
                 'curve\'s vertical start at 450 nm (along the grid line), the green/red tails at 584-592 nm '
                 '(the curves merge), and two unlabelled steep fragments from ~368 nm (-0.75) to -3.0 at ~390 and '
                 '~400 nm (secondary short-wavelength responses; not attributable to a layer from the chart).'}
    rec['dyeDensity'] = {
        'units': 'diffuse spectral density', 'process': 'ECP-2D', 'wavelength': dy['x'],
        'cyan': dy['ys']['cyan'], 'magenta': dy['ys']['magenta'], 'yellow': dy['ys']['yellow'], 'minimum': None,
        'midscaleNeutral': None, 'visualNeutral': dy['ys']['visualNeutral'],
        'notes': 'Chart: "Normalized dyes to form a visual neutral density of 1.0 for a xenon-arc viewing '
                 'illuminant" (the dyes are scaled to the amounts forming that neutral, so their peaks are not 1.0, '
                 'although a page note calls them peak-normalized). visualNeutral is the resulting neutral curve. '
                 'No D-min curve is published. Between 350 and 450 nm two low curves cross near 385 and 450 nm; '
                 'they are attributed by continuity to cyan (the ~0.3 lobe at ~390 nm) and magenta (the ~0.04-0.09 '
                 'tail), which is the smoothest reading but is not labelled on the chart. The yellow dip at '
                 '~368 nm and the neutral below its ~378 nm minimum were traced as separate pieces and joined.'}
    rec['granularity'] = {'rmsDiffuse': None, 'printGrainIndex': None,
                          'notes': 'Published only as "Diffuse rms Granularity Curves" (sigma-D vs log exposure, '
                                   'ECP-2D, Status A) on p4; not digitised here.'}
    rec['mtf'] = {'units': 'percent response', 'frequencyUnits': 'cycles/mm', 'exposure': 'tungsten 3200 K',
                  'process': 'ECP-2D', 'densityType': 'status-A', 'target': '35% modulation target',
                  'frequency': mt['x'], 'red': mt['ys']['red'], 'green': mt['ys']['green'], 'blue': mt['ys']['blue'],
                  'notes': 'Below ~20 c/mm the three curves overlap within the line width (±3 %); only the upper '
                           'envelope is traced there and stored as green. Red is traced from 43 c/mm (it runs along '
                           'the 70 % grid line and against green below that) and blue from ~22 c/mm; lower '
                           'frequencies are null for those two.'}
    rec['interlayer'] = None
    rec['notes'] = ['Exposure index is not applicable to print film (null).']
    rec['derived'] = derived_block(rec['characteristicCurves'], rec['spectralSensitivity'], rec['dyeDensity'])
    rec['extraction'] = {'method': 'raster', 'tool': 'research/film-data/extract.py',
                         'notes': 'All H-1-2383 charts are low-resolution embedded bitmaps (1.7-2.5 px/pt). Axes '
                                  'from tick marks / grid lines; characteristic, dye and MTF curves traced with the '
                                  'dynamic-programming follower; spectral sensitivity read column by column '
                                  '(re-traced in batch 2: previously the green peak and the steep tails were '
                                  'missing).',
                         'confidence': 'medium (characteristic, dye, MTF, sensitivity); sensitivity peak at 550 nm '
                                       'interpolated across the grid line',
                         'checks': []}
    return rec


@stock
def kodak_gold_200():
    r = kodak_colour_negative('e7022', 4, (81.7, 71.9, 266.2, 256.4), (74.9, 317.9, 275.4, 469.4),
                              (357.1, 55.4, 541.4, 239.7), None, 'kodak-gold-200',
                              char_xvalues=[-3.0, -2.0, -1.0, 0.0, 1.0], sens_extra={'red': (385, 480)})
    pgi = [('135 (24x36 mm)', '4x6 in', '4.4X', 44), ('135 (24x36 mm)', '8x10 in', '4.4X (as printed)', 64),
           ('120 (6x6 cm)', '4x6 in', '2.6X', 33), ('120 (6x6 cm)', '8x10 in', '4.4X', 44),
           ('120 (6x6 cm)', '16x20 in', '8.8X', 64)]
    return kodak_cn_record(r, 'kodak-gold-200', 'KODAK GOLD 200 Film', 200, 'e7022', [3, 4], -1.14, 'Daylight',
                           'Daylight, effective exposure 1/50 s', pgi, mtf=False,
                           notes=['The log-exposure axis is printed in Kodak bar notation (3̄.0 = -3.0).',
                                  'The red-sensitive (cyan-forming) sensitivity curve is drawn in two pieces: a '
                                  'secondary lobe at ~390-465 nm (log S up to ~0.6) that runs down onto the 0.0 '
                                  'frame, and the main curve that re-emerges from the frame at ~490 nm. Both are '
                                  'stored in "red"; samples lying on the chart floor (log S <= 0) are null.',
                                  'No MTF curve is published in E-7022 (March 2022 edition); mtf is null.'])


@stock
def kodak_portra_160():
    r = kodak_colour_negative('e4051', 4, (81.4, 102.1, 266.0, 286.6), (73.8, 348.0, 274.2, 499.6),
                              (355.1, 101.2, 539.5, 285.5), (349.0, 350.4, 551.4, 503.5), 'kodak-portra-160',
                              mtf_names=('green', 'blue', 'red'))
    pgi = [('135 (24x36 mm)', '4x6 in', '4.4X', 28), ('135 (24x36 mm)', '8x10 in', '8.8X', 50),
           ('135 (24x36 mm)', '16x20 in', '17.8X', 79),
           ('120 (6x6 cm)', '4x6 in', '2.6X', '<25'), ('120 (6x6 cm)', '8x10 in', '4.4X', 28),
           ('120 (6x6 cm)', '16x20 in', '8.8X', 50),
           ('4x5 in sheet', '4x6 in', '1.2X', '<25'), ('4x5 in sheet', '8x10 in', '2X', '<25'),
           ('4x5 in sheet', '16x20 in', '4X', 26)]
    return kodak_cn_record(r, 'kodak-portra-160', 'KODAK PROFESSIONAL PORTRA 160 Film', 160, 'e4051', [1, 2, 3, 4],
                           -1.051, 'Daylight', 'Daylight, effective exposure 1/50 s', pgi, notes=[
        'ISO 160 daylight / electronic flash; ISO 50 under 3400 K photolamps with WRATTEN 80B; ISO 40 under 3200 K '
        'tungsten with WRATTEN 80A (daylight-balanced film).',
        'No filter or exposure correction is needed from 1/10,000 s to 1 s (reciprocity); longer exposures: test.',
        'MTF curve labels at the high-frequency end read G (top), B, R (bottom).',
        'Red-filter densities of a normally exposed negative: gray card 0.79-0.89; lightest step of a paper gray '
        'scale 1.15-1.25; forehead 1.10-1.20 (light) / 0.95-1.05 (dark complexion).'])


@stock
def kodak_portra_800():
    key, slug = 'e4040', 'kodak-portra-800'
    bar = [-4.0, -3.0, -2.0, -1.0, 0.0, 1.0]
    # the EI 800 chart prints its x labels as -4.0, -2.0, -3.0, -1.0, 0.0, 1.0 (two swapped); they are evenly
    # spaced, so the values are assigned in reading order
    r = kodak_colour_negative(key, 4, (81.6, 74.5, 266.2, 258.9), (350.2, 313.7, 550.9, 465.4),
                              (81.1, 101.8, 265.4, 286.1), (71.6, 345.7, 274.1, 498.7), slug, char_xvalues=bar,
                              pages={'dye': 5, 'mtf': 5})
    variants, gv = [], {}
    for F, ei, push, tag in (((81.1, 314.1, 265.6, 498.5), 1600, '1 stop push', 'push1'),
                             ((357.6, 71.0, 542.2, 255.5), 3200, '2 stop push', 'push2')):
        v = vchart(key, 4, F, lambda cs, xa, ya: by_order_at(cs, xa, ya, lo_x(cs, xa) + 0.05, ['blue', 'green', 'red']),
                   0.05, f'{slug}-characteristic-{tag}', f'E-4040 p4 characteristic curves EI {ei} ({push})',
                   xvalues=bar)
        variants.append({'exposureIndex': ei, 'process': f'C-41, {push} (as labelled on the chart)',
                         'logExposure': v['x'], **v['ys'], 'dMin': {c: v['ys'][c][0] for c in ('red', 'green', 'blue')}})
        gv[f'EI {ei}'] = {c: round(gamma_fit(v['x'], v['ys'][c]), 3) for c in ('red', 'green', 'blue')}
    pgi = [('135 (24x36 mm)', '4x6 in', '4.4X', 48), ('135 (24x36 mm)', '8x10 in', '8.8X', 70),
           ('135 (24x36 mm)', '16x20 in', '17.8X', 99),
           ('120 (6x6 cm)', '4x6 in', '2.6X', 36), ('120 (6x6 cm)', '8x10 in', '4.4X', 48),
           ('120 (6x6 cm)', '16x20 in', '8.8X', 70)]
    rec = kodak_cn_record(r, slug, 'KODAK PROFESSIONAL PORTRA 800 Film', 800, key, [2, 3, 4, 5], -1.74, 'Daylight',
                          'Daylight, effective exposure 1/200 s', pgi, notes=[
        'ISO 800 daylight / electronic flash; ISO 250 under 3400 K photolamps with WRATTEN 80B; ISO 200 under 3200 K '
        'tungsten with WRATTEN 80A (daylight-balanced film).',
        'Push processing is published: characteristicCurves.variants holds the EI 1600 (push 1) and EI 3200 '
        '(push 2) curves, same exposure, densitometry and Log H Ref (-1.74) as the EI 800 chart. The datasheet does '
        'not give the push development times (C-41 push is lab practice, typically longer developer time).',
        'Red-filter densities of a normally exposed negative (EI 800 / 1600 push 1 / 3200 push 2): gray card '
        '0.75-0.95 / 0.85-1.05 / 0.95-1.15; lightest paper-gray-scale step 1.00-1.20 / 1.20-1.40 / 1.40-1.60.',
        'No filter or exposure correction is needed from 1/10,000 s to 1 s (reciprocity).',
        'High-speed film: sensitive to ambient radiation and airport x-ray inspection (datasheet note).',
        'The EI 800 chart prints its log-exposure labels as -4.0, -2.0, -3.0, -1.0, 0.0, 1.0 (two transposed); '
        'they are evenly spaced and were read as -4.0 ... 1.0 in order.'])
    rec['characteristicCurves']['variants'] = variants
    rec['characteristicCurves']['condition'] = 'EI 800, normal C-41 processing'
    rec['derived']['gammaByVariant'] = gv
    return rec


@stock
def kodak_ultramax_400():
    r = kodak_colour_negative('e7023', 4, (81.1, 112.7, 265.9, 297.4), (76.6, 371.0, 277.6, 522.6),
                              (357.2, 113.0, 541.5, 297.2), None, 'kodak-ultramax-400')
    pgi = [('135 (24x36 mm)', '4x6 in', '4.4X', 46)]
    return kodak_cn_record(r, 'kodak-ultramax-400', 'KODAK ULTRA MAX 400 Film', 400, 'e7023', [1, 2, 3, 4],
                           -1.44, 'Daylight', 'Daylight, effective exposure 1/100 s', pgi, mtf=False, notes=[
        'ISO/DIN 400/27° (daylight-balanced consumer film). The datasheet gives no tungsten / filter speed table.',
        'No exposure or filter adjustment from 1/10,000 s to 1 s; longer exposures may need compensation.',
        'Printing-compatible with KODAK GOLD films (datasheet).',
        'No MTF curve and no rms granularity are published in E-7023 (Feb 2016); mtf is null. Only one Print Grain '
        'Index figure is given (135, 4x6 in print).',
        'Red-filter densities of a normally exposed negative: gray card 0.80-1.00; lightest paper-gray-scale step '
        '1.20-1.40; forehead 1.10-1.40 (light) / 0.85-1.25 (dark complexion).'])


def neutral_and_dyes(cs, xa, ya):
    """Dye chart with a visual-neutral curve: the neutral is the curve with the highest mean density."""
    mean = lambda c: sum(ya.val(y) for p in c['polys'] for _, y in p) / sum(len(p) for p in c['polys'])
    cs = sorted(cs, key=mean)
    return {**by_peak(cs[:-1], xa, ya, BANDS_DYE), 'visualNeutral': cs[-1]['polys']}


@stock
def kodak_ektachrome_e100():
    slug, key = 'kodak-ektachrome-e100', 'e4000'
    rgb = ('red', 'green', 'blue')
    ch = vchart(key, 3, (368.7, 358.6, 553.9, 543.0),
                lambda cs, xa, ya: by_order_at(cs, xa, ya, lo_x(cs, xa) + 0.05, ['blue', 'green', 'red']),
                0.05, slug + '-characteristic', 'E-4000 p3 characteristic curves', min_width=40)
    mt = vchart(key, 3, (357.6, 126.9, 560.1, 279.7),
                lambda cs, xa, ya: by_order_at(cs, xa, ya, hi_x(cs, xa) - 0.01, ['blue', 'green', 'red']),
                'mtf', slug + '-mtf', 'E-4000 p3 MTF', xlog=True, ylog=True, nd=1, max_width_frac=0.9)
    se = vchart(key, 4, (74.3, 107.0, 274.9, 258.5), lambda cs, xa, ya: by_peak(cs, xa, ya, BANDS_RGB),
                5, slug + '-sensitivity', 'E-4000 p4 spectral sensitivity', max_width_frac=0.8, floor=True)
    dy = vchart(key, 4, (70.6, 349.7, 271.1, 501.1), neutral_and_dyes, 5, slug + '-dye-density',
                'E-4000 p4 spectral dye density')
    rec = base_record(slug, 'KODAK PROFESSIONAL EKTACHROME Film E100', 'Kodak Alaris (KODAK PROFESSIONAL)',
                      'reversal', 'E-6', 100, key, [1, 2, 3, 4])
    xs, c = ch['x'], ch['ys']
    rec['characteristicCurves'] = {
        'densityType': 'status-A', 'exposure': 'Daylight, 1/100 s', 'process': 'E-6',
        'logExposureUnits': LOGH_UNITS, 'logExposure': xs, **c,
        'dMax': {k: next(v for v in c[k] if v is not None) for k in rgb},
        'dMin': {k: next(v for v in reversed(c[k]) if v is not None) for k in rgb},
        'notes': 'Reversal: density falls with exposure. dMax / dMin = density at the lowest / highest plotted '
                 'exposure. The three curves separate only in the shoulder (D > ~2.5, B highest) and coincide '
                 'within the line width below D ≈ 2.'}
    rec['spectralSensitivity'] = {
        'units': LOGS_UNITS, 'densityCriterion': 'equivalent neutral density (E.N.D.) = 1.0',
        'exposure': 'effective exposure 1/10 s', 'process': 'E-6', 'wavelength': se['x'], **se['ys'],
        'notes': 'red = red-sensitive (cyan-forming) layer, green = magenta-forming, blue = yellow-forming. Curves '
                 'end where the published curves end; samples on the chart floor are null.'}
    rec['dyeDensity'] = {
        'units': 'diffuse spectral density', 'process': 'E-6', 'wavelength': dy['x'],
        'cyan': dy['ys']['cyan'], 'magenta': dy['ys']['magenta'], 'yellow': dy['ys']['yellow'],
        'minimum': None, 'midscaleNeutral': None, 'visualNeutral': dy['ys']['visualNeutral'],
        'notes': 'Chart: "Normalized dyes to form a visual neutral density of 1.0 for a viewing illuminant of '
                 '5000 K"; visualNeutral is the resulting neutral. No D-min curve is published.'}
    rec['granularity'] = {'rmsDiffuse': 8, 'printGrainIndex': None,
                          'notes': 'Diffuse rms granularity 8 ("extremely fine"), read at a gross diffuse visual '
                                   'density of 1.0 with a 48 µm aperture (Kodak x1000 scale; reversal-film '
                                   'convention, i.e. at D = 1.0 gross rather than 1.0 above D-min).'}
    rec['mtf'] = {'units': 'percent response', 'frequencyUnits': 'cycles/mm', 'process': 'E-6',
                  'frequency': mt['x'], **mt['ys'],
                  'notes': 'Exposure illuminant not stated on the chart. Labels at the high-frequency end read B '
                           '(top), G, R.'}
    rec['interlayer'] = None
    rec['notes'] = [
        'EI 100 daylight / electronic flash; EI 32 under 3400 K photolamps with WRATTEN 80B; EI 25 under 3200 K '
        'tungsten with WRATTEN 80A (daylight-balanced).',
        'Reciprocity: no correction from 1/10,000 s to 10 s; at 120 s add CC10R. Multiple flash: none up to 4 '
        'pops, CC05M for 8.',
        'Push processing: effective speed is raised by extending the E-6 first-developer time; recommended '
        'starting point for push 1 is EI 200 with 8 minutes in the first developer (labs typically offer push '
        '1/2 and push 1). No push characteristic curves are published.',
        'Low D-min and a low-contrast tone scale are design features (datasheet).']
    rec['derived'] = derived_block(rec['characteristicCurves'], rec['spectralSensitivity'], rec['dyeDensity'],
                                   reversal=True)
    rec['derived']['gammaNote'] = 'Reversal: gamma is the magnitude of the (negative) slope.'
    rec['extraction'] = {'method': 'vector', 'tool': 'research/film-data/extract.py',
                         'notes': 'All four charts are vector paths; sampled from path geometry with tick-snapped '
                                  'axes.', 'confidence': 'high', 'checks': []}
    return rec


@stock
def kodak_kodachrome_64():
    slug, key = 'kodak-kodachrome-64', 'e55'
    rgb = ('red', 'green', 'blue')
    # Bar-notation labels (3̄.0 = -3.0); axes from the frame edges and grid lines, which the labels sit on.
    ch = vchart(key, 6, (71.3, 161.7, 255.8, 346.2),
                lambda cs, xa, ya: by_order_at(cs, xa, ya, lo_x(cs, xa) + 0.05, ['red', 'green', 'blue']),
                0.05, slug + '-characteristic', 'E-55 p6 KODACHROME 64 characteristic curves', min_width=40,
                xaxis=axis_from_pairs([(71.3 + i * (255.8 - 71.3) / 4, -3.0 + i) for i in range(5)], name='logH'),
                yaxis=axis_from_pairs([(161.7, 4.0), (346.2, 0.0)], name='D'))
    se = vchart(key, 6, (74.7, 422.3, 275.2, 573.8), lambda cs, xa, ya: by_peak(cs, xa, ya, BANDS_RGB),
                5, slug + '-sensitivity', 'E-55 p6 KODACHROME 64 spectral sensitivity', max_width_frac=0.8,
                xaxis=axis_from_pairs([(74.7 + i * (255.5 - 74.7) / 9, 250 + 50 * i) for i in range(10)], name='nm'),
                yaxis=axis_from_pairs([(422.3, 2.0), (460.2, 1.0), (498.1, 0.0), (535.9, -1.0), (573.8, -2.0)],
                                      name='log S'))
    dy = vchart(key, 6, (352.0, 305.3, 536.3, 489.6), neutral_and_dyes, 5, slug + '-dye-density',
                'E-55 p6 KODACHROME 64 spectral dye density',
                xaxis=axis_from_pairs([(352.0, 400), (536.3, 700)], name='nm'),
                yaxis=axis_from_pairs([(489.6, 0.0), (425.7, 0.5), (361.3, 1.0)], name='D'))
    mt = vchart(key, 6, (351.2, 58.4, 553.7, 211.4), lambda cs, xa, ya: {'neutral': cs[0]['polys']},
                'mtf', slug + '-mtf', 'E-55 p6 KODACHROME 64 MTF', nd=1, max_width_frac=0.9,
                xaxis=axis_from_pairs([(351.2, 1), (372.9, 2), (385.6, 3), (394.9, 4), (401.5, 5), (422.9, 10),
                                       (445.5, 20), (474.5, 50), (496.2, 100), (517.6, 200)], log=True, name='c/mm'),
                yaxis=axis_from_pairs([(77.7, 100), (88.2, 70), (97.9, 50), (112.6, 30), (124.4, 20), (144.6, 10),
                                       (154.8, 7), (165.1, 5), (179.2, 3), (191.9, 2), (211.4, 1)], log=True,
                                      name='%'))
    rec = base_record(slug, 'KODACHROME 64 Professional Film (PKR)', 'Eastman Kodak Company', 'reversal',
                      'K-14', 64, key, [1, 2, 3, 6])
    xs, c = ch['x'], ch['ys']
    rec['characteristicCurves'] = {
        'densityType': 'status-A', 'exposure': 'Daylight, 1/50 s', 'process': 'K-14',
        'logExposureUnits': LOGH_UNITS, 'logExposure': xs, **c,
        'dMax': {k: next(v for v in c[k] if v is not None) for k in rgb},
        'dMin': {k: next(v for v in reversed(c[k]) if v is not None) for k in rgb},
        'notes': 'Reversal: density falls with exposure. dMax / dMin = density at the lowest / highest plotted '
                 'exposure. The x labels use Kodak bar notation (3̄.0 = -3.0); axes calibrated on the frame edges '
                 '(-3.0 and +1.0 log H; 0 and 4.0 D). Curves are drawn in black and identified by their end labels '
                 '(R top, G, B at the shoulder); they merge in the toe.'}
    rec['spectralSensitivity'] = {
        'units': LOGS_UNITS, 'densityCriterion': 'equivalent neutral density (E.N.D.) = 1.00',
        'exposure': 'effective exposure 1.4 s', 'process': 'K-14', 'wavelength': se['x'], **se['ys'],
        'notes': 'red = cyan-forming layer, green = magenta-forming, blue = yellow-forming (chart labels). Bar-'
                 'notation y labels (1̄.0 = -1.0). Curves end where the published curves end.'}
    rec['dyeDensity'] = {
        'units': 'diffuse spectral density', 'process': 'K-14', 'wavelength': dy['x'],
        'cyan': dy['ys']['cyan'], 'magenta': dy['ys']['magenta'], 'yellow': dy['ys']['yellow'],
        'minimum': None, 'midscaleNeutral': None, 'visualNeutral': dy['ys']['visualNeutral'],
        'notes': 'Chart: "Normalized dyes to form a visual density of 1.0 for a viewing illuminant of 3200 K" '
                 '(not 5000 K as on current Kodak reversal sheets); visualNeutral is the resulting neutral. No '
                 'D-min curve is published. Kodachrome dyes are formed in processing (K-14 colour developers '
                 'contain the couplers), not by couplers coated in the film.'}
    rec['granularity'] = {'rmsDiffuse': 10, 'printGrainIndex': None,
                          'notes': 'Diffuse rms granularity 10, read at a gross diffuse visual density of 1.0 with a '
                                   '48 µm aperture, 12x magnification (Kodak x1000 scale; reversal convention).'}
    rec['mtf'] = {'units': 'percent response', 'frequencyUnits': 'cycles/mm', 'exposure': 'Daylight',
                  'process': 'K-14', 'frequency': mt['x'], 'neutral': mt['ys']['neutral'],
                  'notes': 'Single curve, "Densitometry: Diffuse visual". The top label "150" is not on the log '
                           'scale and was not used; y calibrated on 1-100%.'}
    rec['interlayer'] = None
    rec['notes'] = [
        'DISCONTINUED (Kodak ended Kodachrome 64 in 2009 and K-14 processing in 2010). Datasheet fetched from an '
        'Internet Archive capture (2000-08-17) of Kodak\'s own URL.',
        'EI 64 daylight / electronic flash; EI 20 under 3400 K photolamps with WRATTEN 80B; EI 16 under 3200 K '
        'tungsten with WRATTEN 80A.',
        'Reciprocity (E-55 table): +1/3 stop with CC05R at 1/10 s; 10 s exposures not recommended.',
        'Push processing is not recommended for KODACHROME 25 and 64.',
        'Base: 5.3-mil (0.13 mm) acetate. Non-substantive process: dyes are formed in three separate colour-'
        'development steps of Process K-14.']
    rec['derived'] = derived_block(rec['characteristicCurves'], rec['spectralSensitivity'], rec['dyeDensity'],
                                   reversal=True)
    rec['derived']['gammaNote'] = 'Reversal: gamma is the magnitude of the (negative) slope.'
    rec['extraction'] = {'method': 'vector', 'tool': 'research/film-data/extract.py',
                         'notes': 'All four p6 charts are vector paths (1996 Distiller PDF); sampled from path '
                                  'geometry. Axes from frame edges and grid lines (bar-notation labels).',
                         'confidence': 'high (geometry); medium for R/G/B identity in the toe, where the black '
                                       'curves merge', 'checks': []}
    return rec


@stock
def fuji_eterna_vivid_250d():
    slug, key = 'fuji-eterna-vivid-250d', 'eternav250d'
    doc_ = SOURCES[key]['document']
    stop = math.log10(2)
    # Page is stored rotated 90°; page_drawings/_number_spans map it upright. x labels are camera stops; the
    # negative labels are not extractable as text, so x is taken from the 1-stop grid lines.
    ch = vchart(key, 1, (234.1, 73.1, 382.5, 179.8),
                lambda cs, xa, ya: by_order_at(cs, xa, ya, lo_x(cs, xa) + 0.05, ['blue', 'green', 'red']),
                0.05, slug + '-characteristic', f'{doc_} characteristic curves (x in log H = stops x 0.301)',
                min_width=60,
                xaxis=axis_from_pairs([(244.7 + i * (371.9 - 244.7) / 12, (i - 6) * stop) for i in range(13)],
                                      name='logH'),
                yaxis=axis_from_pairs([(179.8, 0.0), (162.0, 0.5), (144.2, 1.0), (126.4, 1.5), (108.7, 2.0),
                                       (90.9, 2.5), (73.1, 3.0)], name='D'))
    se = vchart(key, 1, (234.5, 291.3, 382.2, 373.6), lambda cs, xa, ya: by_peak(cs, xa, ya, BANDS_RGB),
                5, slug + '-sensitivity', f'{doc_} spectral sensitivity (relative log)', max_width_frac=0.8,
                min_width=10,
                xaxis=axis_from_pairs([(243.1, 400), (286.3, 500), (330.0, 600), (373.4, 700)], name='nm'),
                yaxis=axis_from_pairs([(373.6, 0.0), (346.2, 1.0), (318.9, 2.0), (291.3, 3.0)], name='rel log S'))
    dy = vchart(key, 1, (49.6, 73.2, 169.0, 227.5),
                lambda cs, xa, ya: {('minimum' if dash_key(c) != 'solid' else 'midscaleNeutral'): c['polys']
                                    for c in cs},
                5, slug + '-dye-density', f'{doc_} spectral density (mid-scale neutral, minimum)',
                xaxis=axis_from_pairs([(49.6, 400), (88.7, 500), (128.9, 600), (169.0, 700)], name='nm'),
                yaxis=axis_from_pairs([(227.5, 0.0), (189.2, 0.5), (150.6, 1.0), (112.1, 1.5), (73.2, 2.0)],
                                      name='D'))
    mt = vchart(key, 1, (49.6, 291.6, 169.4, 373.9), lambda cs, xa, ya: {'neutral': cs[0]['polys']},
                'mtf', slug + '-ctf', f'{doc_} contrast transfer function', nd=1, max_width_frac=0.9,
                xaxis=axis_from_pairs([(49.6, 1), (67.7, 2), (91.5, 5), (109.9, 10), (127.8, 20), (138.3, 30),
                                       (145.9, 40), (152.1, 50), (169.4, 100)], log=True, name='c/mm'),
                yaxis=axis_from_pairs([(295.1, 100), (313.8, 50), (327.1, 30), (337.9, 20), (355.8, 10)],
                                      log=True, name='%'))
    rec = base_record(slug, 'FUJICOLOR NEGATIVE FILM ETERNA Vivid 250D (Type 8546 / 8646)', 'FUJIFILM Corporation',
                      'negative', 'ECN-2', 250, key, [1, 2])
    rec['characteristicCurves'] = {
        'densityType': 'status-M', 'exposure': '5400 K light source, 1/50 s, through a Fuji SC-41 UV filter',
        'process': 'ECN-2 (specified standard conditions)', 'logExposureUnits': REL_LOGH,
        'logExposure': ch['x'], **ch['ys'],
        'dMin': {c: ch['ys'][c][0] for c in ('red', 'green', 'blue')},
        'notes': 'The x axis is labelled in camera stops (-6..+6) relative to normal exposure, not in lux-seconds; '
                 'converted here to log exposure at 0.30103 per stop (0 = normal exposure, no absolute origin). '
                 'Status M densities including the orange mask; dMin = density at the lowest plotted exposure.'}
    rec['spectralSensitivity'] = {
        'units': 'relative log10 spectral sensitivity (0-3 as labelled; arbitrary origin); sensitivity = '
                 'reciprocal of the exposure (erg/cm^2) required to produce the stated density',
        'densityCriterion': '0.40 above minimum density (arbitrary three-colour densities)',
        'process': 'ECN-2', 'wavelength': se['x'], **se['ys'],
        'notes': 'Curves end where the published curves end.'}
    rec['dyeDensity'] = {
        'units': 'spectral density', 'wavelength': dy['x'], 'cyan': None, 'magenta': None, 'yellow': None,
        'minimum': dy['ys']['minimum'], 'midscaleNeutral': dy['ys']['midscaleNeutral'],
        'notes': 'Only "typical densities for a mid-scale neutral subject" (solid) and "minimum densities" (dashed) '
                 'are published; per-dye curves are not, so cyan/magenta/yellow are null.'}
    rec['granularity'] = {'rmsDiffuse': 3.5, 'printGrainIndex': None,
                          'notes': 'RMS granularity 3.5: 1000x the value measured at a visual diffuse density of 1.0 '
                                   'above minimum density with a 48 µm aperture (same scale as Fujifilm still '
                                   'negative sheets).'}
    rec['mtf'] = {'units': 'percent response (contrast transfer function, square-wave)', 'frequencyUnits': 'cycles/mm',
                  'process': 'ECN-2', 'frequency': mt['x'], 'neutral': mt['ys']['neutral'],
                  'notes': 'Published as a contrast transfer function: "spatial frequency attenuation characteristic '
                           'of amplitude relative to rectangular wave chart", normalised to zero frequency, at a '
                           'visual diffuse density of 1.1. This is a square-wave response, not a sine-wave MTF '
                           '(CTF exceeds MTF at mid frequencies); convert before mixing with MTF data.'}
    rec['interlayer'] = ('Fujifilm cites "Super-Efficient DIR-Coupler Technology" for colour separation; no interimage '
                         'data are published.')
    rec['notes'] = [
        'DISCONTINUED (Fujifilm ended motion-picture camera film production in 2013). Datasheet fetched from an '
        'Internet Archive capture (2012-02-16) of Fujifilm\'s own URL. ETERNA 250D (non-Vivid) was also sought; '
        'its only archived capture is a truncated PDF.',
        'Daylight balanced. EI 250 daylight, metal halide (HMI), ordinary fluorescent (white and daylight types) and '
        'three-band daylight fluorescent (5000 K), no filter; EI 64 under 3200 K tungsten with Kodak Daylight '
        'Filter No. 80A.',
        'Reciprocity: no correction from 1/1000 s to 1/10 s; at 1 s open 1/3 stop.',
        'Described as the highest-contrast film of the ETERNA colour negative series, with high saturation, '
        '"optimised orange mask density" for scanning, and designed to intercut with ETERNA Vivid 500.',
        'Base: triacetate, tinted light cyan (anti-light-piping). Process ECN-2 (persulfate, ferricyanide or '
        'PDTA-ferric bleach). Edge code FN46 / "FUJI V250".']
    rec['derived'] = derived_block(rec['characteristicCurves'], rec['spectralSensitivity'])
    rec['derived']['gammaNote'] = 'Gamma per log10 exposure (stops converted at 0.30103 log units per stop).'
    rec['extraction'] = {'method': 'vector', 'tool': 'research/film-data/extract.py',
                         'notes': 'All four p1 charts are vector paths on a page stored rotated 90°; coordinates are '
                                  'mapped through the page rotation matrix. Axes from grid lines.',
                         'confidence': 'high (characteristic, dye, CTF geometry); medium for sensitivity (relative '
                                       'scale)', 'checks': []}
    return rec


REL_LOGH = 'relative log exposure (arbitrary origin, as labelled on the chart)'


@stock
def ilford_hp5_plus():
    slug, key = 'ilford-hp5-plus', 'hp5'
    ident = lambda f: f
    k = dict(pred=DARK, grid_halfwidth=2, line_frac=0.3, half=1)
    ch = raster_chart(key, 5, 18, ('v', ident, (0.0, 4.5, 0.5), False), ('h', ident, (3.0, 0.0, 0.5), False),
                      {'neutral': (3.0, 1.49)}, 0.05, slug + '-characteristic', 'HP5 Plus p5 characteristic curve',
                      lo=0.0, hi=4.3, track_kw=LOWRES, **k)
    # x: centres of the wavelength labels (no tick marks); "400" merges with the axis title and is not used
    wa = L_([115.65, 144.35, 171.8, 199.75, 227.5], [450, 500, 550, 600, 650], name='nm')
    sa = L_([605.76, 633.12], [1.0, 0.5], name='S')      # tick marks right of the frame
    se = raster_chart(key, 1, 55, wa, sa, {'neutral': (450, 0.83)}, 5, slug + '-sensitivity',
                      'HP5 Plus p1 spectral sensitivity', lo=350, hi=660, track_kw=LOWRES, **k)
    rec = base_record(slug, 'ILFORD HP5 PLUS', 'HARMAN technology Ltd (ILFORD PHOTO)', 'bw-negative',
                      'ILFORD ILFOTEC HC (1+31), 6½ min at 20°C/68°F, intermittent agitation (curve); many developers '
                      'per datasheet', 400, key, [1, 5])
    rec['characteristicCurves'] = {
        'densityType': None, 'logExposureUnits': REL_LOGH, 'exposure': None,
        'condition': 'ILFORD ILFOTEC HC (1+31) stock, 6½ min at 20°C/68°F, intermittent agitation',
        'logExposure': ch['x'], 'neutral': ch['ys']['neutral'],
        'dMin': next(v for v in ch['ys']['neutral'] if v is not None), 'variants': [],
        'notes': 'Single published curve, "also representative of roll film and sheet film formats". The x axis is '
                 'relative log exposure 0-4.5 with no absolute origin, so the curve cannot be placed against '
                 'lux-seconds from this datasheet. Density type and exposure illuminant are not stated. dMin = '
                 'base + fog at the lowest plotted exposure.'}
    rec['spectralSensitivity'] = {
        'units': 'relative sensitivity as labelled (ticks 0.5 and 1.0; zero at the chart floor)',
        'densityCriterion': None, 'exposure': 'wedge spectrogram to tungsten light (2850 K)',
        'wavelength': se['x'], 'neutral': se['ys']['neutral'],
        'notes': 'Ilford publishes a wedge-spectrogram outline with a "Sensitivity" axis marked 0.5 and 1.0 and does '
                 'not say whether the scale is linear or logarithmic (a wedge spectrogram\'s height is '
                 'proportional to log sensitivity). Values are read on the printed scale. No density criterion '
                 'is given. x calibrated on the centres of the wavelength labels (no tick marks drawn).'}
    rec['dyeDensity'] = None
    rec['granularity'] = {'rmsDiffuse': None, 'printGrainIndex': None,
                          'notes': 'No granularity figure is published in the HP5 Plus datasheet (Nov 2018).'}
    rec['mtf'] = None
    rec['interlayer'] = None
    rec['notes'] = ['ISO 400/27°. Rated EI 400; Ilford gives meter settings from EI 400/27 to EI 3200/36 with '
                    'extended development (not foot-speed based).',
                    'No MTF, resolving power or granularity data are published (mtf and granularity null).',
                    '35 mm on 0.125 mm acetate base; roll film on 0.110 mm clear acetate with anti-halation backing '
                    'that clears in development; sheet film on 0.180 mm polyester base with anti-halation backing.']
    rec['derived'] = derived_block(rec['characteristicCurves'], rec['spectralSensitivity'])
    rec['extraction'] = {'method': 'raster', 'tool': 'research/film-data/extract.py',
                         'notes': 'Both charts are embedded ~2.1-2.4 px/pt bitmaps. Characteristic axes from the '
                                  'grid lines (0.5 log E, 0.5 D, checked against the 1/2/3/4 and 1.0/2.0 labels).',
                         'confidence': 'medium (characteristic), medium-low (sensitivity: scale type unstated)',
                         'checks': []}
    return rec


def wedge_axes(key, pno, xref, labels=(400, 450, 500, 550, 600, 650)):
    """Axes of an Ilford wedge-spectrogram bitmap: x from the centres of the wavelength labels under the
    frame (no tick marks are drawn; label glyph groups are split where the gap exceeds 4 pt), y from the
    1.0 / 0.5 tick marks right of the frame."""
    r = Raster.image(key, pno, xref)
    m = r.mask(DARK)
    h, v = r.lines(m, 'h', 0.5), r.lines(m, 'v', 0.3)
    yb, xr = max(h), max(v)
    a, b = int(r.to_px(0, yb + 1.5)[1]), min(r.h, int(r.to_px(0, yb + 10)[1]))
    groups, last = [], -99
    for c in range(r.w):
        if any(m[y][c] for y in range(a, b)):
            if c - last > 4 * r.sx:
                groups.append([c])
            else:
                groups[-1].append(c)
            last = c
    cent = [r.to_page((g[0] + g[-1]) / 2, 0)[0] for g in groups]
    assert len(cent) == len(labels), (key, cent)
    ticks = tick_marks(r, m, 'y', (xr + 0.6, xr + 3.0))
    assert len(ticks) == 2, (key, ticks)
    return L_(cent, list(labels), name='nm'), L_(ticks, [1.0, 0.5], name='S'), r.rect


ILFORD_SENS_NOTE = ('Ilford publishes a wedge-spectrogram outline with a "Sensitivity" axis marked 0.5 and 1.0 and does '
                    'not say whether the scale is linear or logarithmic (a wedge spectrogram\'s height is '
                    'proportional to log sensitivity). Values are read on the printed scale (the chart floor is '
                    '≈0). No density criterion is given. x calibrated on the centres of the wavelength labels (no '
                    'tick marks drawn).')


def ilford_film(slug, key, name, ei, pages, sens_xref, char, notes, sens_seed, extra=None, iso_note=None):
    """ILFORD B&W film: wedge spectrogram on p1 + characteristic-curve bitmap(s).
    char: [(pno, xref, {name: (x, y) seed}, condition, developer, times or None)]."""
    k = dict(pred=DARK, grid_halfwidth=2, line_frac=0.5, half=1)
    ident = lambda f: f
    variants, checks, prim = [], [], None
    for pno, xref, seeds, cond, dev, times in char:
        tag = '' if len(char) == 1 else '-' + dev.split()[1].lower()
        ch = raster_chart(key, pno, xref, ('v', ident, (0.0, 4.5, 0.5), False), ('h', ident, (3.0, 0.0, 0.5), False),
                          seeds, 0.05, f'{slug}-characteristic{tag}', f'{SOURCES[key]["document"][:20]} p{pno} '
                          f'characteristic {dev}', lo=0.02, hi=(extra or {}).get('hi', 4.45), track_kw=LOWRES, **k)
        for n in seeds:
            if '+' in n:
                continue
            v = {'developer': dev, 'condition': cond, 'timeMin': times[n] if times else None,
                 'logExposure': [x for x, y in zip(ch['x'], ch['ys'][n]) if y is not None],
                 'neutral': [y for y in ch['ys'][n] if y is not None]}
            v['gamma'] = round(gamma_fit(v['logExposure'], v['neutral']), 3)
            variants.append(v)
    wa, sa, _ = wedge_axes(key, 1, sens_xref)
    se = raster_chart(key, 1, sens_xref, wa, sa, {'neutral': sens_seed}, 5, slug + '-sensitivity',
                      f'{SOURCES[key]["document"][:20]} p1 spectral sensitivity', lo=wa.val(wa.labels[0][0]) - 60,
                      hi=720, track_kw=LOWRES, **dict(k, line_frac=0.3))
    prim = variants[0] if len(variants) == 1 else extra['primary'](variants)
    rec = base_record(slug, name, 'HARMAN technology Ltd (ILFORD PHOTO)', 'bw-negative', prim['condition'], ei, key,
                      pages)
    rec['characteristicCurves'] = {
        'densityType': None, 'logExposureUnits': REL_LOGH, 'exposure': None, 'condition': prim['condition'],
        'logExposure': prim['logExposure'], 'neutral': prim['neutral'], 'dMin': prim['neutral'][0],
        'variants': [dict((kk, vv) for kk, vv in v.items() if kk != 'gamma') for v in variants] if len(variants) > 1 else [],
        'notes': 'x axis is relative log exposure 0-4.5 with no absolute origin, so the curve cannot be placed against '
                 'lux-seconds from this datasheet. Density type and exposure illuminant are not stated. dMin = '
                 'base + fog at the lowest plotted exposure. Grid: 0.5 log E x 0.5 D, checked against the 1-4 and '
                 '1.0 / 2.0 labels.' + (' ' + extra['char_note'] if extra and extra.get('char_note') else '')}
    rec['spectralSensitivity'] = {
        'units': 'relative sensitivity as labelled (ticks 0.5 and 1.0; zero at the chart floor)',
        'densityCriterion': None, 'exposure': f'wedge spectrogram to tungsten light ({extra.get("sens_k", 2850) if extra else 2850} K)',
        'wavelength': se['x'], 'neutral': se['ys']['neutral'], 'notes': ILFORD_SENS_NOTE}
    rec['dyeDensity'] = None
    rec['granularity'] = {'rmsDiffuse': None, 'printGrainIndex': None,
                          'notes': 'No granularity figure is published in this datasheet.'}
    rec['mtf'] = None
    rec['interlayer'] = None
    if extra and extra.get('contrastVsTime'):
        rec['contrastVsDevelopmentTime'] = extra['contrastVsTime']
    rec['notes'] = list(notes) + ['No MTF, resolving power or granularity data are published (mtf and granularity '
                                  'null).']
    rec['derived'] = derived_block(rec['characteristicCurves'], rec['spectralSensitivity'])
    if len(variants) > 1:
        rec['derived']['gammaByVariant'] = {f"{v['developer']} {v['timeMin']} min": v['gamma'] for v in variants}
    rec['extraction'] = {'method': 'raster', 'tool': 'research/film-data/extract.py',
                         'notes': 'Embedded bitmaps (~1.8-4.9 px/pt). Characteristic axes from the grid lines; '
                                  'spectrogram x from the wavelength-label centres and y from the two tick marks.',
                         'confidence': 'medium (characteristic), medium-low (sensitivity: scale type unstated)',
                         'checks': checks}
    return rec


def ilford_bw_notes(iso, eis, recip, base, curve):
    return [iso + ' ' + eis, f'Reciprocity: {recip}', base, f'Characteristic curve: {curve}']


ILFORD_BASE = ('35 mm on 0.125 mm acetate base; roll film on 0.110 mm clear acetate with an anti-halation backing that '
               'clears in development; sheet film on 0.180 mm polyester base with anti-halation backing.')


@stock
def ilford_delta_100():
    return ilford_film(
        'ilford-delta-100', 'd100', 'ILFORD DELTA 100 PROFESSIONAL', 100, [1, 2, 3, 4], 16,
        [(4, 37, {'neutral': (3.9, 1.745)}, 'ILFORD ID-11 stock, 8½ min at 20°C/68°F, intermittent agitation '
          '(roll film; representative of 35 mm and sheet)', 'ILFORD ID-11', None)],
        ilford_bw_notes('ISO 100/21° daylight.', 'Best at EI 100/21; good results from EI 50/18 to EI 200/24 (EI range '
                        'from practical evaluation, not ISO foot speed). Development times are tabulated for EI 50, '
                        '100 and 200 (e.g. ID-11 stock 7 / 8½ / 10½ min, DD-X 1+4 8 / 10½ / 12½ min at 20°C).',
                        'none from 1/10,000 s to 1 s; longer metered times Tm need Ta = Tm^1.26 (seconds).',
                        ILFORD_BASE, 'ID-11 stock, 8½ min, 20°C.'),
        (500, 0.75))


@stock
def ilford_fp4_plus():
    return ilford_film(
        'ilford-fp4-plus', 'fp4', 'ILFORD FP4 PLUS', 125, [1, 2, 3, 5], 17,
        [(5, 38, {'neutral': (3.9, 1.86)}, 'ILFORD ILFOTEC HC (1+31), 8 min at 20°C/68°F, intermittent agitation '
          '(roll film; representative of 35 mm and sheet)', 'ILFORD ILFOTEC HC', None)],
        ilford_bw_notes('ISO 125/22° daylight (ID-11, 20°C, spiral tank).', 'Best at EI 125/22; good results from EI '
                        '50/18 to EI 200/24. Development times are tabulated for EI 50, 125 and 200 (e.g. ID-11 stock '
                        '6½ / 8½ / 10 min, DD-X 1+4 8 / 10 / 12 min at 20°C).',
                        'none from 1/2 s to 1/10,000 s; longer metered times Tm need Ta = Tm^1.26 (seconds).',
                        ILFORD_BASE, 'ILFOTEC HC (1+31), 8 min, 20°C.'),
        (500, 0.62))


@stock
def ilford_pan_f_plus():
    return ilford_film(
        'ilford-pan-f-plus', 'panf', 'ILFORD PAN F PLUS', 50, [1, 2, 3, 4], 32,
        [(4, 48, {'neutral': (3.9, 1.622)}, 'ILFORD ILFOTEC HC (1+31), 4 min at 20°C/68°F, intermittent agitation '
          '(roll film; representative of 35 mm)', 'ILFORD ILFOTEC HC', None)],
        ilford_bw_notes('ISO 50/18° daylight (ID-11, 20°C, spiral tank).', 'Best at EI 50/18; good results at EI 25/15. '
                        'Development times are tabulated for EI 25, 50 and 64 (e.g. ID-11 stock 4½ / 6½ min, DD-X 1+4 '
                        '7 / 8 min at 20°C); accidental exposure at EI 100-200+ is covered only by a rescue table.',
                        'none from 1/2 s to 1/10,000 s; longer metered times Tm need Ta = Tm^1.33 (seconds).',
                        ILFORD_BASE.replace('; sheet film', '; large-format sheet film'),
                        'ILFOTEC HC (1+31), 4 min, 20°C.') +
        ['Ilford recommends processing PAN F Plus within 3 months of exposure (latent-image stability).'],
        (500, 0.65))


@stock
def ilford_delta_3200():
    slug, key = 'ilford-delta-3200', 'd3200'
    times = {'t16': 16, 't12': 12, 't9': 9, 't7': 7}
    dd = {'t16': (3.9, 2.378), 't12': (3.9, 2.22), 't9': (3.9, 1.951), 't7': (3.9, 1.756)}
    mi = {'t16': (3.9, 2.384), 't12': (3.9, 2.208), 't9': (2.25, 1.40), 't7': (3.9, 1.866)}
    k = dict(pred=DARK, grid_halfwidth=2, line_frac=0.5, half=1, track_kw=LOWRES)
    ident = lambda f: f
    cvt = {}
    for xref, dev, xv, seed in ((45, 'ILFORD ILFOTEC DD-X 1+4', (3, 30, 3), (13.5, 0.78)),
                                (46, 'ILFORD MICROPHEN stock', (0, 18, 2), (14.0, 0.775))):
        c = raster_chart(key, 5, xref, ('v', ident, xv, False), ('h', ident, (1.2, 0.0, 0.2), False),
                         {'contrast': seed}, 0.5, f'{slug}-contrast-time-{dev.split()[1].lower()}',
                         f'DELTA 3200 p5 contrast vs time {dev}', lo=xv[0] + 0.05, hi=xv[1] - 0.05, nd=3, **k)
        cvt[dev] = {'timeMin': [x for x, y in zip(c['x'], c['ys']['contrast']) if y is not None],
                    'contrastGbar': [y for y in c['ys']['contrast'] if y is not None]}
    contrast = {'units': 'Ilford average gradient G-bar (contrast) vs development time in minutes at 20°C/68°F',
                'series': cvt,
                'notes': 'From the "CONTRAST – TIME GRAPHS" (p5). G-bar is Ilford\'s average-gradient contrast; its '
                         'exact definition (density interval) is not given in the datasheet.'}
    pick = lambda vs: next(v for v in vs if 'DD-X' in v['developer'] and v['timeMin'] == 9)
    return ilford_film(
        slug, key, 'ILFORD DELTA 3200 PROFESSIONAL', 3200, [1, 2, 3, 4, 5, 6], 23,
        [(5, 47, dd, 'ILFORD ILFOTEC DD-X 1+4, 20°C/68°F', 'ILFORD ILFOTEC DD-X 1+4', times),
         (5, 48, mi, 'ILFORD MICROPHEN stock, 20°C/68°F', 'ILFORD MICROPHEN stock', times)],
        ['Nominal ISO speed 1000/31° daylight (ID-11, 20°C, spiral tank); designed to be exposed at EI 3200/36 with '
         'extended development. Good results from EI 400/27 to EI 6400/39 (recommended range EI 1600-6400); usable '
         'up to EI 25000/45 with tests. exposureIndex is the recommended meter setting (3200), not the ISO speed.',
         'Push/pull is by development time: e.g. ILFOTEC DD-X 1+4 at 20°C: EI 400 6 min, 800 7, 1600 8, 3200 9½, '
         '6400 12½, 12500 17 min; EI 25000: DD-X 25 min / MICROPHEN 22 min at 20°C.',
         'Reciprocity: none from 1/2 s to 1/10,000 s; longer metered times Tm need Ta = Tm^1.33 (seconds).',
         '35 mm on 0.125 mm acetate base; 120 roll film. Very fast film: Ilford advises against airport x-ray '
         'scanners.',
         'Characteristic variants: DD-X 1+4 and MICROPHEN stock, each 7 / 9 / 12 / 16 min at 20°C. The primary '
         'curve is DD-X 9 min (nearest the EI 3200 time of 9½ min).',
         'contrastVsDevelopmentTime: G-bar vs development time for DD-X 1+4 and MICROPHEN (p5).'],
        (500, 0.83), extra={'primary': pick, 'contrastVsTime': contrast, 'sens_k': 2856, 'hi': 4.25,
                            'char_note': 'The four curves of each chart merge below relative log E ≈ 0.8 (toe); the '
                                         'traced values there are a shared centreline (±0.03 D). Traces stop at '
                                         'relative log E 4.25, where the time labels are printed over the curve ends.'})


MG_FILTERS = ['00', '0', '1', '2', '3', '4', '5']


@stock
def ilford_multigrade_rc():
    slug, key = 'ilford-multigrade-rc', 'mgrc'
    k = dict(pred=DARK, grid_halfwidth=2, line_frac=0.3, half=1, clip_frame=False)
    # "NEW - MULTIGRADE RC DELUXE & PORTFOLIO" (p3, bottom row): filters 00-3 left, 4-5 right. The lowest
    # detected horizontal line is the paper-base floor of the curves (~D 0.05), not a grid line.
    xa = L_([80.5, 103.3, 126.2, 149.0, 171.9, 194.7, 217.5, 240.4, 263.0], [0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5])
    ya = L_([596.3, 620.0, 643.7, 667.5, 690.9], [2.5, 2.0, 1.5, 1.0, 0.5])
    # The rising parts are steep, so they are followed row by row (transposed) between D 0.1 and 2.02; the
    # flat floor (~0.05) and plateau (~2.07), common to all filters, come from one ordinary trace.
    def mg_chart(xref, xax, yax, seeds, floor, tag, title):
        lo_d, hi_d = 0.1, 2.05
        base = raster_chart(key, 3, xref, xax, yax, {'base': seeds['base']}, 0.05, tag, title, lo=0.02, hi=4.3,
                            track_kw=LOWRES, drop_lines=[('h', floor)], **k)
        mid = raster_chart(key, 3, xref, xax, yax, {g: s for g, s in seeds.items() if g != 'base'}, 0.05, tag,
                           title, lo=lo_d, hi=hi_d, xs=base['x'], transpose=True,
                           track_kw=dict(LOWRES, gap_pt=16.0, seed_gap=2, seed_slope=0.8),
                           drop_lines=[('h', floor)], **k)
        xs = base['x']
        ends = {}
        for g, v in mid['ys'].items():
            i1 = max(i for i, y in enumerate(v) if y is not None)
            ends[g] = (xs[i1], v[i1])
        # shoulders: ordinary traces from the end of each steep part into the common plateau
        sh = raster_chart(key, 3, xref, xax, yax, ends, 0.05, tag, title, lo={g: e[0] for g, e in ends.items()},
                          hi=4.3, xs=xs, track_kw=LOWRES, drop_lines=[('h', floor)], **k)
        out = {}
        for g, v in mid['ys'].items():
            idx = [i for i, y in enumerate(v) if y is not None]
            i0, i1 = idx[0], idx[-1]
            out[g] = [v[i] if v[i] is not None else
                      sh['ys'][g][i] if i > i1 and sh['ys'][g][i] is not None else
                      (b if b is not None and ((i < i0 and b <= lo_d + 0.03) or (i > i1 and b >= hi_d - 0.03))
                       else None) for i, b in enumerate(base['ys']['base'])]
        overlay(key, 3, Raster.image(key, 3, xref).rect, xax, yax, [(g, base['x'], v) for g, v in out.items()],
                tag, title)
        return base['x'], out

    # at D = 1.2 the five curves are separate; left to right = filters 3, 2, 1, 0, 00 (chart labels "3" .. "00")
    at12 = {'3': 2.307, '2': 2.377, '1': 2.45, '0': 2.551, '00': 2.636}
    lx, lf = mg_chart(11, xa, ya, {'base': (2.636, 1.2), **{g: (x, 1.2) for g, x in at12.items()}}, 0.047,
                      slug + '-characteristic-00-3', 'MULTIGRADE RC p3 (new Deluxe) filters 00-3')
    xb = L_([348.6, 393.6, 438.7, 483.7, 506.0], [1, 2, 3, 4, 4.5])
    yb = L_([619.3, 642.6, 665.9, 689.8], [2.0, 1.5, 1.0, 0.5])
    rx, rt = mg_chart(12, xb, yb, {'base': (2.354, 0.6), 'a': (2.309, 0.6), 'b': (2.354, 0.6)}, 0.064,
                      slug + '-characteristic-4-5', 'MULTIGRADE RC p3 (new Deluxe) filters 4-5')
    # filters 4 and 5 are labelled only by small numbers at the toe; the steeper curve is taken as filter 5
    ga, gb = (gamma_fit(rx, rt[n]) for n in ('a', 'b'))
    rt_names = {'a': '5', 'b': '4'} if ga > gb else {'a': '4', 'b': '5'}
    curves = {g: (lx, lf[g]) for g in at12}
    curves.update({rt_names[n]: (rx, rt[n]) for n in ('a', 'b')})
    iso_r = {'00': 160, '0': 130, '1': 110, '2': 90, '3': 70, '4': 60, '5': 50}
    iso_p = {'00': 240, '0': 240, '1': 240, '2': 240, '3': 240, '4': 220, '5': 220}
    variants = [{'filter': g, 'isoRange': iso_r[g], 'isoSpeedP': iso_p[g],
                 'logExposure': [x for x, y in zip(*curves[g]) if y is not None],
                 'neutral': [y for y in curves[g][1] if y is not None]} for g in MG_FILTERS]
    gammas = {g: round(gamma_fit(*curves[g]), 3) for g in MG_FILTERS}
    order_ok = all(gammas[a] < gammas[b] for a, b in zip(MG_FILTERS[:5], MG_FILTERS[1:5]))
    # spectral sensitivity (p1): no y scale is printed
    ws = L_([387.85, 417.5, 446.9, 476.55, 505.95], [450, 500, 550, 600, 650], name='nm')
    hs = L_([725.7, 643.8], [0.0, 1.0], name='frac')
    se = raster_chart(key, 1, 812, ws, hs, {'neutral': (500, 0.347), 'neutral+r': (540, 0.22)}, 5,
                      slug + '-sensitivity', 'MULTIGRADE RC p1 spectral sensitivity',
                      lo={'neutral': 365, 'neutral+r': 527}, hi={'neutral': 526, 'neutral+r': 560}, track_kw=LOWRES,
                      **dict(k, clip_frame=True))
    top = max(v for v in se['ys']['neutral'] if v is not None)
    sens = [None if v is None else round(v / top, 3) for v in se['ys']['neutral']]
    prim = next(v for v in variants if v['filter'] == '2')
    rec = base_record(slug, 'ILFORD MULTIGRADE RC DELUXE / PORTFOLIO (new emulsion, 2020)',
                      'HARMAN technology Ltd (ILFORD PHOTO)', 'bw-paper',
                      'ILFORD MULTIGRADE developer 1+9, 1 min at 20°C/68°F', None, key, [1, 2, 3])
    rec['characteristicCurves'] = {
        'densityType': 'reflection (type not stated)', 'logExposureUnits': REL_LOGH,
        'exposure': 'through ILFORD MULTIGRADE filters 00-5',
        'condition': 'ILFORD MULTIGRADE developer 1+9, 1 min at 20°C/68°F',
        'logExposure': prim['logExposure'], 'neutral': prim['neutral'], 'dMin': prim['neutral'][0],
        'variants': variants,
        'notes': 'Primary curve: filter 2. Curves for the new MULTIGRADE RC DELUXE & PORTFOLIO emulsion (p3, bottom '
                 'row); filters 00-3 and 4-5 are on separate charts with the same relative log-exposure scale. '
                 'Filters 4 and 5 are distinguished only by small toe labels; the steeper curve is taken as '
                 'filter 5. Where the curves merge (the toe below D ≈ 0.6 for 00-3, the shoulder above D ≈ 1.9, '
                 'and most of 4 vs 5) the traced values are a shared centreline (±0.03 D). The flat floor '
                 '(paper base + fog, ~0.05) is common to all filters. isoRange / isoSpeedP are the ISO 6846 range '
                 '(R) and paper speed (P) figures from p2 for this emulsion (no filter: R 90, P 500).'}
    rec['spectralSensitivity'] = {
        'units': 'relative (no scale printed; normalised to peak = 1.0, chart floor = 0)',
        'densityCriterion': None, 'exposure': None, 'wavelength': se['x'], 'neutral': sens,
        'notes': '"ILFORD MULTIGRADE papers all have similar spectral sensitivity as shown in the chart" (p1). The '
                 'chart has no y-axis scale, so only the shape is meaningful and linear vs log is unknown. x '
                 'calibrated on the wavelength-label centres (no tick marks).'}
    rec['dyeDensity'] = None
    rec['granularity'] = None
    rec['mtf'] = None
    rec['interlayer'] = None
    rec['notes'] = ['Exposure index is not applicable (null); see the ISO paper speeds per filter in variants.',
                    'Ilford notes MULTIGRADE RC papers are roughly equivalent to film ISO 3-6.',
                    'Older emulsions on p3 (MULTIGRADE IV RC DELUXE, WARMTONE, COOLTONE) are not digitised.']
    rec['derived'] = derived_block(rec['characteristicCurves'], rec['spectralSensitivity'])
    rec['derived']['gammaByFilter'] = gammas
    rec['extraction'] = {'method': 'raster', 'tool': 'research/film-data/extract.py',
                         'notes': 'Embedded bitmaps at ~2.0-2.8 px/pt; axes from grid lines checked against the '
                                  '1.0/2.0 density labels and 1-4 exposure labels. The steep rising parts '
                                  '(D 0.1-2.05) were followed row by row (x as a function of D), the shoulders '
                                  'column by column from there, and the flat base and plateau (common to all '
                                  'filters) from one ordinary trace. In the toe (D 0.1-0.5) the curves fan out by '
                                  'only ~0.1 log E and the per-filter values there are uncertain by ±0.05 log E.',
                         'confidence': 'medium (filters 00-3 away from the merged toe/shoulder), low (4 vs 5, '
                                       'sensitivity)',
                         'checks': [f'gamma increases monotonically from filter 00 to 3: {order_ok}',
                                    f'filters 4/5 assigned by slope: {rt_names}']}
    return rec


if __name__ == '__main__':
    main(sys.argv[1:])
