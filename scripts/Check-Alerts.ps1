# =============================================================
# Check-Alerts.ps1
# Cek log harian, kirim alert jika ada device ERROR
# Bisa diintegrasikan dengan email atau webhook Telegram
# =============================================================

param(
    [string]$LogPath       = "$PSScriptRoot\..\logs",
    [string]$TelegramToken = "",   # isi token bot Telegram kamu
    [string]$TelegramChatId= "",   # isi chat ID Telegram kamu
    [string]$SmtpServer    = "",   # isi SMTP server jika pakai email
    [string]$AlertEmail    = ""    # isi email tujuan alert
)

$today    = Get-Date -Format "yyyyMMdd"
$summary  = "$LogPath\summary_$today.log"
$failures = @()

# ── Scan semua log device hari ini ────────────────────────
Get-ChildItem -Path $LogPath -Recurse -Filter "*$today.log" | ForEach-Object {
    $lines = Get-Content $_.FullName
    foreach ($line in $lines) {
        if ($line -match "\| ERROR \|") {
            $failures += $line
        }
    }
}

if ($failures.Count -eq 0) {
    Write-Host "✅ Semua device OK hari ini." -ForegroundColor Green
    exit 0
}

# ── Ada kegagalan — buat pesan alert ──────────────────────
$msg = "🚨 *Network Alert — $(Get-Date -Format 'dd/MM/yyyy HH:mm')*`n`n"
$msg += "$($failures.Count) device bermasalah:`n`n"
foreach ($f in $failures) {
    $parts = $f -split "\|"
    $msg  += "• $($parts[2].Trim()) — $($parts[3].Trim())`n"
}
$msg += "`nCek log di: $LogPath"

Write-Host $msg -ForegroundColor Yellow

# ── Kirim ke Telegram (jika dikonfigurasi) ─────────────────
if ($TelegramToken -and $TelegramChatId) {
    try {
        $body = @{
            chat_id    = $TelegramChatId
            text       = $msg
            parse_mode = "Markdown"
        } | ConvertTo-Json

        Invoke-RestMethod `
            -Uri "https://api.telegram.org/bot$TelegramToken/sendMessage" `
            -Method POST `
            -Body $body `
            -ContentType "application/json"

        Write-Host "✅ Alert terkirim ke Telegram." -ForegroundColor Green
    } catch {
        Write-Host "❌ Gagal kirim Telegram: $_" -ForegroundColor Red
    }
}

# ── Kirim via Email (jika dikonfigurasi) ───────────────────
if ($SmtpServer -and $AlertEmail) {
    try {
        Send-MailMessage `
            -SmtpServer $SmtpServer `
            -To         $AlertEmail `
            -From       "monitoring@kantor.com" `
            -Subject    "🚨 Network Alert — $($failures.Count) device bermasalah" `
            -Body       ($msg -replace "\*","") `
            -Priority   High

        Write-Host "✅ Alert terkirim via email ke $AlertEmail." -ForegroundColor Green
    } catch {
        Write-Host "❌ Gagal kirim email: $_" -ForegroundColor Red
    }
}
