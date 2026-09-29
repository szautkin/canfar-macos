#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Copyright (C) 2025-2026 Serhii Zautkin
"""Spectrum tables written by astropy, in the shapes archives use.

- `x1d-echelle.fits`: an HST `_x1d` — an empty primary HDU, then a SCI
  table with an array per row (one echelle order each, highest first):
  SPORDER (with TNULL), WAVELENGTH (D, Angstroms), FLUX and ERROR (E),
  DQ (I). One flux value is NaN.
- `x1d-rows.fits`: a JWST `x1d` — a number per row: WAVELENGTH (um),
  FLUX (Jy) and FLUX_ERROR, with integer FLUX scaled by TSCAL/TZERO in a
  second copy of the flux, FLUXSCALED.
- `table-no-spectrum.fits`: a catalogue — RA, DEC, MAG and a NAME.

Run from this folder:  python3 make_spectrum_fixtures.py
"""
import os
import numpy as np
from astropy.io import fits

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "VerbinalKitTests", "Fixtures")


def echelle():
    n = 8
    orders = [(301, 1200.0), (300, 1190.0)]  # highest order first, as STIS writes them
    wave = np.array([start + 0.5 * np.arange(n) for _, start in orders])
    flux = np.array([1e-14 * (1 + 0.1 * np.arange(n)), 2e-14 * (1 + 0.1 * np.arange(n))], dtype=np.float32)
    flux[1, 3] = np.nan
    error = (flux * 0.05).astype(np.float32)
    cols = [
        fits.Column(name="SPORDER", format="1I", null=-32767, array=np.array([o for o, _ in orders], dtype=np.int16)),
        fits.Column(name="WAVELENGTH", format=f"{n}D", unit="Angstroms", array=wave),
        fits.Column(name="FLUX", format=f"{n}E", unit="erg/s/cm**2/Angstrom", array=flux),
        fits.Column(name="ERROR", format=f"{n}E", unit="erg/s/cm**2/Angstrom", array=error),
        fits.Column(name="DQ", format=f"{n}I", null=-32767, array=np.zeros((2, n), dtype=np.int16)),
    ]
    table = fits.BinTableHDU.from_columns(cols, name="SCI")
    fits.HDUList([fits.PrimaryHDU(), table]).writeto(os.path.join(OUT, "x1d-echelle.fits"), overwrite=True)


def rows():
    n = 20
    wave = np.linspace(1.0, 2.9, n)
    flux = 1e-3 * (1 + wave)
    cols = [
        fits.Column(name="WAVELENGTH", format="D", unit="um", array=wave),
        fits.Column(name="FLUX", format="D", unit="Jy", array=flux),
        fits.Column(name="FLUX_ERROR", format="D", unit="Jy", array=flux * 0.01),
        # Stored as integers, read as 1e-6 * stored + 0.001 once TSCAL/TZERO are set below.
        fits.Column(name="FLUXSCALED", format="J", array=np.round((flux - 0.001) / 1e-6).astype(np.int32)),
    ]
    table = fits.BinTableHDU.from_columns(cols, name="EXTRACT1D")
    path = os.path.join(OUT, "x1d-rows.fits")
    fits.HDUList([fits.PrimaryHDU(), table]).writeto(path, overwrite=True)
    fits.setval(path, "TSCAL4", value=1e-6, ext=1)
    fits.setval(path, "TZERO4", value=0.001, ext=1)


def catalogue():
    cols = [
        fits.Column(name="RA", format="D", unit="deg", array=np.array([10.68, 10.70])),
        fits.Column(name="DEC", format="D", unit="deg", array=np.array([41.27, 41.28])),
        fits.Column(name="MAG", format="E", array=np.array([12.5, 13.1], dtype=np.float32)),
        fits.Column(name="NAME", format="8A", array=np.array(["M31", "M32"])),
    ]
    table = fits.BinTableHDU.from_columns(cols, name="CATALOG")
    fits.HDUList([fits.PrimaryHDU(), table]).writeto(os.path.join(OUT, "table-no-spectrum.fits"), overwrite=True)


if __name__ == "__main__":
    echelle()
    rows()
    catalogue()
    # What astropy reads back is what the Swift tests expect.
    with fits.open(os.path.join(OUT, "x1d-rows.fits")) as h:
        scaled = h[1].data["FLUXSCALED"]
        assert np.allclose(scaled, h[1].data["FLUX"], atol=1e-6), scaled
    print("written to", os.path.normpath(OUT))
