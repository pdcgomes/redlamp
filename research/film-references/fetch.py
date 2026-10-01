"""Collects photographs shot on the film stocks Redlamp models, to check the looks' colour against.

Wikimedia Commons only, and only files licensed CC0, public domain, CC BY or CC BY-SA whose
page states the stock: a category named after it ("Taken on Ilford HP5 plus 400") or the
title or description ("Shot on Portra 400"). Pages naming a second stock, or describing
cross-processing, expired film, redscale, pushing, toy cameras, filters or digital edits,
are skipped, and so are photos of the film itself. The images are references only: they live
in build/film-references/ (gitignored) and are never shipped or committed (the DEC-17 policy).
One request a second, resumable, and the fetcher stops at the first refusal.

    python3 research/film-references/fetch.py                     # downloads what manifest.json lists but is missing
    python3 research/film-references/fetch.py discover            # re-queries Commons and tops each stock up
    python3 research/film-references/fetch.py discover --stock kodak-portra-400 --refresh --dry-run
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import re
import struct
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = Path(__file__).resolve().parent / "manifest.json"
OUT = ROOT / "build" / "film-references"
CACHE = OUT / ".cache"
API = "https://commons.wikimedia.org/w/api.php"
UA = "RedlampFilmReferences/1.0 (https://github.com/pdcgomes/redlamp; research; contact via repository)"
PAUSE = 1.0
TARGET = 20
OPTIONAL_TARGET = 12
MINIMUM = 8
PER_AUTHOR = 4
MIN_EDGE = 1000
SEARCH_LIMIT = 500


@dataclass
class Stock:
    name: str
    # What the title or description must say. Matching it is the evidence for the stock.
    pattern: str
    # Categories named after the stock: membership is the evidence.
    categories: list[str] = field(default_factory=list)
    # Categories for a family of stocks (all Portras, all Velvias): searched, but the page must name the stock.
    family: list[str] = field(default_factory=list)
    searches: list[str] = field(default_factory=list)
    # The page must also mention this, for names that mean other things too ("Delta 100").
    requires: str = ""
    # Older, different emulsions sold under the same name before this year.
    since: int = 0
    colour: bool = True
    optional: bool = False
    # Weaker evidence: the page names the product line but not the speed (Tri-X is only sold as 400 in 35 mm).
    loose: str = ""
    # Close relatives a page may name without making the stock ambiguous (CineStill 800T is Vision3 500T).
    related: tuple[str, ...] = ()
    # Different products sharing the name.
    excludes: str = ""


STOCKS: dict[str, Stock] = {
    "kodak-portra-400": Stock(
        "Kodak Portra 400", r"portra[\s_-]*400(?!\d)(?![\s_-]*(?:nc|vc|uc|bw)\b)",
        categories=["Photographs taken on Kodak Portra 400"], family=["Photographs taken on Kodak Portra films"],
        searches=['"Portra 400"', "Portra400"], since=2010),
    "kodak-portra-160": Stock(
        "Kodak Portra 160", r"portra[\s_-]*160(?!\d)(?![\s_-]*(?:nc|vc)\b)",
        categories=["Photographs taken on Kodak Portra 160"], family=["Photographs taken on Kodak Portra films"],
        searches=['"Portra 160"', "Portra160"], since=2011),
    "kodak-portra-800": Stock(
        "Kodak Portra 800", r"portra[\s_-]*800(?!\d)",
        categories=["Photographs by Artem Svetlov/2022-05 Kodak Portra800"],
        family=["Photographs taken on Kodak Portra films"], searches=['"Portra 800"', "Portra800"]),
    "kodak-ektar-100": Stock(
        "Kodak Ektar 100", r"ektar[\s_-]*100(?!\d)",
        categories=["Photographs taken on Kodak Ektar 100 film", "Photographs by Artem Svetlov/2020-03-08 KodakEktar100",
                    "Photographs by Artem Svetlov/2021-05-01 KodakEktar100"],
        searches=['"Ektar 100"', "Ektar100"], since=2008),
    "kodak-gold-200": Stock(
        "Kodak Gold 200", r"\bgold[\s_-]*200(?!\d)", requires=r"kodak",
        categories=["Photographs taken on Kodak Gold 200 film", "Photographs by Artem Svetlov/2024-03-10 Kodak Gold 200"],
        searches=['"Kodak Gold 200"']),
    "kodak-ultramax-400": Stock(
        "Kodak UltraMax 400", r"ultra[\s_-]*max[\s_-]*400(?!\d)",
        categories=["Photographs taken on Kodak UltraMax 400 film"], searches=['"UltraMax 400"', '"Ultra Max 400"']),
    "fuji-superia-xtra-400": Stock(
        "Fujifilm Superia X-TRA 400", r"\bx[\s_-]?tra[\s_-]*400(?!\d)",
        categories=["Taken on Fuji Superia X-TRA 400"], searches=['"Superia X-TRA 400"', '"Superia Xtra 400"']),
    "fuji-pro-400h": Stock(
        "Fujifilm Pro 400H", r"\bpro[\s_-]*400[\s_-]*h\b|\bfuji(?:film|color)?[\s_-]*400[\s_-]*h\b",
        searches=['"Pro 400H"', "Pro400H", '"Fuji 400H"'], since=2004),
    "cinestill-800t": Stock(
        "CineStill 800T", r"cine[\s_-]*still[\s_-]*800",
        searches=['"CineStill 800T"', '"Cinestill 800"', "Cinestill800T"], since=2012,
        related=("kodak-vision3-500t",)),
    "cinestill-50d": Stock(
        "CineStill 50D", r"cine[\s_-]*still[\s_-]*50[\s_-]*d",
        searches=['"CineStill 50D"', "Cinestill50D"], since=2014, related=("kodak-vision3-50d",)),
    "fuji-provia-100f": Stock(
        "Fujifilm Provia 100F", r"provia[\s_-]*100[\s_-]*f\b|\brdp[\s_-]*(?:iii|3)\b",
        categories=["Taken on Fuji Provia 100F"], searches=['"Provia 100F"', '"RDP III"'], since=2000),
    "fuji-velvia-50": Stock(
        "Fujifilm Velvia 50", r"velvia[\s_-]*50(?!\d)|\brvp[\s_-]*50(?!\d)",
        family=["Taken on Fuji Velvia"], searches=['"Velvia 50"', "Velvia50", "RVP50", '"RVP 50"']),
    "fuji-velvia-100": Stock(
        "Fujifilm Velvia 100", r"velvia[\s_-]*100(?![\s_-]*f\b)(?!\d)|\brvp[\s_-]*100(?![\s_-]*f\b)(?!\d)",
        family=["Taken on Fuji Velvia"], searches=['"Velvia 100"', "Velvia100", "RVP100"], since=2003),
    # "Ektachrome 100" alone isn't enough: older Ektachrome 100 emulsions are still shot expired.
    "kodak-ektachrome-e100": Stock(
        "Kodak Ektachrome E100", r"\be[\s_-]?100\b(?![\s_-]*(?:g|s|sw|vs|gx)\b)", requires=r"ektachrome|kodak",
        searches=['"Ektachrome E100"', '"Kodak E100"'], since=2018),
    "kodak-kodachrome-64": Stock(
        "Kodachrome 64", r"kodachrome[\s_-]*64|\bkr[\s_-]?64\b|\bpkr[\s_-]*64\b",
        categories=["Photographs taken on Kodachrome 64 film"], family=["Photographs taken on Kodachrome film"],
        searches=['"Kodachrome 64"', "KR64"], since=1974),
    "kodak-tri-x-400": Stock(
        "Kodak Tri-X 400", r"tri[\s_-]?x[\s_-]*(?:pan[\s_-]*)?400|\b400[\s_-]?tx\b|\btx[\s_-]?400\b",
        loose=r"tri[\s_-]?x", family=["Photographs taken on Kodak TRI-X film"],
        searches=['"Tri-X 400"', "400TX", '"Tri-X Pan"'], colour=False,
        excludes=r"tri[\s_-]?x[\s_-]*(?:pan[\s_-]*)?(?:pro[\s_-]*)?320|\btxp\b|\b320[\s_-]?tx"),
    "kodak-t-max-100": Stock(
        "Kodak T-Max 100", r"\bt[\s_-]?max[\s_-]*100(?!\d)",
        categories=["Photographs taken on Kodak T-MAX 100 films"], searches=['"T-Max 100"', '"TMax 100"', "TMAX100"],
        since=1986, colour=False),
    "kodak-t-max-400": Stock(
        "Kodak T-Max 400", r"\bt[\s_-]?max[\s_-]*400(?!\d)",
        categories=["Photographs taken on Kodak T-MAX 400 films"], searches=['"T-Max 400"', '"TMax 400"', "TMAX400"],
        since=1986, colour=False),
    "ilford-hp5-plus": Stock(
        "Ilford HP5 Plus", r"\bhp[\s_-]?5[\s_-]*(?:plus|\+)",
        categories=["Taken on Ilford HP5 plus 400"], searches=['"HP5 Plus"', "HP5plus"], since=1989, colour=False),
    "ilford-delta-100": Stock(
        "Ilford Delta 100", r"\bdelta[\s_-]*100(?!\d)", requires=r"ilford",
        categories=["Taken on Ilford Delta 100"], searches=['"Delta 100" Ilford'], since=1992, colour=False),
    "ilford-delta-3200": Stock(
        "Ilford Delta 3200", r"\bdelta[\s_-]*3200", requires=r"ilford|film",
        categories=["Taken on Ilford Delta 3200"], searches=['"Delta 3200"'], since=1998, colour=False),
    "ilford-fp4-plus": Stock(
        "Ilford FP4 Plus", r"\bfp[\s_-]?4[\s_-]*(?:plus|\+)",
        categories=["Taken on Ilford FP4 plus"], family=["Taken on Ilford FP4"], searches=['"FP4 Plus"', "FP4plus"],
        since=1990, colour=False),
    "ilford-pan-f-plus": Stock(
        "Ilford Pan F Plus", r"\bpan[\s_-]?f[\s_-]*(?:plus|\+)",
        categories=["Photographs taken on Ilford PAN F plus"], searches=['"Pan F Plus"', '"Pan F"'], since=1992,
        colour=False),
    "kodak-vision3-50d": Stock(
        "Kodak Vision3 50D", r"vision[\s_-]*3[\s_-]*50[\s_-]*d",
        categories=["Photographs taken on Kodak Vision3 50D film", "Photographs by Artem Svetlov/2024-08-20 Kodak Vision 3 50D",
                    "Photographs by Artem Svetlov/2021-08-15 Kodak Vision 3 50D",
                    "Photographs by Artem Svetlov/2023-06 KodakVision3 50D"],
        searches=['"Vision3 50D"', '"Vision 3 50D"'], since=2010, optional=True),
    "kodak-vision3-250d": Stock(
        "Kodak Vision3 250D", r"vision[\s_-]*3[\s_-]*250[\s_-]*d",
        categories=["Photographs taken on Kodak Vision3 250D film",
                    "Photographs by Artem Svetlov/2021-03-06 KodakVision3 250D",
                    "Photographs by Artem Svetlov/2022-02 KodakVision3 250D",
                    "Photographs by Artem Svetlov/2021-08-24 KodakVision3 250D",
                    "Photographs by Artem Svetlov/2023-01 KodakVision3 250D",
                    "Photographs by Artem Svetlov/2024-03-30 Kodak Vision 3 250D",
                    "Photographs by Artem Svetlov/2024-05-19 Kodak Vision 3 250D"],
        searches=['"Vision3 250D"', '"Vision 3 250D"'], since=2007, optional=True),
    "kodak-vision3-500t": Stock(
        "Kodak Vision3 500T", r"vision[\s_-]*3[\s_-]*500[\s_-]*t",
        categories=["Photographs taken on Kodak Vision3 500T film"], searches=['"Vision3 500T"', '"Vision 3 500T"'],
        since=2007, optional=True),
}

# Files rejected after looking at them, with the reason.
EXCLUDE: dict[str, str] = {
    "File:10388 Haagsemarkt 2, Breda panorama Princenhage, Breda.jpg": "stitched collage, nearly monochrome",
    "File:Brick well in logatec, Slovenia.jpg": "box camera, strong magenta cast",
    "File:Insomnia (243776093).jpeg": "500px copy of File:Бессонница Insomnia (39892064491).jpg",
    "File:Lune nb.jpg": "the Moon: no colour to compare",
    "File:Cascata delle Marmore vista dal Penna Rossa.jpg": "long exposure at dusk through an ND filter",
    "File:ЗИЛ-4329 с308ам77 Москва.jpg": "strong magenta cast and yellow sky, not how E-6 E100 renders overcast light",
    "File:KodakEktachrome2018.jpg": "a photo of the film cassette",
    "File:ArcheryGermanyEarly1980s.jpg": "processed version of File:Image-ArcheryGermanyEarly1980s-OriginalScan.jpg",
    "File:Canon F-1 and Kodak Films.jpg": "a photo of the film boxes",
    "File:KodakTMax400.jpg": "a photo of the film box",
    "File:Zu 1998-07-02 Ilford HP5 Plus Uebersbach.jpg": "sepia-toned",
    "File:Fuji Gw690iii (222408623).jpeg": "a colour photo of a camera, shot on Kodak Vision 50D",
    "File:St. Anthony's Lighthouse (45446952952).jpg": "mottled, solarised-looking frame (a processing fault?)",
    "File:Дзвіниця, Контрактова площа 2-А.jpg": "strong purple cast from the negative's inversion",
    "File:Foal Flehmen.jpg": "warm-toned print scan",
    "File:Zu Opel Astra G Start ILFORD HP5 1998 bw.jpg": "sepia-toned",
}

# One photographer credited under several names.
AUTHOR_ALIASES = {"artyom svetlov": "artem svetlov", "trolleway": "artem svetlov",
                  "spoilt.exile": "nepochatov stanislav"}

# Films other than the stock that, named on the same page, make it ambiguous: (name, pattern, stocks it belongs to).
OTHER_FILMS = [
    ("Kodak Vision", r"\bvision[\s_-]*[23]?[\s_-]*(?:50|200|250|320|500)[\s_-]*[dt]\b",
     {"kodak-vision3-50d", "kodak-vision3-250d", "kodak-vision3-500t", "cinestill-800t", "cinestill-50d"}),
    # CineStill's films, not its developing kits (Cs41, CS6), which are ordinary C-41 and E-6 chemistry.
    ("CineStill", r"cine[\s_-]*still[\s_-]*(?:\d{2,3}[\s_-]*[dt]?\b|bw[\s_-]*xx|film|tungsten|daylight)",
     {"cinestill-800t", "cinestill-50d"}),
    ("Kodak Portra", r"portra(?!it)", {"kodak-portra-400", "kodak-portra-160", "kodak-portra-800"}),
    ("Kodak Ektar", r"ektar\b", {"kodak-ektar-100"}),
    ("Kodak Gold", r"kodak[\s_-]*gold", {"kodak-gold-200"}),
    ("Kodak UltraMax", r"ultra[\s_-]*max", {"kodak-ultramax-400"}),
    ("Fujifilm Superia", r"superia", {"fuji-superia-xtra-400"}),
    ("Fujifilm Provia", r"provia", {"fuji-provia-100f"}),
    ("Fujifilm Velvia", r"velvia", {"fuji-velvia-50", "fuji-velvia-100"}),
    ("Kodak Ektachrome", r"ektachrome|elite[\s_-]*chrome", {"kodak-ektachrome-e100"}),
    ("Kodachrome", r"kodachrome", {"kodak-kodachrome-64"}),
    ("Kodak Tri-X", r"\btri[\s_-]?x\b", {"kodak-tri-x-400"}),
    ("Kodak T-Max", r"\bt[\s_-]?max\b(?![\s_-]*(?:rs[\s_-]*)?(?:developer|dev)\b)", {"kodak-t-max-100", "kodak-t-max-400"}),
    ("Ilford HP5", r"\bhp[\s_-]?5(?!\d)", {"ilford-hp5-plus"}),
    ("Ilford FP4", r"\bfp[\s_-]?4(?!\d)", {"ilford-fp4-plus"}),
    ("Ilford Delta", r"ilford[\s_-]*delta", {"ilford-delta-100", "ilford-delta-3200"}),
    ("Ilford Pan F", r"\bpan[\s_-]?f\b(?!/)", {"ilford-pan-f-plus"}),
    ("another film", r"\bkodachrome[\s_-]*(?:25|40|200)\b|ektar[\s_-]*(?:25|125|1000)\b|portra[\s_-]*(?:160|400|800)"
                     r"[\s_-]*(?:nc|vc|uc)\b|portra[\s_-]*400[\s_-]*bw|kodak[\s_-]*gold[\s_-]*(?:100|400|800)\b|"
                     r"ultra[\s_-]*max[\s_-]*800|superia[\s_-]*(?:x[\s_-]?tra[\s_-]*)?(?:100|200|800|1600)\b|reala\b|"
                     r"provia[\s_-]*400|velvia[\s_-]*100[\s_-]*f\b|\bastia\b|\bsensia\b|\bpro[\s_-]*160|"
                     r"fujicolor[\s_-]*(?:c[\s_-]?)?200|"
                     r"\bc[\s_-]?200\b|colou?r[\s_-]*plus|pro[\s_-]*image|t[\s_-]?max[\s_-]*(?:p[\s_-]?)?3200|\bp3200\b|"
                     r"delta[\s_-]*400|\bxp[\s_-]?2\b|kentmere|fomapan|\bacros\b|neopan|\bsfx\b|ortho[\s_-]*plus|"
                     r"rollei[\s_-]*(?:retro|rpx|infrared|ortho|digibase|crossbird|vario|superpan)|agfapan|agfacolor|"
                     r"agfaphoto|agfa[\s_-]*(?:vista|apx|precisa|optima|ultra|scala|portrait|copex|isopan)|silberra|"
                     r"svema|свема|\btasma\b|тасма|\borwo\b|ferrania|\bcenturia\b|konica[\s_-]*(?:vx|impresa)", set()),
]

# Anything that changes how the film renders colour or tone, and photos of the film itself.
SKIP = re.compile("|".join([
    r"cross[\s_-]*process", r"\bx[\s_-]?pro(?:cess(?:ed)?)?\b(?![\s_-]*c[\s_-]*41)", r"red[\s_-]*scale", r"expired",
    r"outdated", r"out[\s_-]of[\s_-]date", r"infra[\s_-]?red", r"aerochrome", r"\bpush(?:ed|ing)?\b",
    r"\bpull(?:ed|ing)?\b", r"double[\s_-]*exposure", r"multiple[\s_-]*exposure", r"multi[\s_-]*exposure",
    r"light[\s_-]*leak", r"pinhole", r"holga", r"\bdiana[\s_-]*(?:f\b|\+|mini)", r"toy[\s_-]*camera",
    r"\blomo(?:graph\w*)?\b",
    r"lensbaby", r"\bhdr\b", r"tone[\s_-]*mapp", r"photoshop", r"lightroom", r"\bvsco\b", r"preset", r"instagram",
    r"colori[sz]", r"colouri[sz]", r"hand[\s_-]*colou?r", r"tint(?:ed|ing)\b", r"\btoned\b", r"sepia", r"selenium",
    r"cyanotype", r"\blith\b", r"split[\s_-]*ton", r"solari[sz]", r"sabattier", r"emulation", r"simulation",
    r"cartridge", r"canister", r"film[\s_-]*box", r"packag", r"\bpkg\b", r"film[\s_-]*strip", r"contact[\s_-]*sheet",
    r"\blogo\b", r"film[\s_-]*soup", r"bleach", r"caffenol", r"stand[\s_-]*develop", r"reticulat", r"light[\s_-]*struck",
    r"fogged", r"\brestored\b", r"colou?r[\s_-]*correct", r"\bedit(?:ed)?\b", r"\bcropped\b",
    # Retouching is fine when it only removed dust and scratches.
    r"\bretouch(?!ed[\s_-]*picture\s*\|\s*(?:1\s*=\s*)?(?:kratzer|staub|flecken|fussel|dust|scratch|spot))",
    r"\bdxo\b", r"post[\s_-]*process", r"anonymi[sz]", r"to[\s_-]*show[\s_-]*(?:the[\s_-]*)?grain",
    r"grain[\s_-]*(?:test|sample|comparison)",
    # Water, not the film, sets the colour.
    r"under[\s_-]*water", r"\bscuba\b", r"snorkel", r"nikonos",
    # Exposures of many seconds, where reciprocity failure shifts the colour.
    r"aurora", r"eclips", r"star[\s_-]*trails?", r"astrophoto", r"milky[\s_-]*way", r"\bcomet\b", r"\bnebula",
    r"long[\s_-]*exposure", r"\b\d+(?:[.,]\d+)?\s*(?:min|mins|minutes?)\b\s*(?:exposure|at\s*f\b|@\s*f|f/)",
    r"(?:exposure|exposed|shutter)\s+(?:time\s+)?(?:of\s+|for\s+)?\d+(?:[.,]\d+)?\s*(?:min|mins|minutes?)\b",
    r"(?:red|orange|yellow|green|blue|polari[sz]\w*|\bcpl|warming|cooling|\b8[0125][a-d]?|fl[\s_-]?[dw]|tiffen|grad\w*)"
    r"[\s_-]*filter",
    # The same in the languages Commons descriptions most often use.
    r"cross[\s_-]*entwick", r"proceso[\s_-]*cruzado", r"procesado[\s_-]*cruzado", r"processo[\s_-]*incrociato",
    r"кросс[\s_-]*процесс", r"クロス現像", r"doble[\s_-]*exposici", r"double[\s_-]*exposition", r"doppelbelichtung",
    r"mehrfachbelichtung", r"doppia[\s_-]*esposizione", r"dubbele[\s_-]*belichting", r"двойн\w*[\s_-]*экспозиц",
    r"多重露光", r"abgelaufen", r"caducad[oa]", r"vencid[oa]", r"expirad[oa]", r"p[ée]rim[ée]e?s?\b", r"scadut[oa]",
    r"verlopen", r"przeterminowan", r"просроч", r"aegunud", r"vanhentun", r"期限切れ", r"gepusht", r"forzad[oa]",
    r"\|\s*filter\s*=\s*(?!\s*(?:none|no|nd|uv|skylight|-|\||\}))",
]))
# Words in a title that mean the image is the film itself rather than a photograph made on it.
SKIP_TITLE = re.compile(r"\bnegatives?\b|\binverted\b|\bscan[\s_-]*of[\s_-]*(?:the[\s_-]*)?film\b|\bsprocket|roll\b|rollfilm"
                        r"|\bbanner\b")
# What a title is made of when it only names the film ("Fujichrome Provia 100F - 02", "Ektar 100").
FILM_WORDS = re.compile(r"\b(?:fuji\w*|kodak|ilford|harman|cine[\s_-]*still|professional|pro|films?|colou?r|slide|"
                        r"reversal|chrome|35[\s_-]*mm|mm|iso|asa|\d+|[a-z])\b|[\W\d_]+")
# A colour stock converted to black and white.
MONOCHROME = re.compile(r"black[\s_-]*(?:and|&|n)[\s_-]*white|\bb[\s_]*&[\s_]*w\b|\bb/w\b|monochrom|gr[ae]yscale|desaturat")

SCENES = [
    ("people", r"\b(?:people|person|portrait|women|woman|men|man|girls?|boys?|child(?:ren)?|kids?|family|wedding|bride|"
               r"musicians?|singer|band|concert|festival|pride|protest|demonstration|crowd|dancers?|actor|actress|couple|"
               r"friends|model|self[\s-]?portrait)\b"),
    ("interior", r"\b(?:interior|inside|indoors?|room|restaurant|bar|pub|caf[eé]|kitchen|bedroom|museum|hall|lobby|"
                 r"corridor|staircase|nave|studio|library)\b"),
    ("landscape", r"\b(?:landscapes?|mountains?|hills?|beach|coast|sea|ocean|lakes?|rivers?|forests?|woods?|valley|"
                  r"fields?|meadow|desert|glacier|waterfall|canyon|national park|sunset|sunrise|island|cliffs?|snow|"
                  r"parks?|gardens?|flowers?|trees?|nature|countryside|rural)\b"),
    ("street", r"\b(?:streets?|roads?|avenue|city|town|village|square|station|tram|bus|trolleybus|trains?|railway|"
               r"metro|subway|cars?|trucks?|buildings?|architecture|bridge|shops?|store|market|skyline|downtown|urban|"
               r"harbou?r|port|church|cathedral|house)\b"),
]

LICENCE_URLS = {"cc0": "https://creativecommons.org/publicdomain/zero/1.0/"}


class Refused(Exception):
    pass


# MARK: - Requests

_last = 0.0


def get(url: str, form: dict | None = None, timeout: float = 120) -> bytes:
    global _last
    time.sleep(max(0.0, PAUSE - (time.time() - _last)))
    body = urllib.parse.urlencode(form).encode() if form is not None else None
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=body, headers={"User-Agent": UA}),
                                    timeout=timeout) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        if error.code in (403, 429):
            raise Refused(f"{error.code} on {url}") from error
        raise
    finally:
        _last = time.time()


def api(**params) -> dict:
    params = {"format": "json", "formatversion": "2", "maxlag": "5", **params}
    for _ in range(5):
        # POST, because fifty non-Latin titles overflow a URL.
        data = json.loads(get(API, form=params))
        if data.get("error", {}).get("code") == "maxlag":
            time.sleep(5)
            continue
        if "error" in data:
            raise RuntimeError(f"Commons API: {data['error'].get('info', data['error'])}")
        return data
    raise RuntimeError("Commons API: still lagged after five tries")


def category_files(category: str) -> list[str]:
    titles, cont = [], {}
    while True:
        data = api(action="query", list="categorymembers", cmtitle=f"Category:{category}", cmtype="file",
                   cmlimit="500", **cont)
        titles += [member["title"] for member in data.get("query", {}).get("categorymembers", [])]
        if "continue" not in data:
            return titles
        cont = data["continue"]


def search_files(query: str) -> list[str]:
    data = api(action="query", list="search", srsearch=f"{query} filetype:bitmap", srnamespace="6",
               srlimit=str(SEARCH_LIMIT), srinfo="", srprop="")
    return [hit["title"] for hit in data.get("query", {}).get("search", [])]


def details(titles: list[str]) -> dict[str, dict]:
    """Size, licence, author, description, categories (hidden ones too) and wikitext, 50 files a request."""
    pages: dict[str, dict] = {}
    for start in range(0, len(titles), 50):
        params = dict(action="query", titles="|".join(titles[start:start + 50]), prop="imageinfo|categories|revisions",
                      iiprop="size|mime|url|extmetadata", cllimit="max", rvprop="content", rvslots="main",
                      iiextmetadatafilter="LicenseShortName|License|LicenseUrl|Artist|ImageDescription|ObjectName|"
                                          "DateTimeOriginal")
        cont: dict = {}
        while True:
            data = api(**params, **cont)
            for page in data.get("query", {}).get("pages", []):
                if page.get("missing") or "pageid" not in page:
                    continue
                entry = pages.setdefault(page["title"], {"pageid": page["pageid"], "categories": []})
                entry["categories"] += [c["title"].removeprefix("Category:") for c in page.get("categories", [])]
                if page.get("imageinfo"):
                    info = page["imageinfo"][0]
                    entry.update(width=info.get("width", 0), height=info.get("height", 0), mime=info.get("mime", ""),
                                 page=info.get("descriptionurl", ""),
                                 meta={k: v.get("value", "") for k, v in info.get("extmetadata", {}).items()})
                if page.get("revisions"):
                    entry["wikitext"] = page["revisions"][0].get("slots", {}).get("main", {}).get("content", "")
            if "continue" not in data:
                break
            cont = data["continue"]
    for entry in pages.values():
        entry["categories"] = list(dict.fromkeys(entry["categories"]))
    return pages


def thumbnails(titles: list[str], width: int) -> dict[str, str]:
    urls = {}
    for start in range(0, len(titles), 50):
        data = api(action="query", titles="|".join(titles[start:start + 50]), prop="imageinfo", iiprop="url",
                   iiurlwidth=str(width))
        for page in data.get("query", {}).get("pages", []):
            info = (page.get("imageinfo") or [{}])[0]
            if info.get("thumburl") or info.get("url"):
                urls[page["title"]] = clean_url(info.get("thumburl") or info["url"])
    return urls


def clean_url(url: str) -> str:
    parts = urllib.parse.urlsplit(url)
    query = [(k, v) for k, v in urllib.parse.parse_qsl(parts.query) if not k.startswith("utm_")]
    return urllib.parse.urlunsplit(parts._replace(query=urllib.parse.urlencode(query)))


# MARK: - Judging a file


def plain(markup: str) -> str:
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", markup or ""))).strip()


def licence(entry: dict) -> tuple[str, str] | None:
    """The file's licence if it is CC0, public domain, CC BY or CC BY-SA (any version)."""
    meta = entry.get("meta", {})
    code, name = meta.get("License", "").lower(), plain(meta.get("LicenseShortName", ""))
    allowed = re.compile(r"^(?:cc0|cc-zero|pd\b|pd-|pdm|public domain|cc-by-(?:sa-)?\d)")
    if allowed.match(code) and "-nc" not in code and "-nd" not in code:
        url = meta.get("LicenseUrl", "") or LICENCE_URLS.get(code, "")
        return name or code, url
    # Multi-licensed files report one licence; the licence categories list all of them.
    for category in entry.get("categories", []):
        match = re.match(r"^CC-BY(-SA)?-(\d\.\d)", category)
        if match:
            kind = "by-sa" if match.group(1) else "by"
            return f"CC {kind.upper()} {match.group(2)}", f"https://creativecommons.org/licenses/{kind}/{match.group(2)}"
        if category in ("CC-Zero", "CC0"):
            return "CC0", LICENCE_URLS["cc0"]
    return None


