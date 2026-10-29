"""対象機のジョブスクリプトから import する補助(labpc.ps1 が PYTHONPATH に入れる)。

    from labenv import lumapi          # 対象機の lumapi(LABPC_LUMAPI のフォルダを自動で追加)
    with lumapi.FDTD(hide=True) as f:  # hide=True 必須(画面を出さない)
        ...

    from labenv import zemax
    zos, oss = zemax()                 # ZOSPy で OpticStudio を standalone 起動。最後に zos.disconnect()

    from labenv import run_fsp, budget_now
    run_fsp(["a.fsp", "b.fsp", ...], procs=4)   # 保存済みの .fsp を FDTD エンジンで直接並列実行。
                                                # 1 本起動するたびに共有機の決まり(labbudget.ps1)を
                                                # その場で確かめ、空きがあるだけ同時に回す。結果は各 .fsp に入る
    run_fsp(["big.fsp"], procs=64, est_hours=5) # 長い計算は所要時間の見込みを渡す。平日 12〜18 時の
                                                # 制限帯に食い込むなら最初から半分以内で回す

環境変数(labpc.ps1 が host 登録簿から設定する):
    LABPC_LUMAPI       lumapi.py のあるフォルダ
    LABPC_ZEMAX_ROOT   ZOS-API の DLL のあるフォルダ
    LABPC_THREADS      submit 時点で使ってよかったスレッド数(目安。実際は budget_now() で都度確かめる)
    LABPC_LIB / LABPC_MARGIN / LABPC_HALFCAP   決まりのスクリプトの場所と、その機の Margin・HalfCap
    (budget_now() はメモリの MemAllowedGB も返す。平日 12〜18 時は自分の合計を全体の半分まで、常に 32 GB は空ける)
    ANSYSLMD_LICENSE_FILE など  ライセンスサーバ(host ごと)

ジョブが終わると labpc の _run.bat が labtidy.ps1 を呼び、このジョブが取り残したプロセス
(閉じ損ねた Lumerical の GUI、Zemax の OpticStudio など)を止める。
"""
import glob
import json
import os
import subprocess
import sys
import time

_lum = os.environ.get("LABPC_LUMAPI")
if _lum and _lum not in sys.path:
    sys.path.append(_lum)

try:
    import lumapi  # noqa: F401
except Exception as e:               # Zemax だけのジョブでは失敗してもよい
    lumapi = None
    _lumapi_error = e


def budget():
    """submit 時点で使ってよかったスレッド数(LABPC_THREADS。無ければ 4)。いまの値は budget_now()。"""
    return max(1, int(os.environ.get("LABPC_THREADS", "4")))


def budget_now():
    """共有機の決まり(labbudget.ps1)を今この瞬間で評価した dict。
    Allowed = 今から新しく使ってよいスレッド数(自分の動いているエンジンは Busy/Mine に数え済み)、
    InWindow = 平日 12〜18 時の制限中か、HoursToWindow = 次の制限までの時間、HalfCap など。"""
    lib = os.environ.get("LABPC_LIB")
    try:
        r = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                            os.path.join(lib, "labbudget.ps1"), "-Margin", os.environ.get("LABPC_MARGIN", "4"),
                            "-HalfCap", os.environ.get("LABPC_HALFCAP", "0")],
                           capture_output=True, text=True, timeout=120)
        return json.loads(r.stdout.strip().splitlines()[-1])
    except Exception as e:                 # 決まりを確かめられないときは submit 時点の値で控えめに
        return {"Allowed": budget(), "InWindow": True, "HoursToWindow": 0, "HalfCap": budget(), "error": str(e)}


def _engine():
    root = os.path.dirname(os.path.dirname(os.environ["LABPC_LUMAPI"]))   # ...\Lumerical\v25x
    eng = os.path.join(root, "bin", "fdtd-engine-msmpi.exe")
    mpi = (glob.glob(r"C:\Program Files\Microsoft MPI\Bin\mpiexec.exe")
           + glob.glob(os.path.join(root, "bin", "mpiexec.exe")))[0]
    return eng, mpi


