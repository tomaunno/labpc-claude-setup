# labpc の参照資料

[SKILL.md](SKILL.md) から引く。

## しくみ

- この PC から対象機へは、Windows に付いている PowerShell Remoting(WinRM)を Kerberos でつなぐ。この PC にログインしている本人のチケットをそのまま使うので、パスワードは要らないし、保存もしない。学内のプロキシは迂回する。
- ジョブは対象機の **自分の RDP のセッションの中** で、タスク スケジューラ(`schtasks /it`)から動く。Lumerical と Zemax は、画面の無いバックグラウンド(session 0)からはライセンスの都合で起動できないため。
- ジョブのフォルダは対象機の `<自分のホーム>\labpc_jobs\<ジョブ名>`。スクリプトと `-Files` のファイルがそこに送られ、そこをカレントにして動く。ログは `_log.txt`、状態は `_status.txt`。
- ライセンスサーバなど機ごとの環境変数は、ジョブのプロセスにだけ設定する(対象機の設定は変えない。ほかの人に影響しない)。

## コマンド

`labpc <コマンド> <機> …`。

| コマンド | すること |
|---|---|
| `hosts` | 使える機の一覧 |
| `check <機>` | つながるか、自分の RDP のセッションがあるか、Python・lumapi・Zemax があるか |
| `load <機>` | 混み具合と、今 submit で使えるスレッド数・メモリ |
| `submit <機> <ファイル> [-Files a,b] [-Job 名前] [-Threads N] [-Tool 名前] [-Wait] [引数 …]` | 送って動かす。`.py`・`.mph`・`.ind`・`.bat`・`.cmd`・`.ps1` を送れる(SKILL.md の表)。スレッド数は決まりの上限で頭打ち(`-Threads` で絞れる)。ジョブ名の既定は `<ファイル名>_<月日_時分秒>` |
| `license <機>` | COMSOL のライセンスの空きと、使っている人(いつから) |
| `wait <機> <job>` | 終わるまで待ち、ログの末尾を出す(バックグラウンド実行で使う) |
| `status <機> [job]` | `queued` / `running` / `done exit=N`。job を省くと自分のジョブの一覧 |
| `log <機> <job> [行数]` | ログの末尾 |
| `pull <機> <job> [パターン …] [-Dest フォルダ]` | 取ってくる。既定の行き先は今いるフォルダの `results\<機>\<job>\`。パターンの既定は全部 |
| `clean <機> <job> [-RemoveFiles]` | タスクの登録を消す。`-RemoveFiles` でフォルダも |
| `tidy <機> [-DryRun]` | 取り残されたプロセス(閉じ損ねた Lumerical の画面、OpticStudio など)を止め、途中で死んだジョブに終わりの印を付ける |
| `exec <機> "<PowerShell>"` | 短い PowerShell を対象機で直に動かす(調べもの用。計算はここで起動しない) |

- `-Files` に渡したフォルダは、同じ名前のフォルダとしてジョブのフォルダに入る(`-Files data` → `data\…`)。
- スクリプト名の後ろの引数は、そのままスクリプトに渡る(`labpc submit MS-3 run.py --n 8` → `python run.py --n 8`)。ただし `-t 1` のように `-` 1 つで始まる引数は、labpc 自身の設定(`-Threads` など)と取り違えられるので使わない。スクリプトの引数は `--` で始まる長い形にする。
- スクリプト名とジョブ名は半角の英数字と `_ . -` だけ(対象機の `_run.bat` は ASCII で書くので、日本語や空白は化けて動かない)。
- `submit` は、対象機に自分の RDP のセッションが無ければ投げずに止まる。`wait` と `submit -Wait` は、5 分たっても始まらないときと、待っている間にセッションが消えたとき、待つのをやめてエラーで止まる。
- 同じアカウントで別の会話も投げていることがある。ジョブ名に作業ごとの頭文字を付けると見分けやすい(`-Job a1_sweep`)。

## ジョブの中で使えるもの(`labenv`)

`labpc` がジョブのフォルダに送る `labenv.py` を import する。

| 名前 | 中身 |
|---|---|
| `lumapi` | その機の Lumerical の lumapi。`lumapi.FDTD(hide=True)`・`lumapi.MODE(hide=True)` など。**`hide=True` を必ず付ける** |
| `zemax()` | ZOSPy で OpticStudio を画面なし(standalone)で起動し `(zos, oss)` を返す。終わったら `zos.disconnect()` |
| `run_fsp(paths, procs=, mem_gb=, est_hours=)` | 保存済みの .fsp を FDTD の計算エンジン(MPI 版)で直接解く。空きがあるだけ同時に回し、1 本起動するたびに共有機の決まりを確かめ直す。結果は各 .fsp に入る。戻り値は `[(path, 終了コード, 秒)]`。エンジンの出力は `<fsp>.log` |
| `budget_now()` | 共有機の決まりを今の時点で評価した dict(`Allowed` = 今から新しく使ってよいスレッド数、`MemAllowedGB`、`InWindow` = 平日 12〜18 時の中か、など) |
| `budget()` | submit の時点で使ってよかったスレッド数(`LABPC_THREADS`) |
| `zemax_threads()` | Zemax の光線追跡に使ってよいスレッド数 |

### FDTD の掃引は 3 段で

```python
from labenv import lumapi, run_fsp
with lumapi.FDTD(hide=True) as f:              # 1) 作って保存(画面のライセンスは本数が少ないので短く)
    for r in radii: build(f, r); f.save(f"cell_r{r*1e9:.0f}.fsp")
