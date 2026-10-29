<#
  labpc-claude-setup の手順の実体。SETUP.md に従って AI(Claude Code か Codex)が呼ぶ。

  どのサブコマンドも、やったことを書いたあと、最後に 1 行 `RESULT {json}` を出す。
  パスワードは扱わない(このPCのドメインのログインの Kerberos チケットをそのまま使う)。

    powershell -NoProfile -ExecutionPolicy Bypass -File setup/labsetup.ps1 <サブコマンド>

    check [-Agent claude|codex] [-Hosts MS-3,MS-4]   このPCとつなぎ先の機を調べる
    admin [-Rdp]                                    許可の無い機で、管理者が打つコマンドを出す
    grant [-Hosts MS-1,MS-2] [-Member <ドメイン>\<人>]    管理者がこの PC で 1 回入力するだけで、許可の無い機すべてに許可を付ける
                                                    (窓を開き、管理者のアカウントとパスワードを Windows の入力窓で聞く。結果を最大 8 分待つ。
                                                    待ちきれなければ grant -WaitOnly)
    rdp -Machine MS-3                               リモート デスクトップの窓を開く
    prepare                                         つなぎ先の自分の設定(Lumerical の License.ini、ジョブの置き場)
    install [-Allow]                                道具・機の一覧・スキル・PATH(・確認なしの許可)
    smoke -Machine MS-3                             試しのジョブ(Zemax のある機は Zemax も)
    cleanup                                         準備のためだけの物を消す

  開発用(最初の check に付ければ setup/state.json に残る): -InstallDir <dir> -ClaudeDir <dir> -NoPath
#>
param(
  [Parameter(Mandatory, Position = 0)][string]$Command,
  [string]$Agent,
  [string[]]$Hosts,
  [string]$Machine,
  [switch]$Rdp,
  [switch]$Allow,
  [string]$InstallDir,
  [string]$ClaudeDir,
  [switch]$NoPath,
  [string]$State,
  [string]$Member,            # grant: 許可を付ける人(既定はこの PC にログインしている人)
  [switch]$WaitOnly,          # grant: 窓は開かず、結果を待つだけ
  [switch]$UseCurrent         # grant の試験用: 管理者を聞かず、今のアカウントでつなぐ
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$Repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $State) { $State = Join-Path $Repo 'setup\state.json' }
$Defaults = Get-Content (Join-Path $Repo 'setup\hosts.default.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$Marker = '.labpc-claude-setup'                 # 入れた道具のフォルダの目印(このセットアップが作ったと分かるように)
$CheckPrefix = 'setupcheck_'                    # 試しのジョブの名前の頭(cleanup はこれだけを消す)
# 確認なしで動かしてよい labpc のサブコマンド(install -Allow のとき)。exec(任意のコマンド)・clean・tidy(プロセスを止める)は毎回聞く
$AllowedSub = @('hosts', 'check', 'load', 'status', 'log', 'wait', 'pull', 'submit')

# ---- 小さな道具 --------------------------------------------------------------------
function Out-Result([string]$status, [hashtable]$data = @{}) {
  $o = [ordered]@{ status = $status }
  foreach ($k in $data.Keys) { $o[$k] = $data[$k] }
  "RESULT " + ($o | ConvertTo-Json -Compress -Depth 8)
}

function ConvertTo-Hash($o) {
  if ($null -eq $o) { return $null }
  if ($o -is [System.Management.Automation.PSCustomObject]) {
    $h = [ordered]@{}; foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hash $p.Value }; return $h
  }
  if ($o -is [array]) { return ,@($o | ForEach-Object { ConvertTo-Hash $_ }) }
  return $o
}

function Read-State {
  if (Test-Path $State) { return (ConvertTo-Hash (Get-Content $State -Raw -Encoding UTF8 | ConvertFrom-Json)) }
  return [ordered]@{}
}
function Save-State($st) {
  New-Item -ItemType Directory -Force (Split-Path $State) | Out-Null
  [IO.File]::WriteAllText($State, ($st | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding $false))
}

function Get-InstallDir($st) { if ($st.install_dir) { $st.install_dir } else { Join-Path $HOME '.labpc' } }
function Get-ClaudeDir($st)  { if ($st.claude_dir) { $st.claude_dir } else { Join-Path $HOME '.claude' } }
function Get-SkillsRoot($st) {
  if ($st.agent -eq 'codex') { return (Join-Path $HOME '.agents\skills') }
  return (Join-Path (Get-ClaudeDir $st) 'skills')
}
function Get-Me { "$($env:USERDOMAIN)\$($env:USERNAME)" }
function Get-Fqdn([string]$name) { "$($name.ToLower()).$($env:USERDNSDOMAIN.ToLower())" }

function Test-Port([string]$fqdn, [int]$port) {
  $c = New-Object Net.Sockets.TcpClient
  try { return ($c.ConnectAsync($fqdn, $port).Wait(4000) -and $c.Connected) } catch { return $false } finally { $c.Dispose() }
}

function New-Session([string]$fqdn) {
  $so = New-PSSessionOption -ProxyAccessType NoProxyServer -OpenTimeout 30000 -OperationTimeout 0
  New-PSSession -ComputerName $fqdn -Authentication Kerberos -SessionOption $so -ErrorAction Stop
}