def year(entry: dict, text: str) -> int | None:
    """When it was taken: the earlier of the page's date and a year the description gives ("taken in 2001")."""
    dated = plain(entry.get("meta", {}).get("DateTimeOriginal", ""))
    years = [int(y) for y in re.findall(r"\b(1[89]\d\d|20\d\d)\b", dated)[:1]]
    said = re.search(r"\b(?:taken|shot|photographed|captured)\b(?:\s+[\w,]+){0,3}?\s+in\s+(?:the\s+year\s+)?"
                     r"(1[89]\d\d|20\d\d)\b", text)
    years += [int(said.group(1))] if said else []
    return min(years) if years else None


def statement(entry: dict, title: str) -> str:
    """What the page says about itself: title, wikitext without the licence boilerplate, and its categories."""
    text = re.sub(r"\{\{\s*(?:self|cc-|gfdl|FlickreviewR|LicenseReview|Location|Information field)[^{}]*\}\}", " ",
                  entry.get("wikitext", ""), flags=re.I)
    return " ".join([title.removeprefix("File:").rsplit(".", 1)[0], text, " ".join(entry.get("categories", []))])


def normalise(text: str) -> str:
    return re.sub(r"\s+", " ", text.replace("_", " ")).lower()


def judge(stock_id: str, title: str, entry: dict) -> dict | str:
    """An accepted file as a manifest-like record, or the reason it was skipped."""
    stock = STOCKS[stock_id]
    if title in EXCLUDE:
        return f"excluded: {EXCLUDE[title]}"
    if entry.get("mime") not in ("image/jpeg", "image/png", "image/tiff"):
        return f"type {entry.get('mime')}"
    if max(entry.get("width", 0), entry.get("height", 0)) < MIN_EDGE:
        return "too small"
    terms = licence(entry)
    if not terms:
        return f"licence {entry.get('meta', {}).get('LicenseShortName', '?')}"
    text = normalise(statement(entry, title))
    name = normalise(title.removeprefix("File:"))
    if SKIP_TITLE.search(name):
        return f"title: {SKIP_TITLE.search(name).group(0)}"
    if not FILM_WORDS.sub(" ", re.sub(stock.pattern, " ", name.rsplit(".", 1)[0])).strip():
        return "title: only the film's name (a photo of the film)"
    if found := SKIP.search(text):
        return f"says: {found.group(0)}"
    if stock.colour and (found := MONOCHROME.search(text)):
        return f"monochrome: {found.group(0)}"
    if stock.excludes and (found := re.search(stock.excludes, text)):
        return f"different product: {found.group(0)}"
    in_category = next((c for c in entry.get("categories", []) if c in stock.categories), None)
    said = re.search(stock.pattern, text)
    if said:
        start = max(0, said.start() - 60)
        evidence, strength = f"text: ...{text[start:said.end() + 40].strip()}...", 2
        if in_category:
            evidence, strength = f"category: {in_category}; {evidence}", 3
    elif in_category:
        evidence, strength = f"category: {in_category}", 2
    elif stock.loose and re.search(stock.loose, text) and any(c in stock.family for c in entry.get("categories", [])):
        family = next(c for c in entry["categories"] if c in stock.family)
        evidence, strength = f"category: {family} (no speed stated; {stock.name} is the only 35 mm speed)", 1
    else:
        return "stock not stated"
    for other_id, other in STOCKS.items():
        if other_id != stock_id and other_id not in stock.related and re.search(other.pattern, text):
            return f"also names {other.name}"
    for other, pattern, owners in OTHER_FILMS:
        if stock_id not in owners and (found := re.search(pattern, text)):
            return f"also names {other} ({found.group(0)})"
    if stock.requires and not re.search(stock.requires, text):
        return "stock name without its maker"
    taken = year(entry, text)
    if stock.since and taken and taken < stock.since:
        return f"dated {taken}, before {stock.name} existed"
    meta = entry.get("meta", {})
    description = plain(meta.get("ImageDescription", "")) or plain(meta.get("ObjectName", ""))
    scene = next((label for label, words in SCENES if re.search(words, text)), "other")
    return {
        "title": title, "pageid": entry["pageid"], "source": entry.get("page", ""),
        "author": plain(meta.get("Artist", ""))[:200] or "unknown", "licence": terms[0], "licenceURL": terms[1],
        "description": description[:200], "date": plain(meta.get("DateTimeOriginal", ""))[:40],
        "evidence": evidence[:240], "strength": strength, "scene": scene,
        "originalWidth": entry.get("width", 0), "originalHeight": entry.get("height", 0),
    }


