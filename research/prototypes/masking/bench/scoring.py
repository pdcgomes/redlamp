"""Scores for one mask against a reference (MSK-38).

Masks are coverage from 0 to 1 at the bench's size; a pixel is inside at 0.5 or more. Pixels the
reference marks unknown count for neither. Shares of the frame keep a mask comparable when the
reference is empty (a photo with no sky), where shares of the reference can't be had.

* `iou`: inside in both, over inside in either (1 when both are empty).
* `missed`, `extra`: what the candidate leaves out of the reference, and what it adds, as shares
  of the reference; `missedFrame`, `extraFrame` as shares of the frame.
* `boundaryF`: how closely the two edges follow each other, within 0.25% of the diagonal (about
  6 px at 2048 px).
* `regionDisagreement`, `edgeDisagreement`: the pixels where they disagree, as shares of the frame,
  split by whether they lie within 1% of the diagonal (about 25 px) of either edge: farther away
  it's a different region (a missed limb, a building taken for sky), nearer it's the edge.
* `softDifference`: the mean absolute difference in coverage, partial pixels included.
"""

import cv2
import numpy as np

BOUNDARY_TOLERANCE = 0.0025
EDGE_BAND = 0.01


def boundary(inside):
    kernel = np.ones((3, 3), np.uint8)
    inside = inside.astype(np.uint8)
    return cv2.morphologyEx(inside, cv2.MORPH_GRADIENT, kernel) > 0


def distance_to(pixels):
    """Each pixel's distance to the nearest of `pixels` (inf when there are none)."""
    if not pixels.any():
        return np.full(pixels.shape, np.inf, np.float32)
    return cv2.distanceTransform((~pixels).astype(np.uint8), cv2.DIST_L2, 3)


def metrics(candidate, reference, unknown=None):
    valid = np.ones(reference.shape, bool) if unknown is None else ~unknown
    frame = max(int(valid.sum()), 1)
    a = (candidate >= 0.5) & valid
    b = (reference >= 0.5) & valid
    inside_a, inside_b = int(a.sum()), int(b.sum())
    union = int((a | b).sum())
    missed = int((b & ~a).sum())
    extra = int((a & ~b).sum())
    diagonal = float(np.hypot(*reference.shape))
    edge_a, edge_b = boundary(a), boundary(b)
    near_a, near_b = distance_to(edge_a), distance_to(edge_b)
    tolerance = max(1.0, BOUNDARY_TOLERANCE * diagonal)
    if edge_a.any() and edge_b.any():
        precision = float((edge_a & (near_b <= tolerance)).sum() / edge_a.sum())
        recall = float((edge_b & (near_a <= tolerance)).sum() / edge_b.sum())
        boundary_f = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
    else:
        boundary_f = 1.0 if not edge_a.any() and not edge_b.any() else 0.0
    differ = (a != b) & valid
    near_edge = (near_a <= EDGE_BAND * diagonal) | (near_b <= EDGE_BAND * diagonal)
    return {
        "iou": (inside_a + inside_b - union) / union if union else 1.0,
        "missed": missed / inside_b if inside_b else 0.0,
        "extra": extra / inside_b if inside_b else (1.0 if extra else 0.0),
        "missedFrame": missed / frame,
        "extraFrame": extra / frame,
        "boundaryF": boundary_f,
        "regionDisagreement": float((differ & ~near_edge).sum()) / frame,
        "edgeDisagreement": float((differ & near_edge).sum()) / frame,
        "softDifference": float(np.abs(candidate - reference)[valid].mean()) if valid.any() else 0.0,
        "candidateShare": inside_a / frame,
        "referenceShare": inside_b / frame,
        "unknownShare": 1 - valid.sum() / valid.size,
    }


def disagreement(m):
    """How much a pair differs, for ranking a review queue: regions first, edges a quarter as much."""
    return m["regionDisagreement"] + 0.25 * m["edgeDisagreement"]


def summary(rows):
    """Per kind: how many photos, median IoU and boundary F, the share of photos whose region
    disagreement passes 1% and 5% of the frame, and the mean edge disagreement."""
    out = {}
    for kind in sorted({r["kind"] for r in rows}):
        of = [r["metrics"] for r in rows if r["kind"] == kind]
        if not of:
            continue
        region = np.array([m["regionDisagreement"] for m in of])
        out[kind] = {
            "photos": len(of),
            "medianIoU": float(np.median([m["iou"] for m in of])),
            "medianBoundaryF": float(np.median([m["boundaryF"] for m in of])),
            "regionOver1pc": float((region > 0.01).mean()),
            "regionOver5pc": float((region > 0.05).mean()),
            "meanEdgeDisagreement": float(np.mean([m["edgeDisagreement"] for m in of])),
        }
    return out
