"""Import stub for MIA-UIB/patchmatch, which is CUDA-only.

Only the Cherel* networks call it; SimpleBlockMatchingUNet (the raw checkpoint) never does.
"""


def patch_match(*args, **kwargs):
    raise NotImplementedError("patchmatch is CUDA-only; use SimpleBlockMatchingUNet")


def stack_matches(*args, **kwargs):
    raise NotImplementedError("patchmatch is CUDA-only; use SimpleBlockMatchingUNet")
