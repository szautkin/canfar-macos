#!/usr/bin/env python3
# Reference values for shared/VerbinalKit/Tests/VerbinalKitTests/SIPDistortionTests.swift.
# A WFC3/UVIS-shaped TAN-SIP header; astropy gives pixel<->sky (origin 0) and
# the AP/BP inverse terms are least-squares fitted to the forward ones.
# Run: python3 scripts/reference/sip_astropy.py   (astropy 7.2, numpy)

import numpy as np, warnings
from astropy.io import fits
from astropy.wcs import WCS
warnings.simplefilter('ignore')
h=fits.Header()
h['NAXIS']=2; h['NAXIS1']=4096; h['NAXIS2']=2051
h['CTYPE1']='RA---TAN-SIP'; h['CTYPE2']='DEC--TAN-SIP'
h['CRPIX1']=2048.0; h['CRPIX2']=1026.0
h['CRVAL1']=150.1163213; h['CRVAL2']=2.2009211
h['CD1_1']=-8.5e-06; h['CD1_2']=-9.8e-06; h['CD2_1']=-1.02e-05; h['CD2_2']=8.1e-06
A={(2,0):-2.9e-07,(1,1):6.1e-07,(0,2):-2.2e-06,(3,0):1.1e-11,(2,1):-3.0e-11,(1,2):1.8e-11,(0,3):-2.4e-11,(4,0):2.0e-15,(2,2):-4.0e-15,(0,4):3.0e-15}
B={(2,0):4.4e-07,(1,1):-1.9e-06,(0,2):5.3e-07,(3,0):-1.5e-11,(2,1):2.2e-11,(1,2):-2.7e-11,(0,3):1.3e-11,(4,0):-1.0e-15,(1,3):2.5e-15,(0,4):-2.0e-15}
h['A_ORDER']=4; h['B_ORDER']=4
for (p,q),c in A.items(): h[f'A_{p}_{q}']=c
for (p,q),c in B.items(): h[f'B_{p}_{q}']=c
pts=[(0,0),(4095,0),(0,2050),(4095,2050),(2047,1025),(1000,1500),(3500,300),(2047.5,1025.5)]
w=WCS(h)
def fmt(v): return repr(float(v))
fwd=[w.all_pix2world([[x,y]],0)[0] for x,y in pts]
h2=h.copy()
for k in list(h2.keys()):
    if k.startswith(('A_','B_')): del h2[k]
h2['CTYPE1']='RA---TAN'; h2['CTYPE2']='DEC--TAN'
w2=WCS(h2)
lin=[w2.all_pix2world([[x,y]],0)[0] for x,y in pts]
off=[np.hypot(*(np.array(w.all_world2pix([f],0)[0])-np.array(w2.all_world2pix([f],0)[0]))) for f in fwd]
print('// header A/B:', {f'A_{p}_{q}':c for (p,q),c in A.items()})
print('max SIP offset px', max(off))
# inverse check
inv=[w.all_world2pix([f],0,tolerance=1e-12,maxiter=50)[0] for f in fwd]
print('inv err', max(np.hypot(*(np.array(i)-np.array(p))) for i,p in zip(inv,pts)))
# fit AP/BP order 4 on grid
uu,vv=np.meshgrid(np.linspace(-2048,2048,41),np.linspace(-1026,1026,21)); u=uu.ravel(); v=vv.ravel()
def poly(coefs,u,v): return sum(c*u**p*v**q for (p,q),c in coefs.items())
U=u+poly(A,u,v); V=v+poly(B,u,v)
terms=[(p,q) for p in range(5) for q in range(5) if 1<=p+q<=4 or p+q==0]
M=np.stack([U**p*V**q for p,q in terms],1)
ap=np.linalg.lstsq(M,u-U,rcond=None)[0]; bp=np.linalg.lstsq(M,v-V,rcond=None)[0]
AP={t:c for t,c in zip(terms,ap)}; BP={t:c for t,c in zip(terms,bp)}
print('AP resid px', np.abs(M@ap-(u-U)).max())
print('SWIFT_FWD')
for (x,y),(ra,dec) in zip(pts,fwd): print(f'        (x: {fmt(x)}, y: {fmt(y)}, ra: {fmt(ra)}, dec: {fmt(dec)}),')
print('SWIFT_AP')
print(', '.join(f'"AP_{p}_{q}": {fmt(c)}' for (p,q),c in AP.items()))
print(', '.join(f'"BP_{p}_{q}": {fmt(c)}' for (p,q),c in BP.items()))
