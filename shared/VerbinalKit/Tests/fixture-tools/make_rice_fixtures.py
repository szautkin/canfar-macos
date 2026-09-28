#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Copyright (C) 2025-2026 Serhii Zautkin
"""Rice (fpack RICE_1) fixtures written by cfitsio, through astropy.

Each image is written twice: compressed (`riceNN.fits.fz`) and plain
(`riceNN.fits`), so a test can decode the one and compare it with the
other value for value. Every image has three bands of rows, one per kind
of Rice block: flat (a block of zero differences), a smooth ramp (ordinary
Rice codes), and noise across the whole range (high-entropy blocks, whose
values are stored raw — the case the decoder used to lack). Tiles are one
row each, as CFHT's fpack files have them, except `rice16tiles`, which
uses 16 × 16 tiles.

Run from this folder:  python3 make_rice_fixtures.py
"""
import os
import numpy as np
from astropy.io import fits

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "VerbinalKitTests", "Fixtures")
W, H = 64, 48


def image(dtype, lo, hi, seed):
    rng = np.random.default_rng(seed)
    img = np.zeros((H, W), dtype=np.int64)
    img[0:16, :] = 7 + lo if lo >= 0 else 7
    img[16:32, :] = (np.arange(W)[None, :] * 3 + np.arange(16)[:, None]) + max(lo, 0)
    img[32:48, :] = rng.integers(lo, hi, size=(16, W), endpoint=True)
    return img.astype(dtype)


def write(name, data, tile_shape):
    fits.PrimaryHDU(data).writeto(os.path.join(OUT, name + ".fits"), overwrite=True)
    fits.HDUList([fits.PrimaryHDU(), fits.CompImageHDU(data, compression_type="RICE_1", tile_shape=tile_shape)]
                 ).writeto(os.path.join(OUT, name + ".fits.fz"), overwrite=True)


os.makedirs(OUT, exist_ok=True)
# Unsigned 16-bit, as CFHT's raw frames are: stored as int16 with BZERO 32768.
write("rice16", image(np.uint16, 0, 65535, 16), (1, W))
write("rice16tiles", image(np.uint16, 0, 65535, 17), (16, 16))
write("rice32", image(np.int32, -2**31, 2**31 - 1, 32), (1, W))
write("rice8", image(np.uint8, 0, 255, 8), (1, W))
print("written to", os.path.normpath(OUT))
