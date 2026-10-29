# 共有機の決まり(唯一の置き場。labpc.ps1 の submit/load と、ジョブ中の labenv.budget_now() の両方がこれを使う)
#
#   ・他の人から奪わない: 使えるのは「全コア − 動いている計算エンジンのコア − Margin」まで。
#     自分の別ジョブ(別の会話のものも)も「動いている」側に数える。
#   ・平日 12〜18 時(WinStart〜WinEnd)は、自分(このアカウント)の合計を HalfCap(機の半分)まで。
#   ・それ以外の時間は空いている分をほぼ全部使ってよい(Margin だけ残す)。
#   ・メモリ: 平日 12〜18 時は自分(自分のセッションのプロセスの合計)を全体の半分まで。いつでも最低 MemMarginGB は空けておく。
#   (「半分」は自分のアカウントの合計。祝日は平日と同じに扱う)
#
# コア数: 他の人の分は、計算エンジンからの推定(MPI 版 *-msmpi 等は 1 プロセス 1 コア、非 MPI 版は スレッド数 − 4)と、
# 機全体の CPU の実測(GetSystemTimes)から自分の分を引いたもの、の大きい方(他の人のプロセスごとの CPU 時間は
# 権限が無く読めないが、機全体の合計は読める)。自分の分は、自分のセッションの全プロセスの CPU 時間を 2 秒あけて
# 測った実測と、エンジンからの推定の大きい方(GUI の中で走る RCWA、Zemax の光線追跡、numpy なども数えるため)。
# 出力: JSON 1 行。
param([int]$Margin = 4, [int]$HalfCap = 0, [int]$WinStart = 12, [int]$WinEnd = 18, [int]$MemMarginGB = 32)

Add-Type -AssemblyName Microsoft.VisualBasic
$mysid = (Get-Process -Id $PID).SessionId
$rdp = $null
foreach ($line in (query user 2>&1)) {                # 自分(このアカウント)の行の最初の数字がセッション ID
  $tok = (([string]$line -replace '^\s*>?', '').Trim()) -split '\s+'
  if ($tok[0] -ieq $env:USERNAME) { $rdp = $tok | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1; break }
}
if ($rdp) { $mysid = [int]$rdp }                      # WinRM から呼ばれたときは RDP のセッションを自分とみなす

$busy = 0; $mine = 0; $rows = @()
$eng = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '-engine' }
foreach ($g in ($eng | Group-Object SessionId, ProcessName)) {
  $n = 0
  foreach ($p in $g.Group) {
    if ($p.ProcessName -match 'msmpi|impi|mpich') { $n += 1 }
    else { $t = 0; try { $t = $p.Threads.Count } catch {}; $n += [math]::Max(1, $t - 4) }
  }
  $busy += $n
  if ($g.Group[0].SessionId -eq $mysid) { $mine += $n }
  $rows += "session $($g.Name): $($g.Count) proc, ~$n cores"
}
# 機全体の CPU は GetSystemTimes で測る(権限が要らず、WinRM の中からも読める)。他の人の Zemax の光線追跡や
# Python など、計算エンジン以外の計算も「動いている」側に数えるため
if (-not ('LabCpu' -as [type])) {
  Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public static class LabCpu { [DllImport("kernel32.dll")] public static extern bool GetSystemTimes(out long idle, out long kernel, out long user); }'
}
[long]$i0 = 0; [long]$k0 = 0; [long]$u0 = 0; [long]$i1 = 0; [long]$k1 = 0; [long]$u1 = 0
$sysok = [LabCpu]::GetSystemTimes([ref]$i0, [ref]$k0, [ref]$u0)
# 自分のセッションの実測の CPU(コア数)。同じ 2 秒で機全体も測る
$t0 = @{}
foreach ($x in (Get-Process -ErrorAction SilentlyContinue | Where-Object SessionId -eq $mysid)) { try { $t0[$x.Id] = $x.TotalProcessorTime.TotalSeconds } catch {} }
$sw = [Diagnostics.Stopwatch]::StartNew(); Start-Sleep -Milliseconds 2000
$cpu = 0.0
foreach ($x in (Get-Process -ErrorAction SilentlyContinue | Where-Object SessionId -eq $mysid)) {
  if ($t0.ContainsKey($x.Id)) { try { $cpu += $x.TotalProcessorTime.TotalSeconds - $t0[$x.Id] } catch {} }
}
$sysok = $sysok -and [LabCpu]::GetSystemTimes([ref]$i1, [ref]$k1, [ref]$u1)
$minecpu = $cpu / $sw.Elapsed.TotalSeconds
if ($minecpu -gt $mine) { $busy += [math]::Ceiling($minecpu) - $mine; $mine = [int][math]::Ceiling($minecpu) }
$rows += "my session: measured CPU ~$([math]::Round($minecpu, 1)) cores"
$cores = [int]$env:NUMBER_OF_PROCESSORS
$tot = ($k1 - $k0) + ($u1 - $u0)                     # kernel は idle を含む
if ($sysok -and $tot -gt 0) {
  $allcpu = (1 - ($i1 - $i0) / $tot) * $cores
  $others = [int][math]::Round([math]::Max(0, $allcpu - $minecpu))
  if ($others -gt $busy - $mine) { $busy = $mine + $others }   # 他の人の分 = エンジンからの推定と、全体の実測 − 自分、の大きい方
  $rows += "machine: measured CPU ~$([math]::Round($allcpu, 1)) cores(自分以外 ~$others)"
}
$d = Get-Date
$wd = ($d.DayOfWeek -ge 1 -and $d.DayOfWeek -le 5)
$inwin = ($wd -and $d.Hour -ge $WinStart -and $d.Hour -lt $WinEnd)
# 次に制限の時間帯が始まるまでの時間(制限中なら 0)
$h2w = 0.0
if (-not $inwin) {
  $t = $d
  for ($i = 0; $i -lt 8; $i++) {
    $cand = $t.Date.AddHours($WinStart)
    $cwd = ($cand.DayOfWeek -ge 1 -and $cand.DayOfWeek -le 5)
    if ($cwd -and $cand -gt $d) { $h2w = ($cand - $d).TotalHours; break }
    $t = $t.Date.AddDays(1)
  }
}
$free = $cores - $busy - $Margin
$ci = New-Object Microsoft.VisualBasic.Devices.ComputerInfo
$totgb = $ci.TotalPhysicalMemory / 1GB
$freegb = $ci.AvailablePhysicalMemory / 1GB
$minegb = ((Get-Process -ErrorAction SilentlyContinue | Where-Object SessionId -eq $mysid | Measure-Object WorkingSet64 -Sum).Sum) / 1GB
$memok = $freegb - $MemMarginGB
if ($inwin) { $memok = [math]::Min($memok, $totgb / 2 - $minegb) }
$cap = if ($inwin -and $HalfCap -gt 0) { $HalfCap - $mine } else { $free }
[pscustomobject]@{
  Cores = $cores; Busy = $busy; Mine = $mine; Margin = $Margin; HalfCap = $HalfCap
  InWindow = $inwin; HoursToWindow = [math]::Round($h2w, 2); Now = $d.ToString('ddd HH:mm')
  Free = [math]::Max(0, $free); Allowed = [math]::Max(0, [math]::Min($free, $cap))
  FreeGB = [math]::Round($freegb); TotalGB = [math]::Round($totgb); MineGB = [math]::Round($minegb, 1)
  MemAllowedGB = [math]::Round([math]::Max(0, $memok), 1)
  Zemax = @(Get-Process OpticStudio -ErrorAction SilentlyContinue).Count; Rows = $rows
} | ConvertTo-Json -Compress
