"""Ratings from pairwise comparisons, and the Selector's diversity and plateau rules."""

from __future__ import annotations

import math


def bradley_terry(items: list[str], comparisons: list[tuple[str, str, str | None]], iterations: int = 200,
                  prior: float = 0.5) -> dict[str, float]:
    """Bradley-Terry strengths by the MM algorithm, returned as log-strengths (0 = average).

    `comparisons` are (a, b, winner) with winner None for a tie (half a win each). A small
    prior (a virtual tie against an average opponent) keeps unbeaten items finite.
    """
    if not items:
        return {}
    strength = {item: 1.0 for item in items}
    wins = {item: prior for item in items}
    pairs: dict[tuple[str, str], float] = {}
    for a, b, winner in comparisons:
        if a not in strength or b not in strength or a == b:
            continue
        key = (a, b) if a < b else (b, a)
        pairs[key] = pairs.get(key, 0) + 1
        if winner is None:
            wins[a] += 0.5
            wins[b] += 0.5
        elif winner in (a, b):
            wins[winner] += 1
    for _ in range(iterations):
        updated = {}
        for item in items:
            denominator = prior * 2 / (strength[item] + 1.0)
            for (a, b), count in pairs.items():
                if item == a:
                    denominator += count / (strength[a] + strength[b])
                elif item == b:
                    denominator += count / (strength[a] + strength[b])
            updated[item] = wins[item] / denominator if denominator > 0 else strength[item]
        mean = math.exp(sum(math.log(value) for value in updated.values()) / len(updated))
        strength = {item: value / mean for item, value in updated.items()}
    return {item: math.log(value) for item, value in strength.items()}


def diversity_penalty(distance_to_library: float, threshold: float = 0.35, weight: float = 2.0) -> float:
    """How much to subtract from a candidate's rating for being too close to a recipe the
    library already has (fingerprint distance below `threshold`)."""
    return weight * max(0.0, threshold - distance_to_library) / threshold


def plateaued(best_by_iteration: list[float], patience: int = 2, epsilon: float = 0.05) -> bool:
    """No real improvement in the best rating for `patience` iterations."""
    if len(best_by_iteration) <= patience:
        return False
    recent = best_by_iteration[-patience:]
    before = max(best_by_iteration[:-patience])
    return max(recent) < before + epsilon
