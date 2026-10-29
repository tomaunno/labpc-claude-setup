"""疎通確認: Lumerical FDTD を画面なしで起動し、小さな計算をして npz に書く。どの機でも共通。"""
import numpy as np
from labenv import lumapi

with lumapi.FDTD(hide=True) as f:
    f.eval("x = linspace(0, 1, 11); y = x^2;")
    x, y = f.getv("x").ravel(), f.getv("y").ravel()
np.savez("smoke_lumerical.npz", x=x, y=y)
print("lumerical OK: sum(y) =", y.sum())
