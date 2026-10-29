# 使いっぱなしの資源を片付ける(対象機の自分の対話セッションの中で動かす。WMI は WinRM からは読めないため)。
#   ・取り残されたプロセス: 自分のセッションの計算系プロセス(下の $TYPES)のうち、親をたどる途中で親が
#     消えている(=起動したジョブの python などが先に終わった)もの → 止める。「生きているジョブの _run.bat の cmd」
#     「explorer(=自分が RDP で手で開いたもの)」「別セッションのサービス」に着くものには触らない。
#   ・死んだジョブ: _status.txt が終わっていないのに、その _run.bat の cmd が生きていないもの → 終了の行を書き足す。
# labpc の各ジョブは、終わるときにこれを自動で呼ぶ。手で呼ぶときは `labpc tidy <機>`。
param([string]$JobRoot = (Join-Path $env:USERPROFILE 'labpc_jobs'), [switch]$DryRun, [string]$Self = '')

$TYPES = '^(python|pythonw|fdtd-solutions|mode-solutions|interconnect|device|launcher|fdtd-engine.*|varfdtd-engine.*|eme-engine.*|fde-engine.*|mpiexec|smpd|OpticStudio|ZOSAPI.*|ansyscl|apip-standalone-service|ANSYSHelpViewer|QtWebEngineProcess|comsol|comsolbatch|comsollauncher|bsimw32|fullwave|fwmpirun|dfmod|dfmodd|femsim|modeprop|modepropd|bandsolve|grmod|winplot|hydra_pmi_proxy|mpiexec\.hydra|pmi_proxy)$'
# comsol〜pmi_proxy は COMSOL(comsolbatch)と RSoft のコマンド版(と RSoft の MPI)
# ansyscl などは Zemax / Lumerical が起動するライセンス補助。ジョブのフォルダを作業場所にしたまま残り、フォルダを消せなくする
$mysid = (Get-Process -Id $PID).SessionId
$all = @{}
Get-CimInstance Win32_Process | ForEach-Object { $all[[int]$_.ProcessId] = $_ }

# 生きているジョブの cmd(_run.bat を実行中)
$livecmd = @{}
foreach ($p in $all.Values) {
  if ($p.Name -eq 'cmd.exe' -and $p.CommandLine -match '([^\\"]+)\\_run\.bat') { $livecmd[[int]$p.ProcessId] = $matches[1] }
}
$livejobs = @($livecmd.Values | Sort-Object -Unique)

function Get-Anchor([int]$id) {
  # 親をたどって、生きているジョブの cmd か explorer に着くか。親が死んでいる(または PID が再利用されている)なら 'orphan'
  $cur = $all[$id]; $seen = 0
  while ($cur -and $seen -lt 50) {
    $seen++
    if ($livecmd.ContainsKey([int]$cur.ProcessId)) { return "job:$($livecmd[[int]$cur.ProcessId])" }
    if ($cur.Name -eq 'explorer.exe') { return 'user' }
    if ($cur.SessionId -ne $mysid) { return 'system' }                  # サービス等から起動された(親が生きている)ものは触らない
    $par = $all[[int]$cur.ParentProcessId]
    if (-not $par) { return 'orphan' }
    if ($par.CreationDate -gt $cur.CreationDate) { return 'orphan' }     # 親の PID が別のプロセスに再利用されている
    $cur = $par
  }
  return 'orphan'
}

$killed = @()
foreach ($p in $all.Values) {
  if ($p.SessionId -ne $mysid) { continue }
  $name = [IO.Path]::GetFileNameWithoutExtension($p.Name)
  if ($name -notmatch $TYPES) { continue }
  if ([int]$p.ProcessId -eq $PID -or ($Self -and $p.CommandLine -match [regex]::Escape($Self))) { continue }
  $a = Get-Anchor ([int]$p.ProcessId)
  if ($a -eq 'orphan') {
    $killed += "$name($($p.ProcessId), start $($p.CreationDate.ToString('MM/dd HH:mm')))"
    if (-not $DryRun) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
  }
}

$dead = @()
foreach ($d in (Get-ChildItem $JobRoot -Directory -ErrorAction SilentlyContinue | Where-Object Name -notlike '_*')) {
  $st = Join-Path $d.FullName '_status.txt'
  $s = Get-Content $st -ErrorAction SilentlyContinue
  # 始まったばかりのジョブ(別の会話が今投げたもの)は、上のプロセスの一覧に間に合っていないことがあるので触らない
  $fresh = (Test-Path $st) -and ((Get-Date) - (Get-Item $st).LastWriteTime).TotalSeconds -lt 120
  if ($s -and -not $fresh -and -not (($s -join ' ') -match 'exit') -and ($livejobs -notcontains $d.Name)) {
    $dead += $d.Name
    if (-not $DryRun) { Add-Content $st "exit -9 (dead: labtidy $(Get-Date -Format 'yyyy/MM/dd HH:mm'))" }
  }
}
"tidy: live jobs [$($livejobs -join ', ')]"
"tidy: orphans $(if ($DryRun) {'(dry run)'} else {'killed'}): $(if ($killed) { $killed -join '; ' } else { 'none' })"
"tidy: dead jobs marked: $(if ($dead) { $dead -join ', ' } else { 'none' })"
