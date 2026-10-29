"""例: 柱の半径を振る単位セルの FDTD を「作って保存 → run_fsp で並列に解く → 読む」の 3 段で回す。

    labpc submit MS-3 sweep_fdtd.py

条件(例なので小さく粗い): 波長 633 nm、正方格子の周期 300 nm、高さ 600 nm の柱(屈折率 2.0)を
屈折率 1.45 の基板に置き、空気側から垂直に入射する。半径ごとの透過率と、柱なしに対する透過光の位相を出す。
研究に使うときは、メッシュ・計算時間・材料を自分の問題に合わせて決め直す。
"""
import numpy as np
from labenv import lumapi, run_fsp

WL, P, H = 633e-9, 300e-9, 600e-9
RADII = [0.0, 60e-9, 80e-9, 100e-9]          # 0 = 柱なし(位相の基準)


def build(f, r):
    f.switchtolayout()
    f.deleteall()
    f.addfdtd(x=0, y=0, x_span=P, y_span=P, z_min=-0.6e-6, z_max=H + 0.8e-6)
    f.setnamed("FDTD", "x min bc", "Periodic")
    f.setnamed("FDTD", "y min bc", "Periodic")
    f.setnamed("FDTD", "mesh accuracy", 2)
    f.setnamed("FDTD", "simulation time", 500e-15)
    f.addrect(name="sub", x=0, y=0, x_span=2 * P, y_span=2 * P, z_min=-2e-6, z_max=0)
    f.setnamed("sub", "material", "<Object defined dielectric>")
    f.setnamed("sub", "index", 1.45)
    if r > 0:
        f.addcircle(name="pil", x=0, y=0, radius=r, z_min=0, z_max=H)
        f.setnamed("pil", "material", "<Object defined dielectric>")
        f.setnamed("pil", "index", 2.0)
    f.addplane(name="src", injection_axis="z", direction="Backward", x=0, y=0, x_span=2 * P, y_span=2 * P,
               z=H + 0.5e-6, wavelength_start=WL, wavelength_stop=WL)
    f.addpower(name="T", monitor_type="2D Z-normal", x=0, y=0, x_span=P, y_span=P, z=-0.4e-6)
    f.setglobalmonitor("frequency points", 1)


# 1) 作って保存する(画面を出さない。GUI のライセンスは本数が少ないので、開くのは短く)
paths = []
with lumapi.FDTD(hide=True) as f:
    for r in RADII:
        build(f, r)
        p = f"cell_r{r * 1e9:.0f}.fsp"
        f.save(p)
        paths.append(p)

# 2) 計算エンジンを直接、空きがあるだけ並列に回す(1 本 4 プロセス。共有機の決まりを起動のたびに確かめる)
for p, rc, sec in run_fsp(paths, procs=4, mem_gb=1):
    print(f"{p}: rc={rc} {sec:.0f} s", flush=True)

# 3) 読み出す
rows = []
with lumapi.FDTD(hide=True) as f:
    for r, p in zip(RADII, paths):
        f.load(p)
        T = abs(float(np.real(np.asarray(f.transmission("T")).ravel()[0])))
        ex = complex(np.asarray(f.getdata("T", "Ex")).squeeze().mean())
        rows.append((r, T, ex))

r = np.array([x[0] for x in rows])
T = np.array([x[1] for x in rows])
ex = np.array([x[2] for x in rows])
phase = np.angle(ex / ex[0])
np.savez("sweep_fdtd.npz", r=r, T=T, ex=ex, phase=phase)
for a, b, c in zip(r, T, phase):
    print(f"r = {a * 1e9:5.1f} nm   T = {b:.4f}   phase = {c:+.3f} rad")
print("sweep OK")