# MARK: - Choosing


def author_key(author: str) -> str:
    """One key per photographer across credit styles ("Photographed by Doug Dolde", "Svetlov Artem")."""
    words = re.sub(r"^(?:photo(?:graph(?:ed)?)?\s+by|by|user)\s*:?\s*", "", author.lower()).split()
    key = " ".join(sorted(words[:2]))
    return AUTHOR_ALIASES.get(key, AUTHOR_ALIASES.get(words[0] if words else "", key))


def title_key(title: str) -> str:
    """The Latin words of a title without import ids, so Flickr and 500px copies of a photo collide."""
    stem = re.sub(r"\(\d+\)|\.[a-z]+$", " ", title.removeprefix("File:").lower())
    return " ".join(re.findall(r"[a-z]+(?:\d+)?|\d+", stem.replace("flickr", " ")))


def choose(accepted: list[dict], kept: list[dict], target: int) -> list[dict]:
    """Up to `target` files, preferring the strongest evidence, spread across authors and kinds of scene."""
    authors: dict[str, int] = {}
    scenes: dict[str, int] = {}
    titles = {title_key(record["title"]) for record in kept}
    for record in kept:
        authors[author_key(record["author"])] = authors.get(author_key(record["author"]), 0) + 1
        scenes[record.get("scene", "other")] = scenes.get(record.get("scene", "other"), 0) + 1
    pool = sorted(accepted, key=lambda r: r["pageid"])
    picks: list[dict] = []
    for cap in (PER_AUTHOR, PER_AUTHOR * 2, target):
        while len(kept) + len(picks) < target:
            # Later rounds may relax the per-author cap, but only to reach the minimum.
            if cap > PER_AUTHOR and len(kept) + len(picks) >= MINIMUM:
                break
            options = [r for r in pool if r not in picks and authors.get(author_key(r["author"]), 0) < cap
                       and (not title_key(r["title"]) or title_key(r["title"]) not in titles)]
            if not options:
                break
            # A stock stated by category or by text counts the same; a page saying both is a small bonus.
            best = max(options, key=lambda r: (
                6 * min(r["strength"], 2) + (r["strength"] == 3) - 3 * authors.get(author_key(r["author"]), 0)
                - 2 * scenes.get(r["scene"], 0) + (max(r["originalWidth"], r["originalHeight"]) >= 1600), -r["pageid"]))
            picks.append(best)
            titles.add(title_key(best["title"]))
            authors[author_key(best["author"])] = authors.get(author_key(best["author"]), 0) + 1
            scenes[best["scene"]] = scenes.get(best["scene"], 0) + 1
    return picks