def run_fsp(paths, procs=None, log=print, est_hours=None, mem_gb=2.0, poll=60):
    """保存済みの .fsp を FDTD エンジン(MS-MPI 版)で直接実行する。lumapi の job manager を通さない
    (資源設定をユーザー単位の設定ファイルに書かないので、別の会話のジョブとぶつからない)。

    procs: 1 本あたりの MPI プロセス数(各 1 スレッド)。省略時は submit 時点の budget()。
    1 本起動する前に毎回 budget_now() を確かめ、Allowed ≥ procs のときだけ起動する(他の人が計算を
    始めたり、平日 12〜18 時の制限帯に入ったりしたら、新しい起動を控えて自然に絞られる)。
    est_hours: 1 本の所要時間の見込み。制限帯に食い込むなら procs を最初から HalfCap 以内にする。
    mem_gb: 1 本が使うメモリの見込み [GB](大きい計算は必ず渡す)。MemAllowedGB がこれ以上のときだけ起動する。
    戻り値: [(path, returncode, 秒)](paths の順)。エンジンの出力は <fsp>.log に残る。
    """
    eng, mpi = _engine()
    paths = [os.path.abspath(p) for p in paths]
    b = budget_now()
    procs = max(1, int(procs or budget()))
    procs = min(procs, max(1, int(b.get("Cores", procs)) - int(os.environ.get("LABPC_MARGIN", "4"))))
    if b.get("InWindow") and b.get("HalfCap"):
        procs = min(procs, int(b["HalfCap"]))
    if est_hours and b.get("HalfCap") and not b.get("InWindow") and b.get("HoursToWindow", 0) < est_hours:
        procs = min(procs, int(b["HalfCap"]))
        log(f"[run_fsp] 制限帯まで {b['HoursToWindow']} h < 見込み {est_hours} h なので 1 本 {procs} プロセスに抑える")
    log(f"[run_fsp] {len(paths)} 本、1 本 {procs} プロセス。起動のたびに空きを確かめる(今の Allowed {b.get('Allowed')})")
    pending = list(enumerate(paths))
    running = {}                     # idx -> (Popen, t0, logfile)
    done = {}
    last_launch = 0.0
    while pending or running:
        for k, (pr, t0, lf) in list(running.items()):
            if pr.poll() is not None:
                lf.close()
                dt = time.time() - t0
                p = paths[k]
                if pr.returncode != 0:
                    tail = open(p + ".log", encoding="utf-8", errors="replace").read().splitlines()[-8:]
                    log(f"[run_fsp] 失敗 rc={pr.returncode} {p}\n" + "\n".join(tail))
                else:
                    log(f"[run_fsp] {os.path.basename(p)}  {dt:.1f} s  ({procs} proc)")
                done[k] = (p, pr.returncode, dt)
                del running[k]
        if pending and time.time() - last_launch > 15:       # 起動直後のエンジンが一覧に出るまで待ってから数える
            b = budget_now()
            if b.get("Allowed", 0) >= procs and b.get("MemAllowedGB", 1e9) >= mem_gb:
                k, p = pending.pop(0)
                lf = open(p + ".log", "w", encoding="utf-8", errors="replace")
                pr = subprocess.Popen([mpi, "-n", str(procs), eng, "-t", "1", p], stdout=lf, stderr=subprocess.STDOUT)
                running[k] = (pr, time.time(), lf)
                last_launch = time.time()
                continue
            if not running:
                log(f"[run_fsp] 空き待ち(Allowed {b.get('Allowed')} / {procs} スレッド、メモリ {b.get('MemAllowedGB')} / {mem_gb} GB、{b.get('Now')})")
        time.sleep(5 if running else poll)
    return [done[k] for k in sorted(done)]


def zemax_threads():
    """Zemax の光線追跡に使ってよいスレッド数(今の決まりで。最低 1)。"""
    return max(1, int(budget_now().get("Allowed", budget())))


def zemax(root=None):
    """ZOSPy で OpticStudio を standalone 起動し (zos, oss) を返す。"""
    import zospy as zp
    root = root or os.environ.get("LABPC_ZEMAX_ROOT")
    zos = zp.ZOS(opticstudio_directory=root)
    oss = zos.connect("standalone")
    return zos, oss
