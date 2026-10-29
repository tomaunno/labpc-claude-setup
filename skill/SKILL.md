---
name: labpc
description: 研究室の共有 Windows 機({{HOST_LIST}})で Lumerical(FDTD・RCWA・lumapi)・Zemax OpticStudio(ZOSPy)・COMSOL(.mph をバッチで解く)・RSoft(.ind を BeamPROP・FullWAVE・DiffractMOD などで解く)を動かす作業。計算をジョブとして投げる・待つ・ログを見る・結果を取ってくる・片付ける、機の混み具合を見る、共有機の決まり(他の人の計算から奪わない、平日 12〜18 時は機の半分まで)を守る、COMSOL のライセンスを誰が使っているか見る、つながらない・ライセンスが取れない・Zemax が残るといった不具合を直す。
---

# 研究室の Windows 機で Lumerical / Zemax / COMSOL / RSoft を動かす

{{DATE}} に labpc-claude-setup が {{ACCOUNT}} さんのために書いたスキル。この PC の持ち主のものなので、使い方に合わせて自由に直してよい。全コマンド・ジョブの中で使える関数・つまずく点は [reference.md](reference.md)。

## この PC の設定

| 項目 | 値 |
|---|---|
| アカウント | `{{ACCOUNT}}`(この PC にログインしているドメインのアカウント。Kerberos でつなぐので、パスワードはどこにも保存していない) |
| 道具 | `{{INSTALL_DIR}}`(本体 `labpc.ps1`、機の一覧 `hosts.json`、例 `examples\`) |
| 呼び方 | `labpc <コマンド> …`。「見つからない」と言われたら({{AGENT}} を開き直す前)、PowerShell では `& "{{LABPC_CMD}}" …`、Git Bash では `{{LABPC_SH}} …` |

## 使える機

| 機 | ソフト | 大きさ | 平日 12〜18 時の自分の上限(スレッド) | いつも空けるコア | ジョブの Python |
|---|---|---|---|---|---|
{{HOSTS_TABLE}}

機のソフトの版が上がったり、新しく入ったりしたら、labpc-claude-setup をもう一度走らせると `hosts.json` が書き直される。

## 前提: 対象機に自分の RDP のセッションがあること

Lumerical と Zemax はライセンスの都合で、対象機の「自分のログオンセッション」の中でしか起動できない。ジョブはどのソフトでも、そのセッションの中で動く。`labpc check <機>` が `session: なし` と言ったら、本人にこう頼む:

> <機> にリモート デスクトップ(`mstsc /v:<機の FQDN>`)で、いつものアカウントでログインしてください。デスクトップが出たら、サインアウトはせず、窓の右上の × で閉じて(切断して)ください。

対象機が再起動するとセッションは消えるので、同じことをもう一度頼む。

## 計算を回す

1. **送るファイルを用意する**。`labpc submit` は送ったファイルの種類で動かし方を選ぶ。どれも対象機のジョブのフォルダをカレントにして動く。

   | 送るもの | 動かし方 | 出力 |
   |---|---|---|
   | `.py` | その機の Python(Lumerical・Zemax は下の `labenv` で) | スクリプトが書いたもの |
   | `.mph`(COMSOL のモデル) | `comsolbatch -np <スレッド数>`。後ろに `-study std1`、パラメータの掃引 `-pname r -plist 1,2,3` などを付けられる | `<名前>_out.mph` |
   | `.ind`(RSoft の設計) | `.ind` の `sim_tool` に合うコマンド版(BeamPROP・FullWAVE・DiffractMOD・FemSIM・ModePROP など。`-Tool dfmod` で指定も可)を画面なしで。後ろに `wavelength=1.55` のように変数を付けて上書きできる | `prefix=<名前>` の各ファイルと `log.txt` |
   | `.bat`・`.cmd`・`.ps1` | そのまま(自由な手順。`LABPC_THREADS`・`LABPC_AFFINITY`・`LABPC_COMSOL`・`LABPC_RSOFT` の環境変数が使える) | 手順しだい |

   COMSOL と RSoft のつまずく点(ライセンスの人数、ログ、付属の例題)は reference.md。Python のスクリプトは次のように書く:

   ```python
   from labenv import lumapi              # その機の lumapi を読み込む
   with lumapi.FDTD(hide=True) as f:      # hide=True を必ず付ける(画面を出さない)
       ...

   from labenv import zemax
   zos, oss = zemax()                     # ZOSPy で OpticStudio を起動。最後に zos.disconnect()
   ```

   FDTD の掃引は「lumapi で .fsp を作って保存 → `run_fsp` で計算エンジンを並列に回す → lumapi で読む」の 3 段で書く。`f.run()` や `runjobs` は使わない(理由と書き方は reference.md、例は `{{INSTALL_DIR}}\examples\sweep_fdtd.py`)。
2. **空きを見る**: `labpc load <機>`。
3. **投げる**: `labpc submit <機> <ファイル> [-Files 付けるファイルやフォルダ,…] [-Job 名前] [後ろに付ける引数 …]`。COMSOL は、送る前にライセンスの空きを確かめ、他の人が使っていれば投げずに止まる(`labpc license <機>` で誰が使っているかを見られる)。使うスレッド数は共有機の決まりから自動で決まり、ジョブには `LABPC_THREADS` で渡る。空きが足りなければ投げずに止まる。自分の RDP のセッションが無いときも止まる(上の「前提」)。スクリプト名とジョブ名は半角の英数字と `_ . -` だけ。スクリプトへの引数は `--n 8` のように `--` で始まる形にする(`-t 1` のような 1 文字の形は labpc 自身の設定と取り違えられる)。
4. **待つ**: `labpc wait <機> <ジョブ名>` をバックグラウンド実行で動かす(終わるとログの末尾を出す)。数秒〜数十秒おきに `status` を打って見張らない。数分で終わる小さなジョブなら `submit … -Wait` でもよい。どちらも、5 分たってもジョブが始まらないときと、自分のセッションが消えたとき(対象機の再起動など)は、待つのをやめてエラーで止まる。そのときは `labpc check <機>` で確かめ、セッションが無ければ本人に入り直してもらう。
5. **結果を見る・取ってくる**: `labpc log <機> <ジョブ名> 50`、`labpc pull <機> <ジョブ名> '*.npz' '*.json'`(今いるフォルダの `results\<機>\<ジョブ名>\` に入る)。大きな .fsp は対象機の上で読み出して小さな npz にしてから取ってくる。
6. **片付ける**: 取ってきたら `labpc clean <機> <ジョブ名> -RemoveFiles`。

ほかに `labpc license <機>`(COMSOL のライセンスを誰が使っているか)、`labpc status <機>`(自分のジョブの一覧)、`labpc tidy <機>`(取り残されたプロセスを止める。`-DryRun` で一覧だけ)、`labpc exec <機> "<PowerShell の 1 行>"`、`labpc hosts`。Git Bash では `*` を含むパターンを引用符で囲む(手元で展開されてしまうため)。

## 共有機の決まり(submit と run_fsp が自動で守る)

研究室の全員で使っている機なので、次を守る。中身は `{{INSTALL_DIR}}\remote\labbudget.ps1` の 1 か所に書いてある。

- **他の人の計算から奪わない**: 使うのは「全コア − 動いている計算のコア − いつも空けるコア」まで。自分の別のジョブ(別の会話のものも)も「動いている」側に数える。COMSOL は `-np`、RSoft は使ってよい数の CPU だけに絞って起動する(RSoft の機ごとのスレッド数の設定は全員に効くので変えない)。
- **COMSOL は同時に使える人数がライセンスで限られる**(`labpc license <機>` で分かる)。画面で開いたままにすると、その間ほかの誰も COMSOL を動かせない。使い終わったら閉じるよう本人にも伝える。
- **平日 12〜18 時は、自分(このアカウント)の合計を機の半分まで**。メモリも自分の合計を全体の半分まで。いつでも 32 GB は空ける。それ以外の時間は空いている分をほぼ全部使ってよい。祝日は平日と同じに扱う。
- 決まりを避けるためにスレッド数を手で盛ったり、`exec` で計算を直接起動したりしない。
- **使いっぱなしにしない**: 回収が済んだジョブは `clean -RemoveFiles`。ジョブの終わりには取り残されたプロセスが自動で片付く。

## 本人とのやりとり

本人はプログラムに詳しくないことがある。どの機で何を回すか、どれくらい待つか、混んでいて待っているのか、結果がどうだったかを、普通の言葉で伝える。エラーの文字はそのまま見せず、何が起きたかと次に何をするかを伝える。
