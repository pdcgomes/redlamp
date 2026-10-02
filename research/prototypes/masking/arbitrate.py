"""Sky from Segment Anything and Depth Anything 3: averaged where they broadly agree; when one
covers under 30% of the other's sky, it missed the sky and the other is used alone."""
import numpy as np


def arbitrate(sam, da3, share=0.3):
    a, b = (sam > 0.5).sum(), (da3 > 0.5).sum()
    if b < share * a:
        return sam
    if a < share * b:
        return da3
    return (sam + da3) / 2
