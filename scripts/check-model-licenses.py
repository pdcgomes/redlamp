#!/usr/bin/env python3
"""Model licence gate (tracker INF-01).

Every model Redlamp can download has a manifest in packages/RedlampMasking/Resources/Models.
This fails the build when a manifest is incomplete, when its code or weights licence isn't a
permissive one, or when its training data's terms don't allow shipping and the manifest doesn't
say so. The training data's licence wins: Apache weights trained on non-commercial data are not
shippable.

Dataset verdicts follow docs/research/notes/C-masking.md:
  commercial       the terms allow commercial use
  publisher-grant  the publisher owned or licensed the data and released the weights itself;
                   shippable once the decision named in the manifest is accepted
  non-commercial   research or non-commercial only: the model must be evaluationOnly
  lineage          research-only data behind the permissive weights a publisher released (under a
                   backbone, an annotator or a fine-tune): allowed by DEC-24, which the manifest
                   must name; data a model was trained on directly from Places2 stays
                   non-commercial
  undisclosed      the publisher doesn't say what the weights were trained on: allowed as an
                   opt-in download, labelled as generated, by DEC-23, which the manifest must name

A manifest is `cleared` (offered to everyone) only once its decision is accepted; until then the
app offers it only with evaluation models turned on. With --release, a model still waiting on its
decision fails.

The owner can accept a model these rules would hold back, by a decision named in EXCEPTIONS: once
that decision is accepted, the data or the licence it covers no longer makes the model evaluation
only.
"""

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFESTS = ROOT / "packages/RedlampMasking/Resources/Models"
TRACKER = ROOT / "docs/research/research-tracker.md"

PERMISSIVE = {"Apache-2.0", "MIT", "BSD-2-Clause", "BSD-3-Clause"}
# Custom licences counsel hasn't cleared: only ever for an evaluation model, never cleared, unless an
# exception covers it.
RESTRICTED = {"SAM License"}
# The owner's exceptions, by decision, and what each covers. DEC-02: Depth Anything V2 Small and 3,
# whose training data's terms don't allow shipping. DEC-27: SAM 3, under Meta's SAM License, with
# its unaudited data. DEC-35: ViTMatte, trained on Composition-1k and Distinctions-646.
EXCEPTIONS = {"DEC-02": {"data"}, "DEC-27": {"data", "licence"}, "DEC-35": {"data"}}

DATASETS = {
    "SA-1B": "publisher-grant",
    "SA-V": "commercial",
    "LVD-142M": "publisher-grant",
    "Open Images V7": "commercial",
    "ImageNet-21K": "non-commercial",
    "Places365": "non-commercial",
    "LSUN": "non-commercial",
    "BDD100K": "non-commercial",
    "Virtual KITTI 2": "non-commercial",
    "ADE20K": "non-commercial",
    "Cityscapes": "non-commercial",
    "DIS5K": "non-commercial",
    # "Public academic datasets", unlisted: treated as non-commercial until audited.
    "Depth Anything 3 academic mix (unaudited)": "non-commercial",
    # SAM 3's SA-Co data (Meta): terms unaudited, treated as non-commercial.
    "SA-Co (unaudited)": "non-commercial",
    # OWLv2 (google/owlv2-base-patch16-ensemble), from its paper (arXiv 2306.09683).
    "CLIP image-text pairs (OpenAI, undisclosed)": "publisher-grant",
    "WebLI (Google), pseudo-annotated": "publisher-grant",
    "LVIS (COCO images)": "lineage",
    "Objects365, behind the annotator": "lineage",
    "Visual Genome, behind the annotator": "lineage",
    # ViTMatte (hustvl): Composition-1k is built from Adobe's Deep Image Matting set, given out on
    # request for research; Distinctions-646's authors ask to hear of any use.
    "Composition-1k (from Adobe's Deep Image Matting dataset, distributed on request for research)": "non-commercial",
    "Distinctions-646": "non-commercial",
    # FLUX.2 [klein] 4B: the model card only describes its NSFW and CSAM filtering.
    "Undisclosed (Black Forest Labs)": "undisclosed",
}