def thumbnail_width(record: dict) -> int:
    """A standard Wikimedia thumbnail width (960 or 1280) that puts the long edge near 1200-1600 px."""
    width, height = record["originalWidth"], record["originalHeight"]
    if width >= height:
        return 1280
    return 960 if 960 * height / width >= 1200 else 1280


# MARK: - Files


def image_size(data: bytes) -> tuple[int, int]:
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return struct.unpack(">II", data[16:24])
    at = 2
    while at < len(data) - 9:
        marker, length = data[at + 1], struct.unpack(">H", data[at + 2:at + 4])[0]
        if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
            height, width = struct.unpack(">HH", data[at + 5:at + 9])
            return width, height
        at += 2 + length
    return 0, 0


def file_name(record: dict, data: bytes) -> str:
    stem = unicodedata.normalize("NFKD", record["title"].removeprefix("File:").rsplit(".", 1)[0])
    slug = re.sub(r"[^a-z0-9]+", "-", stem.encode("ascii", "ignore").decode().lower()).strip("-")[:48].strip("-")
    return f"{record['pageid']}{'-' + slug if slug else ''}{'.png' if data[:4] == b'\x89PNG' else '.jpg'}"


def load() -> list[dict]:
    return json.loads(MANIFEST.read_text()) if MANIFEST.exists() else []