run_fsp(paths, procs=4, mem_gb=2)              # 2) エンジンを直接、並列に
with lumapi.FDTD(hide=True) as f:              # 3) 読む
    for p in paths: f.load(p); T = f.transmission("T")
```

- `f.run()` や `runjobs` を使わない理由: どちらも計算の資源の設定を、ユーザーごとの設定ファイルに書く。同じアカウントで同時に動く別のジョブ(別の会話のものも)とぶつかる。
- `mem_gb` は 1 本が使うメモリの見込み(既定 2 GB)。大きな 3D の計算は必ず渡す。
- 1 本が数時間かかる計算は `est_hours` を渡す。平日 12〜18 時に食い込むなら、最初から機の半分以内で回す。
- 動く例: `examples\sweep_fdtd.py`(柱の半径を振る単位セル。`labpc submit <機> <その例のパス>` でそのまま動く)。

## 共有機の決まりの中身

`remote\labbudget.ps1` が JSON 1 行で返し、`submit`・`load`・`run_fsp` がそれに従う。

- 使ってよいスレッド数 = 全コア − 動いている計算のコア − いつも空けるコア。平日 12〜18 時は、さらに「機の半分 − 自分が使っている分」で頭打ち。
- 他の人の分は、計算エンジンのプロセスからの推定(MPI 版は 1 プロセス 1 コア、そうでないものはスレッド数 − 4)と、機全体の CPU の実測(2 秒)から自分の分を引いたもの、の大きい方。他の人のプロセスごとの CPU 時間は権限が無く読めないが、機全体の合計は読めるので、他の人の Zemax の光線追跡や Python の計算も数えられる。
- 自分の分は、自分のセッションの全プロセスの CPU 時間を 2 秒あけて測った値と、エンジンから数えた値の大きい方。画面のプロセスの中で走る Lumerical の RCWA や Zemax の光線追跡も数えるため。
- メモリ: 平日 12〜18 時は、自分のセッションのプロセスの合計を全体の半分まで。いつでも 32 GB は空ける。

## Lumerical のつまずき

- **`appOpen error: Failed to start messaging, check licenses`**: 画面(GUI)のライセンスが一時的に足りないことが多い(計算のライセンスは本数に余裕がある)。lumapi を開く段は、数分おいてやり直す仕組みを入れる。続くようなら、対象機の自分の `%APPDATA%\Lumerical\License.ini` を見る(`labpc exec <機> 'Get-Content $env:APPDATA\Lumerical\License.ini'`。単引用符で囲み、手元で展開させない)。正しい中身は `[license]` / `domain=1` / `ansysserver\host=<ライセンスサーバ>` / `default=user` の 4 行。計算エンジンがライセンスを取れなかったとき、このファイルが 2 行に書き換わることがある。そのときは元を控えてから 4 行に書き戻す(自分のアカウントの設定なので、ほかの人には影響しない)。
- **lumapi が止まったまま終わらない**: そのアカウントで初めて Lumerical を起動するとき、画面の無いところで確認の窓を出して待っていることがある。`labpc tidy <機>` で止め、本人に「<機> にリモート デスクトップで入り、Lumerical の FDTD を 1 回開いて、出てきた窓に答えてから閉じてください」と頼む。
- RCWA(`addrcwa`)は画面のプロセスの中で走る。層は `interface absolute positions` で必ず与える(与えないと上側全体が柱の層として扱われる)。波長は `frequency center` で与える(`wavelength span = 0` は効かない)。
- 材料データベースの材料を広い波長で使うと、既定の当てはめが粗く、可視で屈折率が一定になることがある。`copymaterial` で複製し、当てはめの許容誤差を小さくする。

## COMSOL のつまずき

- **同時に使える人数がライセンスで限られる**(何人分あって、誰が使っているかは `labpc license <機>` で分かる)。画面で COMSOL を開いたままの人がいると、その間ほかの誰も動かせない(同じ人なら動かせる)。`submit` は送る前にこれを確かめて止まる。止まったら、本人に「○○ さんが COMSOL を開いたままなので、閉じてもらえるか聞いてください」と伝える。
- バッチ専用の枠(`COMSOLBATCH`)があるときは、`submit` が自動で `-usebatchlic` を付ける(画面用の枠を使わない)。
- 後ろに付けられる主な引数: `-study std1`(解くスタディ)、`-pname r,h -plist 1,2,3`(パラメータの掃引)、`-paramfile 表.txt`、`-nosave`、`-clearsolution`(保存を小さく)。出力は `<名前>_out.mph`。
- `comsolbatch` はモデルのエラーやライセンスの失敗でも終了コード 0 を返す。labpc は `<名前>_out.mph` ができていなければ終了コード 3(失敗)にする。原因はログ(`labpc log`)に書いてある。
- COMSOL のログは Shift-JIS。labpc の `log`・`wait` は自動で読み分ける。
- COMSOL に付いているアプリケーションライブラリの `.mph` の多くは「プレビュー用」で、中身が無く解けない(「これは COMSOL アプリケーションライブラリプレビューファイルです」と出る)。試すなら、本人が COMSOL の画面で作ったモデルか、ライブラリからダウンロードしたものを使う。
- `comsolbatch.exe` は本体を起こす役で、`start` 経由で呼ぶと本体の終わりを待たずに戻る。labpc は直接呼んでいる(`.bat` を自分で書くときも `start` を使わない)。

## RSoft のつまずき

- どのソフトも `<プログラム> -hide <名前>.ind prefix=<名前> wait=0` で、画面を出さずに解いて閉じる。後ろの `名前=値` は `.ind` の記号表を上書きする(パラメータを振るときに使う)。
- **`.ind` の名前を引用符で囲まない**(RSoft は引数を自分で読み、引用符も名前の一部にして「開けない」と止まる)。labpc は名前を英数字だけに限って、囲まずに渡している。
- BeamPROP・DiffractMOD などは、既定で機の全コアを使う。スレッド数の設定(RSoft CAD の Multi-Threading Settings)は**その機の全員に効く**ので変えない。labpc は `start /affinity` で使ってよい数の CPU だけに絞って起動する(`.bat` を自分で書くときは `LABPC_AFFINITY` を使う)。
- FullWAVE の並列版(`fwmpirun`)は別のライセンスが要る(無いと `No such feature exists` で止まる)。labpc はどこでも動く 1 プロセスの `fullwave` で動かす。
- RSoft は自分のログを `log.txt`(ジョブのフォルダ)に足していく。エラーの理由はそこに出る。

## Zemax(OpticStudio)のつまずき

- `zemax()` は OpticStudio を画面なしで起動する。最後に必ず `zos.disconnect()`。光線追跡のスレッド数は `zemax_threads()` に合わせる。
- ジョブのあと OpticStudio・ANSYSHelpViewer・QtWebEngineProcess・ansyscl(ライセンスの補助)が残り、ジョブのフォルダを掴んで消せなくすることがある。ジョブの終わりに自動で片付くが、`clean -RemoveFiles` が「残りファイルあり」と言ったら `tidy` を 1 回。
- そのアカウントで初めて OpticStudio を起動するときに、確認の窓で止まることがある。Lumerical と同じく、本人にリモート デスクトップで 1 回開いてもらう。
- ログの末尾の `*** FRU__delta_init(): Attempt to start when running!` は無害。

## つながらないとき

- **「接続失敗」**: 学内のネットワークにいるか(学外からは届かない)、この PC にドメインのアカウントでログインしているか(`klist` にチケットがあるか)を確かめる。
- **ログが文字化けする・`exec` の出力がとても遅い**: `labpc exec` の中で `Get-Content` を使うと、行ごとに付属の情報まで送るので遅い。`Get-Content … | ForEach-Object { "$_" }` のように文字列にして返す。
- **「アクセスが拒否されました」**: 対象機の Remote Management Users に入っていない。管理者にこの PC へ来てもらえるなら、labpc-claude-setup の `setup/labsetup.ps1 grant`(管理者のアカウントとパスワードを窓に 1 回入れるだけで全部の機に付く)。来られなければ、対象機の管理者に、その機の管理者のターミナル(コマンド プロンプトでも PowerShell でもよい)で `powershell -NoProfile -Command "Add-LocalGroupMember -Group (Get-LocalGroup -SID S-1-5-32-580) -Member '{{ACCOUNT}}'"` を打ってもらう(管理者の権限は付かない。遠隔でコマンドを実行してよい、という許可だけ)。
- **`session: なし`**: SKILL.md の「前提」のとおり、本人にリモート デスクトップで入って切断してもらう。
- 対象機の PowerShell は 5.1。`remote\*.ps1` を直すときは **BOM 付きの UTF-8** で保存する(BOM が無いと日本語が化けて param が効かなくなる)。ログを読むときは `-Encoding UTF8`。
- WinRM の中からは、プロセスの親子関係や他の人の CPU 時間(WMI)が読めない。必要なら、ジョブとして自分のセッションの中で動かす(`tidy` がそうしている)。

## やめるとき

`{{INSTALL_DIR}}` のフォルダと、このスキルのフォルダを消し、ユーザーの環境変数 PATH から `{{INSTALL_DIR}}\bin` を外し、`~/.claude/settings.json` に `labpc` で始まる許可の行があれば消す。対象機に残るのは、自分のホームの `labpc_jobs` と、Lumerical の `License.ini`(Lumerical を手で使うときにも使う設定)だけ。