REQUIRED = ["id", "version", "name", "purpose", "provider", "assetPack", "source", "computeUnits", "files", "licenses"]


def accepted_decisions():
    """Decision ids the tracker marks Accepted."""
    accepted = set()
    for line in TRACKER.read_text().splitlines():
        match = re.match(r"\|\s*(DEC-\d+)\s*\|", line)
        if match and "| Accepted" in line:
            accepted.add(match.group(1))
    return accepted


def check(path, accepted):
    problems = []
    manifest = json.loads(path.read_text())
    for key in REQUIRED:
        if key not in manifest:
            problems.append(f"missing {key}")
    if problems:
        return problems, None
    licenses = manifest["licenses"]
    decision = manifest.get("decision")
    excepted = EXCEPTIONS.get(decision, set()) if decision in accepted else set()
    for part in ("code", "weights"):
        licence = licenses.get(part)
        if licence in RESTRICTED:
            if "licence" not in excepted and (not manifest.get("evaluationOnly", False) or manifest.get("cleared", False)):
                problems.append(f"{part} licence {licence!r} is only allowed for an evaluation model, never cleared")
        elif licence not in PERMISSIVE:
            problems.append(f"{part} licence {licence!r} is not permissive")
    if not manifest["files"]:
        problems.append("no files")
    for file in manifest["files"]:
        if not re.fullmatch(r"[0-9a-f]{64}", file.get("sha256", "")) or file.get("bytes", 0) <= 0:
            problems.append(f"{file.get('path')}: needs bytes and a SHA-256")
    verdicts = {}
    for dataset in licenses.get("data", []):
        verdict = DATASETS.get(dataset)
        if verdict is None:
            problems.append(f"dataset {dataset!r} has no verdict in this script")
        verdicts[dataset] = verdict
    evaluation_only = manifest.get("evaluationOnly", False)
    if "non-commercial" in verdicts.values() and not evaluation_only and "data" not in excepted:
        tainted = [d for d, v in verdicts.items() if v == "non-commercial"]
        problems.append(f"trained on non-commercial data ({', '.join(tainted)}) but not evaluationOnly")
    if manifest.get("cleared") and manifest.get("published") is False:
        problems.append("cleared models must be published (downloadable)")
    if "publisher-grant" in verdicts.values() and not decision:
        problems.append("publisher-granted data needs a decision id")
    if "lineage" in verdicts.values() and decision != "DEC-24":
        problems.append("research-only data in the lineage is allowed by DEC-24 only, which it must name")
    if "undisclosed" in verdicts.values() and decision != "DEC-23":
        problems.append("undisclosed training data is allowed by DEC-23 only, which it must name")
    cleared = manifest.get("cleared", False)
    if cleared and (evaluation_only or (decision and decision not in accepted)):
        problems.append(f"marked cleared, but {'it is evaluation only' if evaluation_only else decision + ' is not accepted'}")
    if evaluation_only:
        status = "evaluation only"
    elif decision and decision not in accepted:
        status = f"waits on {decision}"
    else:
        status = "shippable"
    return problems, status


def main():
    accepted = accepted_decisions()
    release = "--release" in sys.argv
    failed = False
    manifests = sorted(MANIFESTS.glob("*.json"))
    if not manifests:
        print("check-model-licenses: no manifests")
        return 1
    for path in manifests:
        problems, status = check(path, accepted)
        if problems:
            failed = True
            print(f"{path.name}: FAIL")
            for problem in problems:
                print(f"  - {problem}")
        elif release and status.startswith("waits on"):
            failed = True
            print(f"{path.name}: FAIL for release ({status})")
        else:
            print(f"{path.name}: OK ({status})")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
