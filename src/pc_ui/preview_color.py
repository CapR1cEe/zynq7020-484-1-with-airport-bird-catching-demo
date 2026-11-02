"""Bounded, temporally smoothed white balance for the desktop preview."""
import numpy as np
from PIL import Image


class PreviewWhiteBalance:
    def __init__(self):
        self.gains = None

    def apply(self, image):
        pixels = np.asarray(image.convert('RGB'), dtype=np.float32)
        sample = pixels[::max(1, image.height // 120), ::max(1, image.width // 160)]
        valid = (sample.min(axis=2) > 12) & (sample.max(axis=2) < 248)
        # Shadows and clipped highlights do not provide usable color ratios.
        if np.count_nonzero(valid) >= 32:
            means = sample[valid].mean(axis=0)
            estimate = np.clip(means.mean() / np.maximum(means, 1.0), .55, 1.8)
            if self.gains is None:
                self.gains = estimate
            else:
                self.gains += .2 * (estimate - self.gains)
        elif self.gains is None:
            self.gains = np.ones(3, dtype=np.float32)
        corrected = np.clip(np.rint(pixels * self.gains), 0, 255).astype(np.uint8)
        return Image.fromarray(corrected), [round(float(value), 5) for value in self.gains]
