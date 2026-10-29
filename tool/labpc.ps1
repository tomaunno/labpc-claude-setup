<#
.SYNOPSIS
  研究室の共有 Windows 機(MS-3 / MS-4 …)で Lumerical / Zemax などをスクリプト実行する CLI。

.DESCRIPTION
  接続は Windows 標準の PowerShell Remoting(WinRM)を Kerberos で使う。
  このPC(研究室のドメインに参加した Windows)に今ログインしている本人の Kerberos チケットを
  そのまま使うので、パスワードは保存しない。学内のプロキシは迂回する。

  ジョブは対象機の「自分のログオンセッション」の中で schtasks /it で走らせる。
  Lumerical / Zemax はライセンスの都合で session 0(バックグラウンド)からは起動できないため。
  → 対象機に自分が RDP でログイン(切断状態でよい)している必要がある。`check` で確認できる。

  対象機の一覧は同じフォルダの hosts.json(labpc-claude-setup の install が対象機を調べて書く)。
  使い方は Claude のスキル labpc を参照。

.EXAMPLE
  labpc hosts
  labpc check MS-3
  labpc submit MS-3 smoke_lumerical.py -Wait
  labpc pull MS-3 smoke_lumerical_1029_120000 '*.npz'
#>
# 位置引数は先頭 3 つだけ。4 つ目以降はすべて $Rest に入る
# (pull のパターン複数・log の行数・submit のスクリプト引数)。
# PositionalBinding を切らないと、余った位置引数が -Files などに黙って入る。
[CmdletBinding(PositionalBinding = $false)]
param(
  [Parameter(Mandatory, Position = 0)][string]$Command,
  [Parameter(Position = 1)][string]$Host_,
  [Parameter(Position = 2)][string]$Path,
  [Parameter(ValueFromRemainingArguments)][string[]]$Rest,
  [string[]]$Files,
  [string]$Job,
  [string]$Dest,
  [switch]$Wait,
  [int]$Interval = 15,
  [switch]$RemoveFiles,
  [int]$Threads = 0,          # submit: 使いたいスレッド数(決まりの上限で頭打ち。0 = 上限いっぱい)
  [string]$Tool,              # submit で .ind を送るとき: RSoft のソフト(bsimw32 / fullwave / dfmod / femsim / modeprop …)。省けば .ind の sim_tool から
  [switch]$DryRun             # tidy: 止めずに一覧だけ出す
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8   # labpc.cmd 経由で呼ばれても日本語が化けないように
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---- 対象機の登録簿(hosts.json) -------------------------------------------------
# Fqdn     : 対象機の正式な名前
# Python   : ジョブを回す python.exe(Lumerical 同梱でも可)
# Lumapi   : lumapi.py のあるフォルダ(スクリプトの sys.path に入る)
# ZemaxRoot: ZOS-API の DLL があるフォルダ(無ければ空)
# Comsol   : comsolbatch.exe(無ければ空)。.mph を送るとこれで解く
# RSoft    : RSoft のコマンド版(bsimw32.exe など)のあるフォルダ(無ければ空)。.ind を送るとこれで解く
# Env      : ジョブのプロセスにだけ設定する環境変数(ライセンスサーバ等。対象機の永続設定は変えない)
# Margin   : 他の人のために常に空けておくコア数
# HalfCap  : 平日 12〜18 時に自分(このアカウント)が使ってよいスレッド数の合計(機の半分)
#            決まりの中身は remote\labbudget.ps1 に 1 か所だけ書いてある
$HostsFile = Join-Path $Here 'hosts.json'
if (-not (Test-Path $HostsFile)) { throw "対象機の一覧 $HostsFile がありません。labpc-claude-setup の install で作られます。" }
$HOSTS = @{}
foreach ($p in (Get-Content $HostsFile -Raw -Encoding UTF8 | ConvertFrom-Json).hosts.PSObject.Properties) {
  $h = @{}; foreach ($q in $p.Value.PSObject.Properties) { $h[$q.Name] = $q.Value }
  $e = @{}; if ($h.Env) { foreach ($q in $h.Env.PSObject.Properties) { $e[$q.Name] = [string]$q.Value } }
  $h.Env = $e
  $HOSTS[$p.Name] = $h
}
$MINTHREADS = 2                                # これ未満しか空いていなければ submit しない
$LIBREL  = '_lib'                              # labenv.py などの置き場(PYTHONPATH に入る)
$JOBROOT = $null                               # 対象機側のジョブ置き場(接続したときに決まる: <対象機のホーム>\labpc_jobs)
$TASKPFX = "labpc_$($env:USERNAME)_"           # schtasks の名前は機全体で共有なので、利用者名を入れて他の人とぶつからないようにする

function Get-HostDef([string]$name) {
  if (-not $name) { throw "対象機を指定してください(例: MS-3)。一覧は labpc hosts" }
  $key = $HOSTS.Keys | Where-Object { $_ -ieq $name }
  if (-not $key) { throw "未登録の機: $name。一覧は labpc hosts" }
  $d = $HOSTS[$key].Clone(); $d.Name = $key; return $d
}

function New-LabSession($def) {
  $so = New-PSSessionOption -ProxyAccessType NoProxyServer -OperationTimeout 0 -OpenTimeout 60000
  try {
    $s = New-PSSession -ComputerName $def.Fqdn -Authentication Kerberos -SessionOption $so -ErrorAction Stop
  } catch {
    throw "接続失敗($($def.Name) = $($def.Fqdn)): $($_.Exception.Message)`n" +
          "  ・学内のネットワークにいるか、このPCに研究室のドメインのアカウントでログインしているか(klist)確認`n" +
          "  ・初めてなら、対象機の管理者に遠隔実行の許可(Remote Management Users)を付けてもらう必要がある(labpc-claude-setup の check が打つコマンドを出す)"
  }
  $script:JOBROOT = Invoke-Command -Session $s -ScriptBlock { Join-Path $env:USERPROFILE 'labpc_jobs' }
  return $s
}

function Split-List([string[]]$xs) {
  # labpc.cmd 経由(powershell -File)では -Files a,b が 1 つの文字列 "a,b" で届くので分ける
  @($xs | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
}

function Copy-ToRemote($sess, [string]$local, [string]$remoteDir) {
  $lp = Resolve-Path $local
  if (Test-Path $lp -PathType Container) {
    Get-ChildItem $lp -Recurse -File | ForEach-Object {
      $rel = $_.FullName.Substring($lp.Path.Length).TrimStart('\')
      $dst = Join-Path $remoteDir (Join-Path (Split-Path $lp -Leaf) $rel)
      Invoke-Command -Session $sess -ScriptBlock { param($p) New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null } -ArgumentList $dst
      Copy-Item $_.FullName -Destination $dst -ToSession $sess -Force
      Write-Host "  push $(Split-Path $lp -Leaf)\$rel"
    }
  } else {
    $dst = Join-Path $remoteDir (Split-Path $lp -Leaf)
    Copy-Item $lp -Destination $dst -ToSession $sess -Force
    Write-Host "  push $(Split-Path $lp -Leaf)"
  }
}

# 共有機の決まりは remote\labbudget.ps1(ジョブの中の labenv.budget_now() も同じものを使う)。
function Get-Budget($sess, $def) {
  $js = Invoke-Command -Session $sess -FilePath (Join-Path $Here 'remote\labbudget.ps1') -ArgumentList $def.Margin, $def.HalfCap
  return ($js | ConvertFrom-Json)
}

function Show-Budget($b, $def) {
  "{0}  {1}  cores {2}  busy~{3}(うち自分 {4})  margin {5}  mem 空き {6}/{7} GB(自分 {8} GB)  OpticStudio {9} 本" -f `
    $def.Name, $b.Now, $b.Cores, $b.Busy, $b.Mine, $b.Margin, $b.FreeGB, $b.TotalGB, $b.MineGB, $b.Zemax
  $b.Rows | ForEach-Object { "  $_" }
  $win = if ($b.InWindow) { "制限中(平日 12〜18 時: 自分の合計 $($b.HalfCap) まで)" } else { "制限外(次の制限まで $($b.HoursToWindow) h)" }
  "  → 今 submit で使えるスレッド数: $($b.Allowed)、新しく使ってよいメモリ: $($b.MemAllowedGB) GB  $win"
}

function Push-Lib($sess) {
  $lib = Join-Path $JOBROOT $LIBREL
  Invoke-Command -Session $sess -ArgumentList $lib -ScriptBlock { param($l) New-Item -ItemType Directory -Force $l | Out-Null }
  foreach ($f in 'labenv.py', 'labbudget.ps1', 'labtidy.ps1') {
    Copy-Item (Join-Path $Here "remote\$f") -Destination (Join-Path $lib $f) -ToSession $sess -Force
  }
  return $lib
}

# 対象機の自分の対話セッションの中で短い PowerShell スクリプトを走らせて出力を返す(WMI は WinRM からは読めないため)
function Invoke-InSession($sess, [string]$tag, [string]$psline) {
  $d = Join-Path $JOBROOT ("_" + $tag + "_" + (Get-Date -Format 'HHmmss'))
  $tn = $TASKPFX + (Split-Path $d -Leaf)
  Invoke-Command -Session $sess -ArgumentList $d, $psline, $tn -ScriptBlock {
    param($d, $psline, $tn)
    New-Item -ItemType Directory -Force $d | Out-Null
    $bat = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -Command `"$psline`" > `"$d\out.txt`" 2>&1`r`necho done > `"$d\done.txt`""
    Set-Content -Encoding ascii "$d\run.bat" $bat
    schtasks /create /tn $tn /tr "`"$d\run.bat`"" /sc once /st 23:59 /it /f | Out-Null
    schtasks /run /tn $tn | Out-Null
    for ($i = 0; $i -lt 120 -and -not (Test-Path "$d\done.txt"); $i++) { Start-Sleep 1 }
    Get-Content "$d\out.txt" -ErrorAction SilentlyContinue | ForEach-Object { "$_" }
    schtasks /delete /tn $tn /f 2>&1 | Out-Null
    Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue
  }
}

function Get-JobState($sess, [string]$job) {
  Invoke-Command -Session $sess -ArgumentList (Join-Path $JOBROOT $job) -ScriptBlock {
    param($d)
    if (-not (Test-Path $d)) { return 'missing' }
    $s = Get-Content (Join-Path $d '_status.txt') -ErrorAction SilentlyContinue
    if (-not $s) { 'queued' }
    elseif (($s -join ' ') -match 'exit (-?\d+)') { "done exit=$($matches[1])" }
    else { 'running' }
  }
}

# ログの末尾を読む(対象機で動かす)。書き込み中でも読めるよう共有で開く。Python のログは UTF-8、COMSOL は Shift-JIS で
# 書くので、UTF-8 として読めなければ対象機の既定の文字コードで読む。行はただの文字列にして返す(Get-Content の行は
# 付属の情報ごと送られ、行が多いととても遅い)
$READTAIL = {
  param($p, $t)
  if (-not (Test-Path $p)) { return }
  $fs = [IO.File]::Open($p, 'Open', 'Read', 'ReadWrite')
  try { $ms = New-Object IO.MemoryStream; $fs.CopyTo($ms); $b = $ms.ToArray() } finally { $fs.Close() }
  try { $txt = (New-Object Text.UTF8Encoding($false, $true)).GetString($b) } catch { $txt = [Text.Encoding]::Default.GetString($b) }
  @($txt.TrimStart([char]0xFEFF).TrimEnd() -split "`r?`n") | Select-Object -Last $t | ForEach-Object { "$_" }
}

function Find-MySession {
  # 対象機の `query user` から自分の行を探す(WinRM の中で呼ぶ)
  foreach ($line in (query user 2>&1)) {
    $t = (([string]$line -replace '^\s*>?', '').Trim()) -split '\s+'
    if ($t[0] -ieq $env:USERNAME) { return ([string]$line).Trim() -replace '\s+', ' ' }
  }
}

# ---- 送るファイルの種類ごとの動かし方 ---------------------------------------------
# .py は Python、.mph は COMSOL(comsolbatch)、.ind は RSoft のコマンド版、.bat/.cmd/.ps1 はそのまま。
# COMSOL と RSoft は、使ってよい数の CPU だけに絞って起動する(start /affinity)。RSoft の BeamPROP や DiffractMOD は
# 既定で機の全コアを使い、そのスレッド数の設定は機の全員に効くので変えない。
$RSOFTTOOLS = @{ ST_BEAMPROP = 'bsimw32'; ST_FULLWAVE = 'fullwave'; ST_DIFFRACTMOD = 'dfmod'; ST_FEMSIM = 'femsim'
                 ST_MODEPROP = 'modeprop'; ST_BANDSOLVE = 'bandsolve'; ST_GRATINGMOD = 'grmod' }

function Get-RSoftTool([string]$ind) {
  if ($Tool) { return ($Tool -replace '\.exe$', '') }
  $m = Select-String -Path $ind -Pattern '^\s*sim_tool\s*=\s*(\S+)' | Select-Object -First 1
  if (-not $m) { return 'bsimw32' }                    # sim_tool の無い .ind は BeamPROP(RSoft の既定)
  $k = $m.Matches[0].Groups[1].Value
  if ($RSOFTTOOLS.ContainsKey($k)) { return $RSOFTTOOLS[$k] }
  throw "この .ind の sim_tool($k)に合うソフトが分かりません。-Tool で指定してください(bsimw32 / fullwave / dfmod / femsim / modeprop など)"
}

function Get-AffinityMask([int]$n, [int]$cores) {
  # 番号の大きい方から n 個の論理 CPU(16 進)。64 を超える機と、全部使ってよいときは絞らない
  if ($cores -gt 64 -or $n -ge $cores -or $n -lt 1) { return $null }
  $m = [uint64]0; for ($i = $cores - $n; $i -lt $cores; $i++) { $m = $m -bor ([uint64]1 -shl $i) }
  return ('{0:X}' -f $m)
}

function Get-RunLine($def, [string]$script, [string]$localPath, [int]$n, [string]$aff, [string]$argline) {
  $ext = [IO.Path]::GetExtension($script).ToLower()
  $base = [IO.Path]::GetFileNameWithoutExtension($script)
  $start = if ($aff) { "start `"`" /wait /b /affinity $aff " } else { "start `"`" /wait /b " }
  switch ($ext) {
    '.py' {
      if (-not $def.Python) { throw "$($def.Name) には、ジョブに使える Python がありません(.mph・.ind・.bat・.ps1 なら動かせます)" }
      return "`"$($def.Python)`" -u `"$script`" $argline"
    }
    '.mph' {
      # comsolbatch.exe は本体を起こす役で、start 経由だと本体の終わりを待たずに戻る。直接呼べば待つので start は使わず、コア数は -np で絞る
      if (-not $def.Comsol) { throw "$($def.Name) には COMSOL がありません" }
      return "`"$($def.Comsol)`" -np $n -inputfile `"$script`" -outputfile `"${base}_out.mph`" $argline"
    }
    '.ind' {
      if (-not $def.RSoft) { throw "$($def.Name) には RSoft がありません" }
      # RSoft は引数を自分で読み、引用符も名前の一部にしてしまうので、.ind の名前は囲まない(名前は英数字だけに限ってある)。
      # FullWAVE の並列版(fwmpirun)は別のライセンスが要るので、どこでも動く 1 プロセスの fullwave で動かす
      $t = Get-RSoftTool $localPath
      return "$start`"$($def.RSoft)\$t.exe`" -hide $script prefix=$base wait=0 $argline"
    }
    { $_ -in '.bat', '.cmd' } { return "call `"$script`" $argline" }
    '.ps1' { return "powershell -NoProfile -ExecutionPolicy Bypass -File `"$script`" $argline" }
    default { throw "動かせない種類のファイルです: $script(使えるのは .py・.mph・.ind・.bat・.cmd・.ps1)" }
  }
}

# COMSOL のライセンス: 同時に使える人数(COMSOLUSER)が少なく、画面で開いたままの人がいると誰も動かせない。
# 送る前にライセンスサーバに問い合わせ、他の人が使っていれば止める。バッチ専用の枠(COMSOLBATCH)があれば -usebatchlic で使う
function Get-ComsolLicense($sess, $def) {
  Invoke-Command -Session $sess -ArgumentList $def.Comsol -ScriptBlock {
    param($cb)
    $root = Split-Path (Split-Path (Split-Path $cb))                     # ...\Multiphysics
    $lm = Join-Path $root 'license\win64\lmutil.exe'; $dat = Join-Path $root 'license\license.dat'
    $r = [ordered]@{ ok = $false; batch = 0; users = 0; inuse = 0; holders = @() }
    if (-not (Test-Path $lm) -or -not (Test-Path $dat)) { return [pscustomobject]$r }
    $txt = (& $lm lmstat -c $dat -f COMSOLUSER 2>&1 | ForEach-Object { "$_" }) + (& $lm lmstat -c $dat -f COMSOLBATCH 2>&1 | ForEach-Object { "$_" })
    $cur = ''
    foreach ($line in $txt) {
      if ($line -match '^Users of (\w+):.*Total of (\d+) licenses? issued;\s*Total of (\d+) licenses? in use') {
        $cur = $matches[1]
        if ($cur -eq 'COMSOLUSER') { $r.ok = $true; $r.users = [int]$matches[2]; $r.inuse = [int]$matches[3] }
        if ($cur -eq 'COMSOLBATCH') { $r.batch = [int]$matches[2] }
      } elseif ($cur -eq 'COMSOLUSER' -and $line -match '^\s+(\S+)\s+\S+\s+\S+.*start (.+)$') { $r.holders += "$($matches[1])($($matches[2].Trim()) から)" }
    }
    [pscustomobject]$r
  }
}

# comsolbatch はモデルのエラーで止まっても終了コード 0 を返すので、保存されるはずの <名前>_out.mph が無ければ失敗(3)にする
function Get-PostCheck([string]$script, [string]$argline) {
  if ([IO.Path]::GetExtension($script) -ine '.mph' -or $argline -match '(?i)-nosave|-outputfile') { return @() }
  $out = [IO.Path]::GetFileNameWithoutExtension($script) + '_out.mph'
  return @("if %RC%==0 if not exist `"$out`" set RC=3")
}

$NOSESSION = "{0} に自分の RDP のセッションがありません(対象機の再起動やサインアウトで消えます)。ジョブは自分のセッションの中でしか動きません。" +
             "本人に、{0}({1})へリモート デスクトップでログインし、サインアウトせずに窓の × で閉じてもらってから、やり直してください。"

function Test-MySession($sess) {
  [bool](Invoke-Command -Session $sess -ScriptBlock ([scriptblock]::Create(${function:Find-MySession}.ToString())))
}

# ジョブの終わりを待ち、ログの末尾を出す。始まらない・セッションが消えた、のときは待ち続けずに止まる
function Wait-LabJob($sess, $def, [string]$job) {
  $t0 = Get-Date; $lastCheck = Get-Date
  while ($true) {
    $st = Get-JobState $sess $job
    if ($st -eq 'missing') { throw "ジョブが見つかりません: $job(status $($def.Name) で一覧)" }
    if ($st -like 'done*') {
      "$job : $st"
      Invoke-Command -Session $sess -ArgumentList (Join-Path (Join-Path $JOBROOT $job) '_log.txt'), 25 -ScriptBlock $READTAIL
      return
    }
    if ($st -eq 'queued' -and ((Get-Date) - $t0).TotalMinutes -gt 5) {
      throw "$job が 5 分たっても始まりません。labpc check $($def.Name) で自分のセッションを確かめ、labpc clean $($def.Name) $job -RemoveFiles で消してから投げ直してください。"
    }
    if (((Get-Date) - $lastCheck).TotalSeconds -ge 60) {
      $lastCheck = Get-Date
      if (-not (Test-MySession $sess)) { throw ($NOSESSION -f $def.Name, $def.Fqdn) + "(ジョブ $job は止まっている見込み。入り直したら labpc tidy $($def.Name) で片付ける)" }
    }
    Start-Sleep $Interval
  }
}

# ---- コマンド ------------------------------------------------------------------
# エラーは PowerShell の飾り(At … / + …)を付けず、文だけを出して終了コード 1 で終わる
try {
switch ($Command.ToLower()) {

  'hosts' {
    "{0,-6} {1,-26} {2}" -f 'NAME','FQDN','NOTE'
    foreach ($k in $HOSTS.Keys | Sort-Object) { "{0,-6} {1,-26} {2}" -f $k,$HOSTS[$k].Fqdn,$HOSTS[$k].Note }
  }

  'check' {
    $def = Get-HostDef $Host_; $s = New-LabSession $def
    try {
      Invoke-Command -Session $s -ArgumentList $def.Python,$def.Lumapi,$def.ZemaxRoot,${function:Find-MySession}.ToString() -ScriptBlock {
        param($py,$lum,$zmx,$fms)
        "whoami : $(whoami)  host: $env:COMPUTERNAME  cores: $env:NUMBER_OF_PROCESSORS"
        $sess = & ([scriptblock]::Create($fms))
        if ($sess) { "session: $sess" } else { "session: なし → 対象機に RDP で一度ログインし、サインアウトせず『切断』(窓の×)で抜ける(ジョブの実行に必要)" }
        "python : $py  exists=$(Test-Path $py)"
        if ($lum) { "lumapi : $lum  exists=$(Test-Path (Join-Path $lum 'lumapi.py'))" }
        if ($zmx) { "zemax  : $zmx  exists=$(Test-Path (Join-Path $zmx 'ZOSAPI.dll'))" }
      }
    } finally { Remove-PSSession $s }
  }

  'license' {
    # COMSOL のライセンスを今だれが使っているか(同時に使える人数が少なく、開いたままの人がいると誰も動かせない)
    $def = Get-HostDef $Host_; $s = New-LabSession $def
    try {
      if (-not $def.Comsol) { "$($def.Name) には COMSOL がありません" }
      else {
        $lic = Get-ComsolLicense $s $def
        if (-not $lic.ok) { "COMSOL のライセンスサーバに問い合わせられませんでした" }
        else {
          $who = if ($lic.holders) { "(" + ($lic.holders -join '、') + ")" } else { '' }
          "COMSOL: 同時に使える人数 $($lic.users)、使用中 $($lic.inuse)$who、バッチ専用の枠 $($lic.batch)"
          if ($lic.inuse -ge $lic.users) { "  → 今は空いていません。使っている人が COMSOL を閉じるまで .mph は投げられない(同じ人なら使える)" }
          else { "  → 今は空いています" }
        }
      }
    } finally { Remove-PSSession $s }
  }

  'load' {
    $def = Get-HostDef $Host_; $s = New-LabSession $def
    try { Show-Budget (Get-Budget $s $def) $def } finally { Remove-PSSession $s }
  }

  'exec' {
    $def = Get-HostDef $Host_; $s = New-LabSession $def
    try { Invoke-Command -Session $s -ScriptBlock ([scriptblock]::Create($Path)) }
    finally { Remove-PSSession $s }
  }

  'submit' {
    $def = Get-HostDef $Host_
    if (-not $Path -or -not (Test-Path $Path)) { throw "スクリプトが見つかりません: $Path" }
    [void](Get-RunLine $def (Split-Path $Path -Leaf) $Path 1 $null '')   # その機で動かせる種類かを、つなぐ前に確かめる
    # _run.bat は ASCII で書くので、日本語や空白の入った名前は化けて動かない
    if ((Split-Path $Path -Leaf) -notmatch '^[A-Za-z0-9_.-]+$') { throw "スクリプトの名前は半角の英数字と _ . - だけにしてください(日本語・空白は不可): $(Split-Path $Path -Leaf)" }
    if (-not $Job) { $Job = [IO.Path]::GetFileNameWithoutExtension($Path) + '_' + (Get-Date -Format 'MMdd_HHmmss') }
    if ($Job -notmatch '^[A-Za-z0-9_.-]+$') { throw "ジョブ名は半角の英数字と _ . - だけにしてください: $Job" }
    $s = New-LabSession $def
    $rdir = Join-Path $JOBROOT $Job
    try {
      if (-not (Test-MySession $s)) { throw $NOSESSION -f $def.Name, $def.Fqdn }
      $b = Get-Budget $s $def
      $n = if ($Threads -gt 0) { [math]::Min($Threads, $b.Allowed) } else { $b.Allowed }
      if ($n -lt $MINTHREADS -or $b.MemAllowedGB -lt 2) {
        Show-Budget $b $def
        throw "空きが足りないので投げません(使えるのは $($b.Allowed) スレッド・$($b.MemAllowedGB) GB)。時間をおいて load で確かめてから投げ直してください。"
      }
      Write-Host "threads: $n(使える上限 $($b.Allowed)、busy~$($b.Busy)、自分 $($b.Mine))"
      $script = Split-Path $Path -Leaf
      $argline = ((@($Rest) | Where-Object { $_ }) -join ' ')   # スクリプト名の後ろの引数はそのまま渡す
      if ([IO.Path]::GetExtension($script) -ieq '.mph') {
        $lic = Get-ComsolLicense $s $def
        $others = @($lic.holders | Where-Object { $_ -notmatch "^$([regex]::Escape($env:USERNAME))\(" })
        if ($lic.ok -and $lic.inuse -ge $lic.users -and $others.Count) {
          throw "COMSOL のライセンス(同時に使えるのは $($lic.users) 人)を、今 $($others -join '、') が使っています。その人が COMSOL を閉じるまで動かせません。"
        }
        if ($lic.batch -gt 0 -and $argline -notmatch '(?i)-usebatchlic') { $argline = "-usebatchlic $argline".Trim() }
        Write-Host "COMSOL license: 使用中 $($lic.inuse)/$($lic.users) 人、バッチ専用の枠 $($lic.batch)"
      }
      Invoke-Command -Session $s -ArgumentList $rdir -ScriptBlock { param($r) New-Item -ItemType Directory -Force $r | Out-Null }
      $lib = Push-Lib $s
      Copy-ToRemote $s $Path $rdir
      foreach ($f in (Split-List $Files)) { Copy-ToRemote $s $f $rdir }

      $aff = Get-AffinityMask $n $b.Cores
      $run = Get-RunLine $def $script $Path $n $aff $argline
      $envlines = @("set PYTHONPATH=$lib", "set PYTHONIOENCODING=utf-8", "set LABPC_LUMAPI=$($def.Lumapi)", "set LABPC_THREADS=$n",
                    "set LABPC_LIB=$lib", "set LABPC_MARGIN=$($def.Margin)", "set LABPC_HALFCAP=$($def.HalfCap)")
      if ($def.ZemaxRoot) { $envlines += "set LABPC_ZEMAX_ROOT=$($def.ZemaxRoot)" }
      if ($def.Comsol) { $envlines += "set LABPC_COMSOL=$($def.Comsol)" }
      if ($def.RSoft) { $envlines += "set LABPC_RSOFT=$($def.RSoft)" }
      if ($aff) { $envlines += "set LABPC_AFFINITY=$aff" }
      foreach ($k in $def.Env.Keys) { $envlines += "set $k=$($def.Env[$k])" }
      $bat = @("@echo off","cd /d `"$rdir`"") + $envlines + @(
        "echo started %date% %time% > `"$rdir\_status.txt`"",
        "$run > `"$rdir\_log.txt`" 2>&1",
        "set RC=%errorlevel%") + @(Get-PostCheck $script $argline) + @(
        # 終わったら取り残されたプロセス(Zemax の OpticStudio、例外で閉じ損ねた Lumerical の GUI など)を片付ける
        "powershell -NoProfile -ExecutionPolicy Bypass -File `"$lib\labtidy.ps1`" -JobRoot `"$JOBROOT`" > `"$rdir\_tidy.txt`" 2>&1",
        "echo exit %RC% %date% %time% >> `"$rdir\_status.txt`"")
      $tn = $TASKPFX + $Job
      Invoke-Command -Session $s -ArgumentList ($bat -join "`r`n"),(Join-Path $rdir '_run.bat'),$tn -ScriptBlock {
        param($bat,$batpath,$tn)
        Set-Content -Encoding ascii $batpath $bat
        $o = schtasks /create /tn $tn /tr "`"$batpath`"" /sc once /st 23:59 /it /f 2>&1
        if ($LASTEXITCODE -ne 0) { throw "タスクを登録できませんでした(schtasks /create: $o)" }
        $o = schtasks /run /tn $tn 2>&1
        if ($LASTEXITCODE -ne 0) { throw "タスクを起動できませんでした(schtasks /run: $o)" }
      }
      Write-Host "job: $Job  (host $($def.Name))"
      if ($Wait) { Wait-LabJob $s $def $Job }
    } finally { Remove-PSSession $s }
  }

  'tidy' {
    # 使いっぱなしの片付け: 取り残されたプロセスを止め、死んだジョブに終了の印を付ける(-DryRun で一覧だけ)
    $def = Get-HostDef $Host_; $s = New-LabSession $def
    try {
      $lib = Push-Lib $s
      $dr = if ($DryRun) { ' -DryRun' } else { '' }
      Invoke-InSession $s 'tidy' "& '$lib\labtidy.ps1' -JobRoot '$JOBROOT'$dr"
    } finally { Remove-PSSession $s }
  }

  'wait' {
    # 既存ジョブの終了を待つ(バックグラウンド実行で使う)。終わったらログ末尾を出す
    $def = Get-HostDef $Host_; $s = New-LabSession $def
    try {
      Wait-LabJob $s $def $Path
    } finally { Remove-PSSession $s }
  }

  'status' {
    $def = Get-HostDef $Host_; $s = New-LabSession $def
    try {
      if ($Path) { "$Path : $(Get-JobState $s $Path)" }
      else {
        $names = Invoke-Command -Session $s -ArgumentList $JOBROOT,$LIBREL -ScriptBlock {
          param($r,$l) Get-ChildItem $r -Directory -ErrorAction SilentlyContinue | Where-Object Name -ne $l | Sort-Object LastWriteTime | ForEach-Object Name }
        foreach ($n in $names) { "{0,-40} {1}" -f $n,(Get-JobState $s $n) }
        if (-not $names) { "(ジョブなし)" }
      }
    } finally { Remove-PSSession $s }
  }

  'log' {
    $def = Get-HostDef $Host_; $s = New-LabSession $def
    $tail = 40; if ($Rest -and $Rest[0] -match '^\d+$') { $tail = [int]$Rest[0] }
    try {
      Invoke-Command -Session $s -ArgumentList (Join-Path (Join-Path $JOBROOT $Path) '_log.txt'),$tail -ScriptBlock $READTAIL
    } finally { Remove-PSSession $s }
  }

  'pull' {
    $def = Get-HostDef $Host_; $s = New-LabSession $def
    $rdir = Join-Path $JOBROOT $Path
    $pats = if ($Rest) { $Rest } else { @('*') }
    $out  = if ($Dest) { $Dest } else { Join-Path (Get-Location) (Join-Path 'results' (Join-Path $def.Name $Path)) }
    try {
      $names = Invoke-Command -Session $s -ArgumentList $rdir,$pats -ScriptBlock {
        param($d,$pats)
        $r=@(); foreach ($p in $pats) { Get-ChildItem $d -Recurse -File -Filter $p -ErrorAction SilentlyContinue | ForEach-Object { $r += $_.FullName.Substring($d.Length).TrimStart('\') } }
        $r | Sort-Object -Unique
      }
      foreach ($n in $names) {
        $lp = Join-Path $out $n
        New-Item -ItemType Directory -Force (Split-Path $lp) | Out-Null
        Copy-Item (Join-Path $rdir $n) -Destination $lp -FromSession $s -Force
        Write-Host "  pull $n -> $lp"
      }
      if (-not $names) { Write-Host "  (該当ファイルなし: $($pats -join ', '))" }
    } finally { Remove-PSSession $s }
  }

  'clean' {
    $def = Get-HostDef $Host_; $s = New-LabSession $def
    $tn = $TASKPFX + $Path
    try {
      Invoke-Command -Session $s -ArgumentList $tn -ScriptBlock { param($tn) schtasks /end /tn $tn 2>&1 | Out-Null; schtasks /delete /tn $tn /f 2>&1 | Out-Null }
      if ($RemoveFiles) {
        $msg = Invoke-Command -Session $s -ArgumentList (Join-Path $JOBROOT $Path) -ScriptBlock {
          param($d)
          for ($i=0; $i -lt 3; $i++) {
            Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue
            if (-not (Test-Path $d)) { return "removed $d" }
            Start-Sleep 2
          }
          "残りファイルあり(実行中のプロセスが掴んでいる可能性。tidy を 1 回): $d"
        }
        Write-Host $msg
      } else { Write-Host "task removed: $tn(フォルダも消すなら -RemoveFiles)" }
    } finally { Remove-PSSession $s }
  }

  default { throw "未知のコマンド: $Command。使えるのは hosts / check / load / license / exec / submit / wait / status / log / pull / clean / tidy" }
}
} catch { [Console]::Error.WriteLine("エラー: $($_.Exception.Message)"); exit 1 }