# つなぎ先で自分のアカウントとして調べる(WinRM の中。対象機は PowerShell 5.1)
$Probe = {
  $u = $env:USERNAME
  $sess = $null
  foreach ($line in (query user 2>&1)) {
    $t = (([string]$line -replace '^\s*>?', '').Trim()) -split '\s+'
    if ($t[0] -ieq $u) { $sess = ([string]$line).Trim() -replace '\s+', ' ' }
  }
  $rdpRight = [bool]((whoami /groups | Out-String) -match 'S-1-5-32-555|S-1-5-32-544')   # Remote Desktop Users か Administrators
  $lum = Get-ChildItem 'C:\Program Files\Lumerical' -Directory -Filter 'v*' -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName 'api\python\lumapi.py') } |
    Sort-Object { [int]($_.Name -replace '\D', '') } -Descending | Select-Object -First 1
  $zmx = Get-ChildItem 'C:\Program Files' -Directory -Filter '*OpticStudio*' -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName 'ZOSAPI.dll') } | Sort-Object Name -Descending | Select-Object -First 1
  $sys = @(Get-ChildItem 'C:\Program Files' -Directory -Filter 'Python3*' -ErrorAction SilentlyContinue |
    Sort-Object { [int]($_.Name -replace '\D', '') } -Descending | ForEach-Object { Join-Path $_.FullName 'python.exe' } | Where-Object { Test-Path $_ })
  $bund = $null; if ($lum) { $bund = Join-Path $lum.FullName 'python\python.exe'; if (-not (Test-Path $bund)) { $bund = $null } }
  function Test-Import($py, $mods) { & $py -c "import $mods" 2>$null | Out-Null; return ($LASTEXITCODE -eq 0) }
  # Python: Zemax のある機は zospy の入った普通の Python、それ以外は Lumerical に付いている Python を先に選ぶ
  $py = $null
  if ($zmx) { foreach ($c in $sys) { if (Test-Import $c 'numpy, zospy') { $py = $c; break } } }
  if (-not $py -and $bund -and (Test-Import $bund 'numpy')) { $py = $bund }
  if (-not $py) { foreach ($c in $sys) { if (Test-Import $c 'numpy') { $py = $c; break } } }
  $zospy = $false; if ($zmx -and $py) { $zospy = Test-Import $py 'zospy' }
  # COMSOL(いちばん新しい版の comsolbatch)と RSoft(コマンド版のあるフォルダ)
  $com = Get-ChildItem 'C:\Program Files\COMSOL' -Directory -Filter 'COMSOL*' -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName 'Multiphysics\bin\win64\comsolbatch.exe') } |
    Sort-Object { [int]($_.Name -replace '\D', '') } -Descending | Select-Object -First 1
  $rsb = @(@(Get-ChildItem 'C:\Synopsys\PhotonicSolutions' -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending |
    ForEach-Object { Join-Path $_.FullName 'RSoft\bin' }) + @('C:\RSoft\bin') | Where-Object { Test-Path (Join-Path $_ 'bsimw32.exe') }) | Select-Object -First 1
  $li = Join-Path $env:APPDATA 'Lumerical\License.ini'
  $lic = 'missing'; $licServer = $null
  if (Test-Path $li) { if ((Get-Content $li -Raw) -match 'ansysserver\\host=(\S+)') { $lic = 'ok'; $licServer = $matches[1] } else { $lic = 'no_server' } }
  Add-Type -AssemblyName Microsoft.VisualBasic
  $mem = (New-Object Microsoft.VisualBasic.Devices.ComputerInfo).TotalPhysicalMemory / 1GB
  [pscustomobject]@{
    whoami = (whoami); computer = $env:COMPUTERNAME; cores = [int]$env:NUMBER_OF_PROCESSORS; mem_gb = [int][math]::Round($mem)
    session = $sess; rdp_right = $rdpRight; profile = $env:USERPROFILE
    lumerical = $(if ($lum) { $lum.Name } else { $null }); lumapi = $(if ($lum) { Join-Path $lum.FullName 'api\python' } else { $null })
    zemax = $(if ($zmx) { $zmx.FullName } else { $null }); python = $py; zospy = $zospy
    comsol = $(if ($com) { Join-Path $com.FullName 'Multiphysics\bin\win64\comsolbatch.exe' } else { $null }); comsol_ver = $(if ($com) { $com.Name } else { $null })
    rsoft = $(if ($rsb) { [string]$rsb } else { $null }); rsoft_ver =$(if ($rsb -match 'PhotonicSolutions\\([^\\]+)\\') { $matches[1] } elseif ($rsb) { 'C:\RSoft' } else { $null })
    license_ini = $lic; license_server = $licServer
  }
}

