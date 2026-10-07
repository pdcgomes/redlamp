"""Downloads a RawNIND subset (Brummer & De Vleeschouwer, arXiv 2501.08924; doi:10.14428/DVN/DEQCIM,
CC BY-SA 4.0) into build/proto-data/raw-denoise/rawnind: for each scene the clean ground-truth frame
and two high-ISO frames. Evaluation only; nothing is committed, and nothing is trained on it (DEC-03).
"""

import json
import re
import subprocess
import urllib.request

from common import DATA

API = "https://dataverse.uclouvain.be/api"
DOI = "doi:10.14428/DVN/DEQCIM"

SCENES = {
    "Bayer": {"Bark": [12800, 51200], "Kortlek": [12800, 51200], "Spydercheckr": [12800, 51200],
              "TEST_TitusToys": [25600, 51200], "bark_beetled_log": [25600, 51200],
              # Held out of the RawNIND checkpoints' training (their test_reserve is the TEST_ scenes).
              "TEST_MuseeL-vases-A7C": [12800, 64000], "TEST_Vaxt-i-trad": [12800, 51200],
              "TEST_7D-2": [6400, 12800]},
    "X-Trans": {"books": [1600, 6400], "MuseeL-text": [5000, 6400], "parking-keyboard": [3200, 6400],
                "fruits": [3200, 6400], "colorscreen": [3200, 6400], "tree1": [3200, 6400]},
}


def main():
    out = DATA / "rawnind"
    out.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(f"{API}/datasets/:persistentId/?persistentId={DOI}", timeout=60) as response:
        files = json.load(response)["data"]["latestVersion"]["files"]
    chosen = []
    for cfa, scenes in SCENES.items():
        for scene, isos in scenes.items():
            pattern = re.compile(rf"^{re.escape(cfa)}_{re.escape(scene)}_(GT_)?ISO(\d+)_sha1=")
            gt, noisy = None, {}
            for f in files:
                name = f["dataFile"]["filename"]
                m = pattern.match(name)
                if not m:
                    continue
                if m.group(1) and gt is None:
                    gt = f
                elif not m.group(1) and int(m.group(2)) in isos and int(m.group(2)) not in noisy:
                    noisy[int(m.group(2))] = f
            chosen.append({"cfa": cfa, "scene": scene, "gt": gt["dataFile"]["filename"],
                           "noisy": {iso: f["dataFile"]["filename"] for iso, f in sorted(noisy.items())}})
            for f in [gt, *noisy.values()]:
                path = out / f["dataFile"]["filename"]
                if path.exists() and path.stat().st_size == f["dataFile"]["filesize"]:
                    continue
                print("downloading", path.name)
                subprocess.run(["curl", "-sfL", "-o", str(path),
                                f"{API}/access/datafile/{f['dataFile']['id']}"], check=True)
    (out / "subset.json").write_text(json.dumps(chosen, indent=1))
    print(len(chosen), "scenes")


if __name__ == "__main__":
    main()