def save(entries: list[dict]) -> None:
    order = {stock: index for index, stock in enumerate(STOCKS)}
    entries.sort(key=lambda e: (order.get(e["stock"], 99), e["file"]))
    MANIFEST.write_text(json.dumps(entries, indent=1, ensure_ascii=False) + "\n")


def download(url: str) -> bytes | None:
    """The image, or None (and a note) if this one file can't be had; refusals still stop the run."""
    try:
        data = get(url)
    except (urllib.error.URLError, TimeoutError) as error:
        print(f"  ! {url}: {error}", flush=True)
        return None
    if data[:2] != b"\xff\xd8" and data[:4] != b"\x89PNG":
        print(f"  ! {url}: not a JPEG or PNG", flush=True)
        return None
    return data


def store(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_suffix(path.suffix + ".part")
    partial.write_bytes(data)
    partial.rename(path)


# MARK: - Steps


def fetch(entries: list[dict]) -> None:
    """Downloads every manifest entry that isn't on disk yet."""
    todo = [e for e in entries if not (ROOT / e["file"]).exists()]
    print(f"{len(entries) - len(todo)} present, {len(todo)} to download", flush=True)
    for index, entry in enumerate(todo, 1):
        data = download(entry["imageURL"])
        if data is None:
            continue
        digest = hashlib.sha256(data).hexdigest()
        if digest != entry["sha256"]:
            # Commons re-renders thumbnails now and then; the manifest follows what is on disk.
            print(f"  {entry['file']}: thumbnail changed upstream, updating its hash", flush=True)
            entry["sha256"] = digest
            entry["width"], entry["height"] = image_size(data)
        store(ROOT / entry["file"], data)
        save(entries)
        print(f"  {index}/{len(todo)} {entry['file']}", flush=True)


def candidates(stock_id: str, refresh: bool) -> dict[str, dict]:
    path = CACHE / f"{stock_id}.json"
    if path.exists() and not refresh:
        return json.loads(path.read_text())
    stock = STOCKS[stock_id]
    titles: list[str] = []
    for category in stock.categories + stock.family:
        titles += category_files(category)
    for query in stock.searches:
        titles += search_files(query)
    pages = details(list(dict.fromkeys(titles)))
    CACHE.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(pages))
    return pages