# ---- check -------------------------------------------------------------------------
function Invoke-Check($st) {
  if ($Agent) { $st.agent = $Agent.ToLower() } elseif (-not $st.agent) { $st.agent = 'claude' }
  if ($InstallDir) { $st.install_dir = $InstallDir }
  if ($ClaudeDir) { $st.claude_dir = $ClaudeDir }
  if ($NoPath) { $st.no_path = $true }
  $names = if ($Hosts) { @($Hosts | ForEach-Object { $_ -split ',' } | Where-Object { $_ }) } else { @($Defaults.hosts.PSObject.Properties.Name) }

  $cs = Get-CimInstance Win32_ComputerSystem
  $pc = [ordered]@{ computer = $env:COMPUTERNAME; account = (Get-Me); part_of_domain = [bool]$cs.PartOfDomain; domain = $cs.Domain; dns_domain = $env:USERDNSDOMAIN; agent = $st.agent }
  "このPC: $($pc.computer)  アカウント: $($pc.account)  ドメイン: $($pc.domain)(参加: $($pc.part_of_domain))"
  if (-not $cs.PartOfDomain) {
    Save-State $st
    return Out-Result 'not_domain' @{ pc = $pc; hint = 'このPCは研究室のドメインに参加していない。研究室のドメインに参加した Windows の PC で、研究室のアカウントでログインしてやり直す' }
  }
  if (-not $env:USERDNSDOMAIN -or $env:USERDOMAIN -ieq $env:COMPUTERNAME) {
    Save-State $st
    return Out-Result 'not_domain_user' @{ pc = $pc; hint = 'このPCには、ドメインのアカウントではなくこのPCだけのアカウントでログインしている。研究室のアカウントでログインし直してやり直す' }
  }

  $found = [ordered]@{}
  foreach ($n in $names) {
    $fq = Get-Fqdn $n
    $r = [ordered]@{ name = $n; fqdn = $fq }
    try { [void][Net.Dns]::GetHostAddresses($fq) } catch { $r.status = 'unresolved'; $found[$n] = $r; "$n : 名前が引けない($fq)"; continue }
    $r.rdp_port = Test-Port $fq 3389
    if (-not (Test-Port $fq 5985)) { $r.status = 'winrm_closed'; $found[$n] = $r; "$n : 遠隔実行の口(WinRM)が閉じている"; continue }
    try { $s = New-Session $fq } catch {
      $m = $_.Exception.Message
      if ($m -match 'Access is denied|アクセスが拒否') { $r.status = 'denied'; "$n : つながったが、遠隔実行の許可が無い(Remote Management Users に入っていない)" }
      else { $r.status = 'error'; $r.detail = $m; "$n : つながらない: $m" }
      $found[$n] = $r; continue
    }
    try { $p = Invoke-Command -Session $s -ScriptBlock $Probe }
    catch { $r.status = 'error'; $r.detail = "$($_.Exception.Message)"; $found[$n] = $r; "$n : 調べている途中で失敗: $($r.detail)"; continue }
    finally { Remove-PSSession $s }
    foreach ($k in 'whoami','computer','cores','mem_gb','session','rdp_right','profile','lumerical','lumapi','zemax','python','zospy','license_ini','license_server','comsol','comsol_ver','rsoft','rsoft_ver') { $r[$k] = $p.$k }
    $r.status = 'ok'
    $soft = @(); if ($p.lumerical) { $soft += "Lumerical $($p.lumerical)" }; if ($p.zemax) { $soft += (Split-Path $p.zemax -Leaf) }
    if ($p.comsol) { $soft += $p.comsol_ver }; if ($p.rsoft) { $soft += "RSoft $($p.rsoft_ver)" }
    "$n : ok  $($p.whoami)  $($p.cores) コア・$($p.mem_gb) GB  $($soft -join ' + ')  python=$($p.python)"
    "     RDP のセッション: $(if ($p.session) { $p.session } else { 'なし' })  RDP の権利: $($p.rdp_right)  License.ini: $($p.license_ini)"
    if ($p.zemax -and -not $p.zospy) { "     Zemax はあるが、使える Python に zospy が無い(この機の Zemax はこの道具からは使えない)" }
    $found[$n] = $r
  }
  $st.hosts = $found
  $st.account = Get-Me
  Save-State $st
  $ok = @($found.Values | Where-Object { $_.status -eq 'ok' })
  $need = @($found.Values | Where-Object { $_.status -in 'denied', 'winrm_closed' } | ForEach-Object { $_.name })
  $nosess = @($ok | Where-Object { -not $_.session } | ForEach-Object { $_.name })
  $noright = @($ok | Where-Object { -not $_.session -and -not $_.rdp_right } | ForEach-Object { $_.name })
  $nozospy = @($ok | Where-Object { $_.zemax -and -not $_.zospy } | ForEach-Object { $_.name })
  $unreach = @($found.Values | Where-Object { $_.status -eq 'unresolved' } | ForEach-Object { $_.name })
  Out-Result 'ok' @{ pc = $pc; hosts = $found; ok_hosts = @($ok | ForEach-Object { $_.name }); need_admin = $need; need_rdp = $nosess
                     need_rdp_right = $noright; no_zospy = $nozospy; unresolved = $unreach }
}

