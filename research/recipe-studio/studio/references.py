"""The reference corpus: public-domain and CC0 photographs that define styles.

Only allowlisted sources are fetched, and only items whose license the source states as
public domain or CC0. Every image gets a manifest entry (source, page, image URL, license,
author, date, title, style), and nothing here is ever shipped: images and the manifest
live in build/references/, which is gitignored. Recipes are never named after
photographers, brands or film stocks.
"""

from __future__ import annotations

import hashlib
import json
import os
import time
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass, field
from pathlib import Path

from . import REFERENCES, STUDIO

USER_AGENT = "RedlampRecipeStudio/1 (+https://github.com/pdcgomes/redlamp; research, public-domain only)"

# Hosts the fetcher may contact. Anything else is refused, so an agent or a bad API
# response can never pull images (or presets) from elsewhere.
ALLOWED_HOSTS = {
    "www.loc.gov", "loc.gov", "tile.loc.gov",
    "collectionapi.metmuseum.org", "images.metmuseum.org",
    "api.artic.edu", "www.artic.edu", "artic.edu",
    "images-api.nasa.gov", "images-assets.nasa.gov",
    "commons.wikimedia.org", "upload.wikimedia.org", "thumb.wikimedia.org",
    "api.si.edu", "ids.si.edu",
    "www.rijksmuseum.nl", "data.rijksmuseum.nl", "lh3.googleusercontent.com",
    "api.flickr.com", "live.staticflickr.com",
}

PUBLIC_DOMAIN = "public-domain"
CC0 = "CC0-1.0"

# Other image URLs to try when a source's preferred size isn't available.
_FALLBACKS: dict[str, list[str]] = {}

# Titles that are documents rather than photographs.
_NOT_PHOTOGRAPHS = ("pamphlet", "price list", "logo", "map of", "diagram", "artist concept", "illustration", "poster")


@dataclass
class Reference:
    id: str
    source: str
    source_id: str
    page: str
    image_url: str
    license: str
    title: str = ""
    author: str = ""
    date: str = ""
    style: str = ""
    query: str = ""
    file: str = ""
    sha256: str = ""
    fetched: str = ""
    notes: str = ""
    tags: list[str] = field(default_factory=list)


class Refused(Exception):
    pass


def _check(url: str) -> str:
    host = urllib.parse.urlparse(url).hostname or ""
    if host not in ALLOWED_HOSTS:
        raise Refused(f"{host} is not an allowlisted reference source")
    return url


