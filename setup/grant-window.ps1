<#
  labsetup.ps1 grant が開く窓。管理者のアカウントとパスワードを Windows の入力窓で聞き、研究室の機それぞれに
  遠隔でつないで、利用者を Remote Management Users(遠隔でコマンドを動かしてよい)と Remote Desktop Users
  (リモート デスクトップで入ってよい)に足す。パスワードはこの窓のプロセスの中だけで使い、どこにも書かない。
  結果は引数のファイルに書いた場所(result)に JSON で残す。
#>
param([string]$ArgsFile)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$a = Get-Content $ArgsFile -Raw -Encoding UTF8 | ConvertFrom-Json
try { $Host.UI.RawUI.WindowTitle = '研究室の機の許可' } catch {}
$res = [ordered]@{ status = 'ok'; member = $a.member; hosts = [ordered]@{} }

Write-Host ""
Write-Host "研究室の Windows 機に、$($a.member) の許可を付けます。"
Write-Host "対象: $(@($a.hosts | ForEach-Object { $_.name }) -join '、')"
Write-Host ""
Write-Host "これから開く窓に、機の管理者のアカウント(ドメインの管理者。例: $($env:USERDOMAIN)\Administrator)とパスワードを入れてください。"
Write-Host "パスワードはこの窓の中だけで使い、どこにも保存しません。"
Write-Host ""

$cred = $null
if ($a.use_current) { Write-Host "(試験用: 今ログインしているアカウントでつなぐ)" }
else { try { $cred = Get-Credential -Message "研究室の Windows 機の管理者のアカウント(例: $($env:USERDOMAIN)\Administrator)とパスワード" } catch {} }

if (-not $cred -and -not $a.use_current) { $res.status = 'cancelled'; Write-Host "取り消されました。" }
else {
  $so = New-PSSessionOption -ProxyAccessType NoProxyServer -OpenTimeout 30000
  foreach ($h in $a.hosts) {
    $p = @{ ComputerName = $h.fqdn; Authentication = 'Kerberos'; SessionOption = $so; ErrorAction = 'Stop'; ArgumentList = $a.member }
    if ($cred) { $p.Credential = $cred }
    try {
      $out = Invoke-Command @p -ScriptBlock {
        param($m)
        foreach ($sid in 'S-1-5-32-580', 'S-1-5-32-555') {
          $g = Get-LocalGroup -SID $sid
          try { Add-LocalGroupMember -Group $g -Member $m -ErrorAction Stop; "$($g.Name): 追加した" }
          catch { if ("$($_.FullyQualifiedErrorId)" -match 'MemberExists') { "$($g.Name): もう入っていた" } else { throw } }
        }
      }
      $res.hosts[$h.name] = [ordered]@{ ok = $true; detail = (@($out) -join '、') }
      Write-Host "  $($h.name): $(@($out) -join '、')"
    } catch {
      $res.hosts[$h.name] = [ordered]@{ ok = $false; detail = "$($_.Exception.Message)".Trim() }
      Write-Host "  $($h.name): うまくいかなかった — $("$($_.Exception.Message)".Trim())"
    }
  }
  if (@($res.hosts.Values | Where-Object { -not $_.ok }).Count) { $res.status = 'partial' }
}
$cred = $null
[IO.File]::WriteAllText($a.result, ($res | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
Write-Host ""
Write-Host "終わりました。この窓は閉じてかまいません。"