# ---- admin -------------------------------------------------------------------------
function Invoke-Admin($st) {
  if (-not $st.hosts) { return Out-Result 'error' @{ reason = 'run `check` first' } }
  $me = Get-Me
  $cmds = [ordered]@{}
  foreach ($h in $st.hosts.Values) {
    $c = @()
    if ($h.status -eq 'winrm_closed') { $c += 'Enable-PSRemoting -Force' }
    if ($h.status -in 'denied', 'winrm_closed') { $c += "Add-LocalGroupMember -Group (Get-LocalGroup -SID S-1-5-32-580) -Member '$me'" }
    # RDP の許可は、つながる前は確かめられないので、遠隔の許可と一緒に頼む(管理者に 2 回頼まずに済むように)
    if ($Rdp -or ($h.status -in @('denied', 'winrm_closed')) -or ($h.status -eq 'ok' -and -not $h.session -and -not $h.rdp_right)) {
      $c += "Add-LocalGroupMember -Group (Get-LocalGroup -SID S-1-5-32-555) -Member '$me'"
    }
    # Windows Server 2016 などは右クリックのメニューにコマンド プロンプトしか出ない。どちらの窓に貼っても動くよう powershell で包む
    if ($c) { $cmds[$h.name] = @($c | ForEach-Object { "powershell -NoProfile -Command `"$_`"" }) }
  }
  if (-not $cmds.Count) { return Out-Result 'nothing' @{ hint = '管理者に頼むことは無い' } }
  "---- 管理者が打つコマンド(機ごと) ----"
  foreach ($n in $cmds.Keys) {
    ""
    "[$n]  $n に管理者のアカウントでログインし、スタートボタンを右クリック →「ターミナル(管理者)」「Windows PowerShell(管理者)」「コマンド プロンプト(管理者)」のどれかを開いて(どれでも同じ行で動く):"
    $cmds[$n] | ForEach-Object { "    $_" }
  }
  ""
  "S-1-5-32-580 は Remote Management Users(遠隔でコマンドを実行してよい人。管理者の権限は付かない)。"
  "S-1-5-32-555 は Remote Desktop Users(リモート デスクトップでログインしてよい人)。"
  "「既にメンバー」と出たら、もう入っているので問題ない。"
  Out-Result 'ok' @{ account = $me; commands = $cmds }
}

# ---- grant -------------------------------------------------------------------------
# 管理者がこの PC で 1 回入力するだけで、許可の無い機すべてに許可を付ける。ドメインの管理者のアカウントが要る
# (その機だけのアカウントでは、遠隔の入り方の制約で使えない)。遠隔実行の口が閉じている機(winrm_closed)は、
# 遠隔からは開けないので admin の行を各機で打ってもらう。
function Invoke-Grant($st) {
  $member = if ($Member) { $Member } else { Get-Me }
  $resultFile = Join-Path $Repo 'setup\grant_result.json'
  $argsFile = Join-Path $Repo 'setup\grant_args.json'
  $closed = @(); if ($st.hosts) { $closed = @($st.hosts.Values | Where-Object { $_.status -eq 'winrm_closed' } | ForEach-Object { $_.name }) }
  if (-not $WaitOnly) {
    if ($Hosts) { $names = @($Hosts | ForEach-Object { $_ -split ',' } | Where-Object { $_ }) }
    elseif ($st.hosts) { $names = @($st.hosts.Values | Where-Object { $_.status -eq 'denied' -or ($_.status -eq 'ok' -and -not $_.session -and -not $_.rdp_right) } | ForEach-Object { $_.name }) }
    else { return Out-Result 'error' @{ reason = 'run `check` first (or give -Hosts)' } }
    if (-not $names) { return Out-Result 'nothing' @{ hint = '遠隔で許可を付けられる機は無い'; winrm_closed = $closed } }
    Remove-Item $resultFile -ErrorAction SilentlyContinue
    $hostsArr = @($names | ForEach-Object { [ordered]@{ name = $_; fqdn = (Get-Fqdn $_) } })
    Write-Utf8 $argsFile (([ordered]@{ member = $member; hosts = $hostsArr; result = $resultFile; use_current = [bool]$UseCurrent } | ConvertTo-Json -Depth 4))
    $win = Join-Path $Repo 'setup\grant-window.ps1'
    Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$win`"", '-ArgsFile', "`"$argsFile`""
    "許可を付ける窓を開いた(対象: $($names -join '、')、付ける人: $member)"
  }
  $t0 = Get-Date
  while (((Get-Date) - $t0).TotalMinutes -lt 8) {
    if (Test-Path $resultFile) {
      Start-Sleep 1
      $r = Get-Content $resultFile -Raw -Encoding UTF8 | ConvertFrom-Json
      Remove-Item $argsFile, $resultFile -ErrorAction SilentlyContinue
      $hs = ConvertTo-Hash $r.hosts
      foreach ($k in @($hs.Keys)) { "$k : $(if ($hs[$k].ok) { 'ok' } else { 'うまくいかなかった' })  $($hs[$k].detail)" }
      return Out-Result $r.status @{ member = $r.member; hosts = $hs; winrm_closed = $closed }
    }
    Start-Sleep 3
  }
  Out-Result 'still_waiting' @{ hint = '窓がまだ開いている。入力が済んだか本人に聞き、grant -WaitOnly でもう一度待つ' }
}

# ---- rdp ---------------------------------------------------------------------------
function Invoke-Rdp($st) {
  if (-not $Machine) { return Out-Result 'error' @{ reason = '-Machine を指定する(例: -Machine MS-3)' } }
  $fq = Get-Fqdn $Machine
  Start-Process mstsc.exe -ArgumentList "/v:$fq"
  "リモート デスクトップを開いた: $fq"
  Out-Result 'window_opened' @{ machine = $Machine; fqdn = $fq; account = (Get-Me) }
}

# ---- prepare -----------------------------------------------------------------------
function Invoke-Prepare($st) {
  if (-not $st.hosts) { return Out-Result 'error' @{ reason = 'run `check` first' } }
  $default = $Defaults.lumerical_license
  $out = [ordered]@{}
  foreach ($h in @($st.hosts.Values | Where-Object { $_.status -eq 'ok' })) {
    $s = New-Session $h.fqdn
    try {
      $r = Invoke-Command -Session $s -ArgumentList ([bool]$h.lumerical), $default -ScriptBlock {
        param($hasLum, $server)
        $res = [ordered]@{}
        $jobs = Join-Path $env:USERPROFILE 'labpc_jobs'
        New-Item -ItemType Directory -Force $jobs | Out-Null
        $res.jobs = $jobs
        if ($hasLum) {
          # lumapi(Lumerical の画面なしの起動)が読む、自分のアカウントのライセンス設定。無いと最初の起動でライセンスの窓を出して止まる
          $dir = Join-Path $env:APPDATA 'Lumerical'; $f = Join-Path $dir 'License.ini'
          $body = "[license]`r`ndomain=1`r`nansysserver\host=$server`r`ndefault=user`r`n"
          if ((Test-Path $f) -and ((Get-Content $f -Raw) -match 'ansysserver\\host=')) { $res.license_ini = 'kept' }
          else {
            New-Item -ItemType Directory -Force $dir | Out-Null
            if (Test-Path $f) { $bak = "$f.bak_$(Get-Date -Format yyyyMMdd)"; Copy-Item $f $bak -Force; $res.license_backup = $bak; $res.license_ini = 'fixed' }
            else { $res.license_ini = 'written' }
            [IO.File]::WriteAllText($f, $body, [Text.Encoding]::ASCII)
          }
        }
        [pscustomobject]$res
      }
    } finally { Remove-PSSession $s }
    "$($h.name) : ジョブの置き場 $($r.jobs)  License.ini $($r.license_ini)$(if ($r.license_backup) { "(元は $($r.license_backup))" })"
    $out[$h.name] = [ordered]@{ jobs = $r.jobs; license_ini = $r.license_ini; license_backup = $r.license_backup }
    if ($r.license_ini -in 'written', 'fixed') { $st.hosts[$h.name].license_ini = 'ok'; $st.hosts[$h.name].license_server = $default }
  }
  Save-State $st
  Out-Result 'ok' @{ hosts = $out }
}

# ---- install -----------------------------------------------------------------------
function Write-Utf8([string]$path, [string]$text, [bool]$bom = $false) {
  [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $bom))
}

# settings.json を型を崩さずに読み書きする(PowerShell 5.1 の ConvertTo-Json は 1 要素の配列などを崩すことがあるため)
Add-Type -AssemblyName System.Web.Extensions
$Js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$Js.MaxJsonLength = 67108864
function Format-Json($o, [string]$ind = '') {
  $n = $ind + '  '
  if ($null -eq $o) { return 'null' }
  if ($o -is [System.Collections.IDictionary]) {
    if ($o.Count -eq 0) { return '{}' }
    $parts = foreach ($k in $o.Keys) { $n + $Js.Serialize([string]$k) + ': ' + (Format-Json $o[$k] $n) }
    return "{`n" + ($parts -join ",`n") + "`n$ind}"
  }
  if ($o -is [System.Collections.IEnumerable] -and $o -isnot [string]) {
    $items = @($o)
    if ($items.Count -eq 0) { return '[]' }
    $parts = foreach ($x in $items) { $n + (Format-Json $x $n) }
    return "[`n" + ($parts -join ",`n") + "`n$ind]"
  }
  return $Js.Serialize($o)
}

function Get-PermissionRules {
  $r = @(); foreach ($t in 'Bash', 'PowerShell') { foreach ($s in $AllowedSub) { $r += "$t(labpc $s *)" } }; return $r
}

function Add-Permissions([string]$settings) {
  $data = $null
  if (Test-Path $settings) {
    try { $data = $Js.DeserializeObject([IO.File]::ReadAllText($settings)) } catch {
      return [ordered]@{ changed = $false; reason = 'settings.json not readable; left untouched'; detail = $_.Exception.Message }
    }
  }
  if ($null -eq $data) { $data = New-Object 'System.Collections.Generic.Dictionary[string,object]' }
  if ($data -isnot [System.Collections.IDictionary]) { return [ordered]@{ changed = $false; reason = 'unexpected shape; left untouched' } }
  if (-not $data.ContainsKey('permissions')) { $data['permissions'] = New-Object 'System.Collections.Generic.Dictionary[string,object]' }
  $perm = $data['permissions']
  if ($perm -isnot [System.Collections.IDictionary]) { return [ordered]@{ changed = $false; reason = 'unexpected shape (permissions); left untouched' } }
  $allow = @(); if ($perm.ContainsKey('allow')) {
    if ($perm['allow'] -isnot [array]) { return [ordered]@{ changed = $false; reason = 'unexpected shape (permissions.allow); left untouched' } }
    $allow = @($perm['allow'])
  }
  $new = @(Get-PermissionRules | Where-Object { $allow -notcontains $_ })
  if (-not $new) { return [ordered]@{ changed = $false; reason = 'already present' } }
  $backup = $null
  if (Test-Path $settings) { $backup = "$settings.bak-$(Get-Date -Format yyyyMMddHHmmss)"; Copy-Item $settings $backup }
  $perm['allow'] = [object[]]($allow + $new)
  New-Item -ItemType Directory -Force (Split-Path $settings) | Out-Null
  Write-Utf8 $settings ((Format-Json $data) + "`n")
  return [ordered]@{ changed = $true; added = $new; backup = $backup }
}

function Get-HostsJson($st) {
  $hosts = [ordered]@{}
  foreach ($h in @($st.hosts.Values | Where-Object { $_.status -eq 'ok' -and ($_.python -or $_.comsol -or $_.rsoft) })) {
    $d = $Defaults.hosts.($h.name)
    $margin = if ($d -and $d.margin) { [int]$d.margin } else { [math]::Max(2, [int][math]::Round($h.cores / 20)) }
    $env_ = [ordered]@{}
    # Zemax のある機では、Zemax がその機のライセンスの設定を読むので、Ansys のライセンスの環境変数は足さない
    $zx = $h.zemax -and $h.zospy                  # この道具から使える Zemax(zospy の入った Python がある)
    if ($h.lumerical -and -not $zx) {
      $srv = if ($h.license_server) { $h.license_server } else { $Defaults.lumerical_license }
      $env_['ANSYSLMD_LICENSE_FILE'] = $srv
    }
    $soft = @(); if ($h.lumerical) { $soft += "Lumerical $($h.lumerical)" }; if ($zx) { $soft += (Split-Path $h.zemax -Leaf) }
    if ($h.comsol) { $soft += $h.comsol_ver }; if ($h.rsoft) { $soft += "RSoft $($h.rsoft_ver)" }
    $hosts[$h.name] = [ordered]@{
      Fqdn = $h.fqdn; Python = $(if ($h.python) { $h.python } else { '' }); Lumapi = $(if ($h.lumapi) { $h.lumapi } else { '' }); ZemaxRoot = $(if ($zx) { $h.zemax } else { '' })
      Comsol = $(if ($h.comsol) { $h.comsol } else { '' }); RSoft = $(if ($h.rsoft) { $h.rsoft } else { '' })
      Env = $env_; Margin = $margin; HalfCap = [int][math]::Floor($h.cores / 2)
      Note = "$($soft -join ' + ')($($h.cores) コア、$($h.mem_gb) GB)"
    }
  }
  return [ordered]@{ written = (Get-Date -Format 'yyyy-MM-dd HH:mm'); account = $st.account; hosts = $hosts }
}

# ユーザーの PATH の末尾に足す。レジストリの値をそのまま読み書きし、%USERPROFILE% などの変数を展開して
# 書き戻さないようにする([Environment]::SetEnvironmentVariable は展開した文字列で上書きしてしまう)
function Add-UserPath([string]$dir, [string]$name = 'Path') {
  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
  try {
    $has = $key.GetValueNames() -contains $name
    $raw = if ($has) { [string]$key.GetValue($name, '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } else { '' }
    $kind = if ($has) { $key.GetValueKind($name) } else { [Microsoft.Win32.RegistryValueKind]::ExpandString }
    $parts = @($raw -split ';' | Where-Object { $_ })
    if (@($parts | Where-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') -ieq $dir.TrimEnd('\') }).Count) { return 'already' }
    $key.SetValue($name, (($parts + $dir) -join ';'), $kind)
  } finally { $key.Close() }
  # 開いているアプリ(エクスプローラーなど)に環境変数が変わったことを知らせる。ダミーの値を書いて消すと .NET が通知を出す
  [Environment]::SetEnvironmentVariable('LABPC_SETUP_NOTIFY', '1', 'User')
  [Environment]::SetEnvironmentVariable('LABPC_SETUP_NOTIFY', $null, 'User')
  return 'added'
}

function Invoke-Install($st) {
  if (-not $st.hosts) { return Out-Result 'error' @{ reason = 'run `check` first' } }
  $hj = Get-HostsJson $st
  if (-not $hj.hosts.Count) { return Out-Result 'error' @{ reason = 'no_usable_host'; hint = 'つながって、Python・COMSOL・RSoft のどれかが見つかった機が 1 つも無い(check の結果を見る)' } }
  $dir = Get-InstallDir $st
  if ((Test-Path $dir) -and -not (Test-Path (Join-Path $dir $Marker))) {
    if (@(Get-ChildItem $dir -Force).Count) { return Out-Result 'error' @{ reason = 'install_dir_in_use'; dir = $dir; hint = 'このセットアップが作っていない同じ名前のフォルダがある。中身を本人に確かめる' } }
  }
  New-Item -ItemType Directory -Force $dir | Out-Null
  foreach ($sub in 'bin', 'remote', 'examples') {
    New-Item -ItemType Directory -Force (Join-Path $dir $sub) | Out-Null
    Copy-Item (Join-Path $Repo "tool\$sub\*") (Join-Path $dir $sub) -Recurse -Force
  }
  Copy-Item (Join-Path $Repo 'tool\labpc.ps1') $dir -Force
  Write-Utf8 (Join-Path $dir 'hosts.json') (($hj | ConvertTo-Json -Depth 6) + "`n")
  Write-Utf8 (Join-Path $dir $Marker) "labpc-claude-setup $(Get-Date -Format 'yyyy-MM-dd')`n"
  "道具を入れた: $dir(機: $($hj.hosts.Keys -join ', '))"

  $bin = Join-Path $dir 'bin'
  $path = 'skipped (-NoPath)'
  if (-not $st.no_path) {
    $path = Add-UserPath $bin
    "PATH: $bin($path。次に開くターミナルと Claude Code から labpc で呼べる)"
  }

  $root = Get-SkillsRoot $st
  $dest = Join-Path $root 'labpc'
  if (Test-Path $dest) {
    $sk = Join-Path $dest 'SKILL.md'
    if ((Test-Path $sk) -and ((Get-Content $sk -Raw -Encoding UTF8) -match 'labpc-claude-setup')) { Remove-Item -Recurse -Force $dest }
    else {
      $bak = Join-Path (Split-Path $root) "labpc-skill-backup-$(Get-Date -Format yyyyMMddHHmmss)"
      Move-Item $dest $bak; "同じ名前のスキル labpc があったので $bak に移した"
    }
  }
  New-Item -ItemType Directory -Force $dest | Out-Null
  $rows = foreach ($n in $hj.hosts.Keys) {
    $h = $hj.hosts[$n]; $s = $st.hosts[$n]
    $soft = @(); if ($s.lumerical) { $soft += "Lumerical $($s.lumerical)" }; if ($s.zemax -and $s.zospy) { $soft += "Zemax $((Split-Path $s.zemax -Leaf) -replace '^.*OpticStudio\s*', '')" }
    if ($s.comsol) { $soft += "COMSOL $($s.comsol_ver -replace '^COMSOL', '')" }; if ($s.rsoft) { $soft += "RSoft $($s.rsoft_ver)" }
    $pycell = if ($h.Python) { "``$($h.Python)``" } else { '(なし)' }
    "| $n | $($soft -join '、') | $($s.cores) コア・$($s.mem_gb) GB | $($h.HalfCap) | $($h.Margin) | $pycell |"
  }
  $agentName = if ($st.agent -eq 'codex') { 'Codex' } else { 'Claude Code' }
  $values = @{
    DATE = (Get-Date -Format 'yyyy-MM-dd'); ACCOUNT = $st.account; AGENT = $agentName
    INSTALL_DIR = $dir; LABPC_CMD = (Join-Path $bin 'labpc.cmd'); LABPC_SH = ((Join-Path $bin 'labpc') -replace '\\', '/')
    HOSTS_TABLE = ($rows -join "`n")
    HOST_LIST = ((@($hj.hosts.Keys) | ForEach-Object {
      $s = $st.hosts[$_]; $sw = @(); if ($s.lumerical) { $sw += 'Lumerical' }; if ($s.zemax -and $s.zospy) { $sw += 'Zemax' }
      if ($s.comsol) { $sw += 'COMSOL' }; if ($s.rsoft) { $sw += 'RSoft' }
      "$_ は $($sw -join ' + ')" }) -join '、')
  }
  foreach ($name in 'SKILL.md', 'reference.md') {
    $t = Get-Content (Join-Path $Repo "skill\$name") -Raw -Encoding UTF8
    foreach ($k in $values.Keys) { $t = $t.Replace("{{$k}}", [string]$values[$k]) }
    $left = [regex]::Matches($t, '\{\{[A-Z_]+\}\}') | ForEach-Object Value | Sort-Object -Unique
    if ($left) { return Out-Result 'error' @{ reason = 'template_unfilled'; left = @($left) } }
    Write-Utf8 (Join-Path $dest $name) $t
  }
  "スキルを書いた: $dest"

  if ($st.agent -eq 'codex') { $perms = [ordered]@{ changed = $false; reason = 'codex: approvals follow the Codex approval mode' } }
  elseif ($Allow) { $perms = Add-Permissions (Join-Path (Get-ClaudeDir $st) 'settings.json') }
  else { $perms = [ordered]@{ changed = $false; reason = 'not requested' } }
  "許可: $(($perms | ConvertTo-Json -Compress))"
  if ($perms.backup) { $st.settings_backup = $perms.backup }   # 2 回目の install で 1 回目の控えを忘れないように
  $st.installed_hosts = @($hj.hosts.Keys)
  Save-State $st
  Out-Result 'ok' @{ install_dir = $dir; hosts = @($hj.hosts.Keys); skill = $dest; path = $path; permissions = $perms }
}

# ---- smoke -------------------------------------------------------------------------
function Invoke-Labpc($st, [string[]]$argv) {
  $cmd = Join-Path (Get-InstallDir $st) 'bin\labpc.cmd'
  $ErrorActionPreference = 'Continue'      # PowerShell 5.1 は子のエラー出力を例外にするので、この関数の中だけ止めない
  $out = & $cmd @argv 2>&1 | ForEach-Object { "$_" }
  $code = $LASTEXITCODE
  # 例外の飾りの行(At … / + … / 発生場所 …)を落とし、伝える文だけ残す
  $lines = @(($out -join "`n") -split "`n" | Where-Object { $_ -notmatch '^\s*(At |\+|発生場所|位置 )|(char|文字):\d+\s*$' -and $_.Trim() })
  return [pscustomobject]@{ code = $code; text = ($lines -join "`n") }
}

function Invoke-Smoke($st) {
  if (-not $Machine) { return Out-Result 'error' @{ reason = '-Machine を指定する(例: -Machine MS-3)' } }
  if (-not $st.installed_hosts -or $st.installed_hosts -notcontains $Machine) { return Out-Result 'error' @{ reason = 'run `install` first (or the machine is not installed)'; installed = $st.installed_hosts } }
  $h = $st.hosts[$Machine]
  if (-not $h.session) {
    # check の後に RDP したかもしれないので、もう一度だけ確かめる
    $r = Invoke-Labpc $st @('check', $Machine)
    if ($r.text -notmatch 'session: (?!なし)') { return Out-Result 'no_session' @{ machine = $Machine; hint = "$Machine に RDP でログインし、切断で抜けてから、もう一度 smoke"; detail = $r.text } }
  }
  $tests = @()
  if ($h.lumerical -and $h.python) { $tests += [pscustomobject]@{ kind = 'lumerical'; script = 'smoke_lumerical.py'; ok = 'lumerical OK'; file = 'smoke_lumerical.npz' } }
  if ($h.zemax -and $h.zospy) { $tests += [pscustomobject]@{ kind = 'zemax'; script = 'smoke_zemax.py'; ok = 'zemax OK'; file = $null } }
  if ($h.rsoft) { $tests += [pscustomobject]@{ kind = 'rsoft'; script = 'smoke_rsoft.bat'; ok = 'rsoft OK'; file = 'gauss.dataindex' } }
  # COMSOL は同時に使える人数が少なく、試しで解くと他の人の邪魔になりうるので、ライセンスの空きを見るだけにする
  $comsol = $null
  if ($h.comsol) { $comsol = ((Invoke-Labpc $st @('license', $Machine)).text -split "`n" | Where-Object { $_ -match 'COMSOL|→' }) -join "`n"; "---- $Machine の COMSOL のライセンス"; $comsol }
  if (-not $tests) {
    if ($comsol) { return Out-Result 'ok' @{ machine = $Machine; tests = @{}; comsol_license = $comsol } }
    return Out-Result 'error' @{ reason = 'nothing_to_test'; hint = 'この機に Lumerical・Zemax(zospy)・RSoft・COMSOL のどれも見つからない' }
  }
  $examples = Join-Path (Get-InstallDir $st) 'examples'
  $res = [ordered]@{}
  $overall = 'ok'
  foreach ($t in $tests) {
    $job = "$CheckPrefix$($t.kind)_$(Get-Date -Format 'MMdd_HHmmss')"
    "---- $Machine で $($t.kind) を試す(ジョブ $job)"
    $r = Invoke-Labpc $st @('submit', $Machine, (Join-Path $examples $t.script), '-Job', $job)
    $r.text
    if ($r.code -ne 0) {
      $reason = if ($r.text -match '空きが足りない') { 'busy' } else { 'submit_failed' }
      $res[$t.kind] = [ordered]@{ status = $reason; job = $job; detail = ($r.text -split "`n" | Select-Object -Last 6) -join "`n" }
      $overall = $reason
      if ($reason -eq 'busy') { break }          # 同じ機の空きなので、続きの試しも投げられない
      continue
    }
    $state = ''; $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt 210) {
      Start-Sleep 10
      $q = Invoke-Labpc $st @('status', $Machine, $job)
      if ($q.text -match ': (done exit=-?\d+|queued|running|missing)') { $state = $matches[1] }
      if ($state -like 'done*') { break }
    }
    $log = (Invoke-Labpc $st @('log', $Machine, $job, '30')).text
    if ($state -eq 'done exit=0' -and $log -match [regex]::Escape($t.ok)) {
      $pulled = $null
      if ($t.file) {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) "labpc_setupcheck_$(Get-Random)"
        $p = Invoke-Labpc $st @('pull', $Machine, $job, $t.file, '-Dest', $tmp)
        $pulled = Test-Path (Join-Path $tmp $t.file)
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
      }
      $line = ($log -split "`n" | Where-Object { $_ -match [regex]::Escape($t.ok) } | Select-Object -Last 1)
      "  → 成功: $line$(if ($null -ne $pulled) { "  回収: $pulled" })"
      $res[$t.kind] = [ordered]@{ status = 'ok'; job = $job; line = $line; pulled = $pulled }
      if ($t.file -and -not $pulled) { $res[$t.kind].status = 'pull_failed'; $overall = 'pull_failed' }
    } else {
      # ライセンスの失敗だけを license とする(smoke_zemax.py は成功しても最初に「zemax license: …」を出すので、その行は見ない)
      $lic = ($log -split "`n" | Where-Object { $_ -notmatch '^zemax license:' }) -join "`n"
      $kind = if (-not ($state -like 'done*')) { 'stuck' }
              elseif ($lic -match 'check licenses|licen[sc]e\S*\s+(server|checkout|denied|unavailable|not available|failed|error)|no license|FlexNet|ライセンス') { 'license' }
              else { 'job_failed' }
      "  → うまくいかなかった($kind、状態 $state)"
      $log
      $res[$t.kind] = [ordered]@{ status = $kind; job = $job; state = $state; log = (($log -split "`n") | Select-Object -Last 15) -join "`n" }
      if ($overall -eq 'ok') { $overall = $kind }
      if ($kind -eq 'stuck') {
        # 止まったままのジョブ: タスクを止めてから(親の cmd が消えて取り残しになる)、残ったプロセスを片付ける
        Invoke-Labpc $st @('clean', $Machine, $job) | Out-Null
        Invoke-Labpc $st @('tidy', $Machine) | Out-Null
      }
    }
    $c = Invoke-Labpc $st @('clean', $Machine, $job, '-RemoveFiles')
    "  片付け: $(($c.text -split "`n" | Select-Object -Last 1))"
    if ($res[$t.kind].status -eq 'stuck') { break }   # 初めての起動の窓で止まっているなら、続きの試しも同じ所で止まる。先に本人に開いてもらう
  }
  Out-Result $overall @{ machine = $Machine; tests = $res; comsol_license = $comsol }
}

# ---- cleanup -----------------------------------------------------------------------
function Invoke-Cleanup($st) {
  $removed = @(); $kept = @()
  foreach ($m in @($st.installed_hosts)) {
    if (-not $m) { continue }
    $q = Invoke-Labpc $st @('status', $m)
    foreach ($line in ($q.text -split "`n")) {
      if ($line -match "^($CheckPrefix\S+)\s+(.*)$") {
        $j = $matches[1]
        if ($matches[2] -notlike 'done*') {          # 終わっていない試し: タスクを止めてから、取り残されたプロセスを片付ける
          Invoke-Labpc $st @('clean', $m, $j) | Out-Null
          Invoke-Labpc $st @('tidy', $m) | Out-Null
        }
        $c = Invoke-Labpc $st @('clean', $m, $j, '-RemoveFiles')
        if ($c.text -match 'removed') { $removed += "${m}:$j" } else { $kept += "${m}:$j ($($c.text.Trim()))" }
      }
    }
  }
  $b = $st.settings_backup
  if ($b -and (Test-Path $b)) {
    $good = $false
    try {
      $d = $Js.DeserializeObject([IO.File]::ReadAllText((Join-Path (Get-ClaudeDir $st) 'settings.json')))
      $allow = @($d['permissions']['allow'])
      $good = -not @(Get-PermissionRules | Where-Object { $allow -notcontains $_ })
    } catch { $good = $false }
    if ($good) { Remove-Item $b; $removed += $b } else { $kept += "$b (settings.json did not read back as expected)" }
  }
  $removed | ForEach-Object { "removed: $_" }
  $kept | ForEach-Object { "kept: $_" }
  Out-Result 'ok' @{ removed = $removed; kept = $kept; setup_folder = $Repo }
}

# ---- main --------------------------------------------------------------------------
$st = Read-State
try {
  switch ($Command.ToLower()) {
    'check'   { Invoke-Check $st }
    'admin'   { Invoke-Admin $st }
    'grant'   { Invoke-Grant $st }
    'rdp'     { Invoke-Rdp $st }
    'prepare' { Invoke-Prepare $st }
    'install' { Invoke-Install $st }
    'smoke'   { Invoke-Smoke $st }
    'cleanup' { Invoke-Cleanup $st }
    default   { Out-Result 'error' @{ reason = "unknown command: $Command"; known = @('check', 'admin', 'grant', 'rdp', 'prepare', 'install', 'smoke', 'cleanup') } }
  }
} catch {
  Out-Result 'error' @{ reason = 'exception'; detail = "$($_.Exception.Message)"; at = "$($_.InvocationInfo.PositionMessage)" }
  exit 1
}