def discover(stock_ids: list[str], refresh: bool, dry_run: bool, entries: list[dict]) -> None:
    for stock_id in stock_ids:
        stock = STOCKS[stock_id]
        target = OPTIONAL_TARGET if stock.optional else TARGET
        pages = candidates(stock_id, refresh)
        verdicts = {title: judge(stock_id, title, entry) for title, entry in pages.items()}
        accepted = {t: v for t, v in verdicts.items() if isinstance(v, dict)}
        # Drop entries the current rules (or a later review) reject, and their files.
        for entry in [e for e in entries if e["stock"] == stock_id]:
            verdict = EXCLUDE.get(entry["title"]) or verdicts.get(entry["title"])
            if isinstance(verdict, str) and not dry_run:
                entries.remove(entry)
                (ROOT / entry["file"]).unlink(missing_ok=True)
                print(f"  - {stock_id}: removed {entry['title']} ({verdict})")
        kept = [e for e in entries if e["stock"] == stock_id]
        held = {e["title"] for e in kept}
        for record in kept:
            record.setdefault("scene", accepted.get(record["title"], {}).get("scene", "other"))
        picks = choose([r for t, r in accepted.items() if t not in held], kept, target)
        reasons: dict[str, int] = {}
        for verdict in verdicts.values():
            if isinstance(verdict, str):
                key = verdict.split(":")[0] if not verdict.startswith("also names") else "names another stock"
                reasons[key] = reasons.get(key, 0) + 1
        print(f"{stock_id}: {len(pages)} candidates, {len(accepted)} accepted, {len(kept)} kept, {len(picks)} new; "
              f"skipped {dict(sorted(reasons.items(), key=lambda kv: -kv[1]))}", flush=True)
        if dry_run:
            for record in picks:
                print(f"    + [{record['strength']}] {record['scene']:9} {record['author'][:24]:24} "
                      f"{record['title'][5:70]} | {record['evidence'][:90]}")
            continue
        urls: dict[str, str] = {}
        for width in (960, 1280):
            group = [r["title"] for r in picks if thumbnail_width(r) == width]
            if group:
                urls.update(thumbnails(group, width))
        for record in picks:
            data = download(urls[record["title"]]) if record["title"] in urls else None
            if data is None:
                continue
            path = OUT / stock_id / file_name(record, data)
            store(path, data)
            width, height = image_size(data)
            entries.append({
                "stock": stock_id, "file": str(path.relative_to(ROOT)), "source": record["source"],
                "imageURL": urls[record["title"]], "author": record["author"], "licence": record["licence"],
                "licenceURL": record["licenceURL"], "description": record["description"], "width": width,
                "height": height, "sha256": hashlib.sha256(data).hexdigest(), "title": record["title"],
                "date": record["date"], "evidence": record["evidence"], "scene": record["scene"],
            })
            save(entries)
            print(f"  + {path.relative_to(OUT)} ({len(data) // 1024} KB)", flush=True)