def _get(url: str, timeout: float = 30) -> bytes:
    request = urllib.request.Request(_check(url), headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        final = response.geturl()
        _check(final)  # Redirects must stay on the allowlist too.
        return response.read()


def _json(url: str) -> dict:
    return json.loads(_get(url))


# MARK: - Sources


def search_loc(query: str, limit: int) -> list[Reference]:
    """Library of Congress: items whose rights say "No known restrictions".

    loc.gov sometimes answers automated requests with 403 (bot protection); the fetcher
    then reports the source as unavailable and carries on with the others.
    """
    url = "https://www.loc.gov/photos/?" + urllib.parse.urlencode({"q": query, "fo": "json", "c": min(limit * 3, 100)})
    results = []
    for item in _json(url).get("results", []):
        rights = " ".join(item.get("rights_advisory", []) if isinstance(item.get("rights_advisory"), list)
                          else [str(item.get("rights_advisory", ""))]) + " " + str(item.get("rights", ""))
        images = item.get("image_url") or []
        if "no known restrictions" not in rights.lower() or not images:
            continue
        results.append(Reference(
            id=f"loc-{hashlib.sha1(item.get('id', '').encode()).hexdigest()[:10]}", source="loc", source_id=item.get("id", ""),
            page=item.get("id", ""), image_url=images[-1].split("#")[0], license=PUBLIC_DOMAIN,
            title=item.get("title", ""), author=", ".join(item.get("contributor", []) or []), date=str(item.get("date", "")),
            query=query, notes="Rights advisory: no known restrictions on publication.",
        ))
        if len(results) >= limit:
            break
    return results


def search_met(query: str, limit: int) -> list[Reference]:
    """The Met Open Access: public-domain photographs (CC0)."""
    # The Met's search ignores filters that come after `q`, so it goes last.
    url = "https://collectionapi.metmuseum.org/public/collection/v1/search?" + urllib.parse.urlencode(
        [("hasImages", "true"), ("isPublicDomain", "true"), ("medium", "Photographs"), ("q", query)])
    ids = (_json(url).get("objectIDs") or [])[: limit * 3]
    results = []
    for object_id in ids:
        item = _json(f"https://collectionapi.metmuseum.org/public/collection/v1/objects/{object_id}")
        if not item.get("isPublicDomain") or not item.get("primaryImage"):
            continue
        results.append(Reference(
            id=f"met-{object_id}", source="met", source_id=str(object_id), page=item.get("objectURL", ""),
            image_url=item["primaryImage"], license=CC0, title=item.get("title", ""),
            author=item.get("artistDisplayName", ""), date=item.get("objectDate", ""), query=query,
            notes=item.get("medium", ""),
        ))
        if len(results) >= limit:
            break
        time.sleep(0.1)
    return results


def search_aic(query: str, limit: int) -> list[Reference]:
    """Art Institute of Chicago: public-domain works (CC0 images)."""
    params = {"q": query, "limit": min(limit * 3, 100), "query[term][is_public_domain]": "true",
              "fields": "id,title,image_id,artist_display,date_display,is_public_domain,artwork_type_title"}
    results = []
    for item in _json("https://api.artic.edu/api/v1/artworks/search?" + urllib.parse.urlencode(params)).get("data", []):
        if not item.get("is_public_domain") or not item.get("image_id"):
            continue
        if item.get("artwork_type_title") not in (None, "Photograph"):
            continue
        results.append(Reference(
            id=f"aic-{item['id']}", source="aic", source_id=str(item["id"]),
            page=f"https://www.artic.edu/artworks/{item['id']}",
            # 843 px is the width the AIC's IIIF server documents for public use.
            image_url=f"https://www.artic.edu/iiif/2/{item['image_id']}/full/843,/0/default.jpg",
            license=CC0, title=item.get("title", ""), author=item.get("artist_display", ""),
            date=item.get("date_display", ""), query=query,
        ))
        if len(results) >= limit:
            break
    return results


def search_nasa(query: str, limit: int) -> list[Reference]:
    """NASA Image and Video Library: US government works, not copyrighted."""
    url = "https://images-api.nasa.gov/search?" + urllib.parse.urlencode({"q": query, "media_type": "image"})
    results = []
    for item in _json(url).get("collection", {}).get("items", [])[:limit]:
        data = (item.get("data") or [{}])[0]
        nasa_id = data.get("nasa_id", "")
        links = [link["href"] for link in item.get("links", []) if link.get("render") == "image"]
        if not nasa_id or not links:
            continue
        image = links[0].replace("~thumb", "~medium").replace("~small", "~medium")
        _FALLBACKS[f"nasa-{hashlib.sha1(nasa_id.encode()).hexdigest()[:10]}"] = [links[0]]
        results.append(Reference(
            id=f"nasa-{hashlib.sha1(nasa_id.encode()).hexdigest()[:10]}", source="nasa", source_id=nasa_id,
            page=f"https://images.nasa.gov/details/{urllib.parse.quote(nasa_id)}", image_url=image,
            license=PUBLIC_DOMAIN, title=data.get("title", ""), author=data.get("photographer", "") or "NASA",
            date=data.get("date_created", ""), query=query, notes="NASA media: not protected by copyright in the US.",
        ))
    return results


def search_wikimedia(query: str, limit: int) -> list[Reference]:
    """Wikimedia Commons: only files whose license is public domain or CC0."""
    params = {"action": "query", "generator": "search", "gsrsearch": f"{query} filetype:bitmap", "gsrnamespace": 6,
              "gsrlimit": min(limit * 4, 50), "prop": "imageinfo", "iiprop": "url|extmetadata", "iiurlwidth": 1600,
              "format": "json"}
    pages = _json("https://commons.wikimedia.org/w/api.php?" + urllib.parse.urlencode(params)).get("query", {}).get("pages", {})
    results = []
    for page in pages.values():
        info = (page.get("imageinfo") or [{}])[0]
        meta = info.get("extmetadata", {})
        license_name = meta.get("LicenseShortName", {}).get("value", "")
        if not (license_name.lower().startswith("public domain") or license_name.upper().startswith("CC0")
                or license_name.upper().startswith("PD")):
            continue
        results.append(Reference(
            id=f"wm-{page['pageid']}", source="wikimedia", source_id=str(page["pageid"]),
            page=info.get("descriptionurl", ""), image_url=info.get("thumburl") or info.get("url", ""),
            license=CC0 if "CC0" in license_name.upper() else PUBLIC_DOMAIN, title=page.get("title", ""),
            author=_strip(meta.get("Artist", {}).get("value", "")), date=_strip(meta.get("DateTimeOriginal", {}).get("value", "")),
            query=query, notes=f"License: {license_name}",
        ))
        if len(results) >= limit:
            break
    return results


def search_smithsonian(query: str, limit: int) -> list[Reference]:
    """Smithsonian Open Access (CC0). Needs SI_API_KEY (api.data.gov)."""
    key = os.environ.get("SI_API_KEY")
    if not key:
        return []
    url = "https://api.si.edu/openaccess/api/v1.0/search?" + urllib.parse.urlencode(
        {"q": f"{query} AND online_media_type:\"Images\"", "rows": min(limit * 3, 100), "api_key": key})
    results = []
    for row in _json(url).get("response", {}).get("rows", []):
        content = row.get("content", {})
        media = content.get("descriptiveNonRepeating", {}).get("online_media", {}).get("media", [])
        usable = [m for m in media if m.get("usage", {}).get("access") == "CC0" and m.get("content")]
        if not usable:
            continue
        results.append(Reference(
            id=f"si-{hashlib.sha1(row['id'].encode()).hexdigest()[:10]}", source="smithsonian", source_id=row["id"],
            page=content.get("descriptiveNonRepeating", {}).get("record_link", ""), image_url=usable[0]["content"],
            license=CC0, title=row.get("title", ""), query=query,
        ))
        if len(results) >= limit:
            break
    return results


def search_rijksmuseum(query: str, limit: int) -> list[Reference]:
    """Rijksmuseum: public-domain photographs. Needs RIJKS_API_KEY."""
    key = os.environ.get("RIJKS_API_KEY")
    if not key:
        return []
    url = "https://www.rijksmuseum.nl/api/en/collection?" + urllib.parse.urlencode(
        {"key": key, "q": query, "imgonly": "true", "type": "photograph", "ps": min(limit, 100)})
    results = []
    for item in _json(url).get("artObjects", []):
        image = (item.get("webImage") or {}).get("url")
        if not image or not item.get("permitDownload", True):
            continue
        results.append(Reference(
            id=f"rijks-{item['objectNumber']}", source="rijksmuseum", source_id=item["objectNumber"],
            page=item.get("links", {}).get("web", ""), image_url=image, license=PUBLIC_DOMAIN,
            title=item.get("title", ""), author=item.get("principalOrFirstMaker", ""), query=query,
        ))
    return results


def search_flickr_commons(query: str, limit: int) -> list[Reference]:
    """Flickr Commons: "no known copyright restrictions" (license 7). Needs FLICKR_API_KEY."""
    key = os.environ.get("FLICKR_API_KEY")
    if not key:
        return []
    params = {"method": "flickr.photos.search", "api_key": key, "text": query, "is_commons": "true", "license": "7",
              "extras": "license,url_l,date_taken,owner_name", "per_page": min(limit, 100), "format": "json", "nojsoncallback": 1}
    results = []
    for photo in _json("https://api.flickr.com/services/rest/?" + urllib.parse.urlencode(params)).get("photos", {}).get("photo", []):
        if str(photo.get("license")) != "7" or not photo.get("url_l"):
            continue
        results.append(Reference(
            id=f"flickr-{photo['id']}", source="flickr-commons", source_id=photo["id"],
            page=f"https://www.flickr.com/photos/{photo['owner']}/{photo['id']}", image_url=photo["url_l"],
            license=PUBLIC_DOMAIN, title=photo.get("title", ""), author=photo.get("ownername", ""),
            date=photo.get("datetaken", ""), query=query, notes="Flickr Commons: no known copyright restrictions.",
        ))
    return results


SOURCES = {
    "loc": search_loc, "met": search_met, "aic": search_aic, "nasa": search_nasa, "wikimedia": search_wikimedia,
    "smithsonian": search_smithsonian, "rijksmuseum": search_rijksmuseum, "flickr-commons": search_flickr_commons,
}


def _strip(html: str) -> str:
    import re
    return re.sub(r"<[^>]+>", "", html).strip()


# MARK: - Manifest


class Corpus:
    """build/references/: images by source, and manifest.jsonl."""

    def __init__(self, root: Path = REFERENCES):
        self.root = root
        self.manifest = root / "manifest.jsonl"

    def entries(self) -> list[Reference]:
        if not self.manifest.exists():
            return []
        return [Reference(**json.loads(line)) for line in self.manifest.read_text().splitlines() if line.strip()]

    def add(self, reference: Reference, data: bytes) -> Reference:
        folder = self.root / reference.source
        folder.mkdir(parents=True, exist_ok=True)
        ext = ".png" if data[:4] == b"\x89PNG" else ".jpg"
        path = folder / f"{reference.id}{ext}"
        path.write_bytes(data)
        reference.file = str(path.relative_to(self.root))
        reference.sha256 = hashlib.sha256(data).hexdigest()
        reference.fetched = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        with self.manifest.open("a") as handle:
            handle.write(json.dumps(asdict(reference)) + "\n")
        return reference

    def known(self) -> set[str]:
        return {entry.id for entry in self.entries()}

    def path(self, reference: Reference) -> Path:
        return self.root / reference.file

    def by_style(self) -> dict[str, list[Reference]]:
        groups: dict[str, list[Reference]] = {}
        for entry in self.entries():
            groups.setdefault(entry.style or "unsorted", []).append(entry)
        return groups


def fetch(styles: dict | None = None, per_query: int = 4, only: set[str] | None = None, log=print) -> list[Reference]:
    """Fetches every style's queries from its sources into the corpus."""
    styles = styles or json.loads((STUDIO / "reference_queries.json").read_text())["styles"]
    corpus = Corpus()
    known = corpus.known()
    added = []
    for style, spec in styles.items():
        if only and style not in only:
            continue
        for source, queries in spec["sources"].items():
            search = SOURCES[source]
            for query in queries:
                try:
                    found = search(query, per_query)
                except Refused as refusal:
                    log(f"refused: {refusal}")
                    continue
                except Exception as error:  # A source being down shouldn't stop the others.
                    log(f"{source} '{query}': {error}")
                    continue
                for reference in found:
                    if reference.id in known or any(word in reference.title.lower() for word in _NOT_PHOTOGRAPHS):
                        continue
                    reference.style = style
                    reference.tags = spec.get("tags", [])
                    data = None
                    for url in [reference.image_url] + _FALLBACKS.get(reference.id, []):
                        try:
                            data = _get(url, timeout=60)
                            reference.image_url = url
                            break
                        except Exception as error:
                            log(f"  {reference.id}: {error} ({url.rsplit('/', 1)[-1]})")
                    if data is None:
                        continue
                    added.append(corpus.add(reference, data))
                    known.add(reference.id)
                    log(f"  + {style}: {reference.source} {reference.title[:60]} ({reference.license})")
    return added


def add_own(folder: Path, style: str, license: str, author: str, log=print) -> list[Reference]:
    """Registers photos we own or commissioned (for styles public domain lacks)."""
    corpus = Corpus()
    added = []
    for path in sorted(folder.iterdir()):
        if path.suffix.lower() not in (".jpg", ".jpeg", ".png", ".tif", ".tiff"):
            continue
        data = path.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        reference = Reference(
            id=f"own-{digest[:12]}", source="own", source_id=path.name, page="", image_url="", license=license,
            title=path.stem, author=author, style=style, notes="Own or commissioned photograph.",
        )
        if reference.id in corpus.known():
            continue
        added.append(corpus.add(reference, data))
        log(f"  + {style}: {path.name}")
    return added
