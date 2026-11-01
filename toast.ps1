param(
    [Parameter(Mandatory = $true)][string]$TextFile,
    [string]$LogFile = "",
    [string]$AppId = "",
    [string]$SoundFile = ""
)
# toast.ps1 -- zero-dependency Windows toast (PowerShell 5.1 + WinRT).
#
# The message is read from a UTF-8 FILE because PS 5.1 mangles non-ASCII
# *arguments* (files are safe, argv is not).
#   line 1     = title
#   line 2..n  = body
# Exits 0 on success, 1 on failure; appends one line to -LogFile when given.
#
# SENDER SELECTION (2026-11-01): Windows lets a toast call return success while
# showing nothing when the sending AUMID is not allowed to display banners.
# There is no error to catch in that case. Therefore:
#   1) use -AppId when the caller supplied one;
#   2) otherwise prefer AUMIDs whose per-app setting has ShowBanner=1;
#   3) finally try the built-in PowerShell IDs.
# The actual AUMID and its banner permission are written to the log, so "sent"
# and "displayed" remain separate, diagnosable facts. A banner can still be
# suppressed by Focus assist or the global notification switch.
$ErrorActionPreference = 'Stop'
try {
    $lines = @(Get-Content -Path $TextFile -Encoding UTF8)
    if ($lines.Count -ge 1) { $title = [string]$lines[0] } else { $title = 'Cline needs you' }
    if ($lines.Count -ge 2) { $body = ($lines[1..($lines.Count - 1)] -join "`n") } else { $body = '' }
    if ([string]::IsNullOrWhiteSpace($body)) { $body = ' ' }

    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

    $tpl = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
        [Windows.UI.Notifications.ToastTemplateType]::ToastText02)
    $nodes = $tpl.GetElementsByTagName('text')
    $nodes.Item(0).AppendChild($tpl.CreateTextNode($title)) | Out-Null
    $nodes.Item(1).AppendChild($tpl.CreateTextNode($body)) | Out-Null

    # The toast itself is silent; the wav is played below. This avoids a double
    # sound on machines where a borrowed AUMID does play the XML <audio> hint.
    $audio = $tpl.CreateElement('audio')
    $audio.SetAttribute('silent', 'true')
    $audio.SetAttribute('loop', 'false')
    $tpl.DocumentElement.AppendChild($audio) | Out-Null

    $toast = New-Object Windows.UI.Notifications.ToastNotification $tpl

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($AppId)) { $candidates += $AppId.Trim() }
    try {
        $root = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings'
        $allowed = @()
        foreach ($k in @(Get-ChildItem $root -ErrorAction SilentlyContinue)) {
            $name = $k.PSChildName
            if ($name -like '{*') { continue }          # GUID roots are not complete AUMIDs
            $v = Get-ItemProperty -Path $k.PSPath -Name ShowBanner -ErrorAction SilentlyContinue
            if ($v -and $v.ShowBanner -eq 1) { $allowed += $name }
        }
        foreach ($name in ($allowed | Sort-Object -Unique)) {
            if ($candidates -notcontains $name) { $candidates += $name }
        }
    } catch { }
    foreach ($name in @('Microsoft.Windows.PowerShell',
                        '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe')) {
        if ($candidates -notcontains $name) { $candidates += $name }
    }

    $used = $null
    $usedSetting = ''
    foreach ($aumid in $candidates) {
        try {
            $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($aumid)
            $setting = $notifier.Setting.ToString()
            if ($setting -ne 'Enabled') { continue }
            $notifier.Show($toast)
            $used = $aumid
            $usedSetting = $setting
            break
        } catch { }
    }
    if (-not $used) { throw 'no enabled AUMID accepted the toast' }

    $banner = 'unset'
    try {
        $key = Join-Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings' $used
        $v = Get-ItemProperty -Path $key -Name ShowBanner -ErrorAction Stop
        if ($v.ShowBanner -eq 1) { $banner = 'allow' } else { $banner = 'deny' }
    } catch { }

    # ---- audible feedback that does NOT depend on the toast subsystem -------------------------
    # <audio> is ignored for a toast sent under a *borrowed* AUMID from a PowerShell process,
    # so play a wav ourselves; only system volume/mute can stop this. -SoundFile selects a
    # custom wav; a missing/broken custom file falls back to the system wav, then to beep.
    function Play-Wav([string]$Path) {
        try {
            if (-not (Test-Path -LiteralPath $Path)) { return $false }
            $pl = New-Object System.Media.SoundPlayer $Path
            $pl.PlaySync()
            return $true
        } catch { return $false }
    }

    $snd = 'none'
    if (-not [string]::IsNullOrWhiteSpace($SoundFile)) {
        $custom = [Environment]::ExpandEnvironmentVariables($SoundFile)
        if (-not (Test-Path -LiteralPath $custom)) { $snd = 'custom-missing' }
        elseif (Play-Wav $custom) { $snd = 'custom' }
        else { $snd = 'custom-fail' }
    }
    if ($snd -ne 'custom') {
        $defaultWav = Join-Path $env:SystemRoot 'Media\Windows Notify System Generic.wav'
        if (Play-Wav $defaultWav) {
            if ($snd -eq 'none') { $snd = 'wav' } else { $snd = $snd + '+default' }
        } elseif ($snd -eq 'none') { $snd = 'wavfail' }
    }
    if ($snd -notmatch '(custom|wav|default)$') {
        try {
            1..2 | ForEach-Object { [console]::beep(880, 120); Start-Sleep -Milliseconds 80 }
            if ($snd -eq 'none') { $snd = 'beep' } else { $snd = $snd + '+beep' }
        } catch { }
    }

    if ($LogFile) {
        ("OK`t" + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "`taumid=" + $used +
         "`tsetting=" + $usedSetting + "`tbanner=" + $banner + "`tsound=" + $snd + "`t" + $title) |
            Add-Content -Path $LogFile -Encoding UTF8
    }
    exit 0
} catch {
    if ($LogFile) {
        ("FAIL`t" + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "`t" + $_.Exception.Message) |
            Add-Content -Path $LogFile -Encoding UTF8
    }
    exit 1
}