def summary(entries: list[dict]) -> None:
    counts = {stock: 0 for stock in STOCKS}
    size = 0
    for entry in entries:
        counts[entry["stock"]] = counts.get(entry["stock"], 0) + 1
        path = ROOT / entry["file"]
        size += path.stat().st_size if path.exists() else 0
    for stock, count in counts.items():
        print(f"  {stock:24} {count}")
    print(f"{len(entries)} files, {size / 1e6:.1f} MB")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    parser.add_argument("step", nargs="?", default="fetch", choices=["fetch", "discover"])
    parser.add_argument("--stock", action="append", choices=list(STOCKS), help="only these stocks (repeatable)")
    parser.add_argument("--refresh", action="store_true", help="re-query Commons instead of using the cached candidates")
    parser.add_argument("--dry-run", action="store_true", help="show what discover would pick, download nothing")
    args = parser.parse_args()
    entries = load()
    try:
        if args.step == "discover":
            discover(args.stock or list(STOCKS), args.refresh, args.dry_run, entries)
        else:
            fetch(entries)
    except Refused as refused:
        save(entries)
        print(f"Stopped: Commons refused a request ({refused}). Rerun later to resume.", file=sys.stderr)
        return 1
    if not args.dry_run:
        save(entries)
        summary(entries)
    return 0


if __name__ == "__main__":
    sys.exit(main())
