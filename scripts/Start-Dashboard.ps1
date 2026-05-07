# =============================================================
# Start-Dashboard.ps1
# Jalankan web server ringan di port 8080
# Tim IT bisa akses via browser: http://[IP-PC-kamu]:8080
# =============================================================

param([int]$Port = 8080)

$dashboardPath = "$PSScriptRoot\..\dashboard"
$url           = "http://+:$Port/"

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($url)

try {
    $listener.Start()
    $localIP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notmatch "Loopback" } | Select-Object -First 1).IPAddress
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  Dashboard aktif!" -ForegroundColor Green
    Write-Host "  Buka di browser:" -ForegroundColor White
    Write-Host "  → http://localhost:$Port" -ForegroundColor Yellow
    Write-Host "  → http://${localIP}:$Port  (dari PC lain)" -ForegroundColor Yellow
    Write-Host "  Tekan Ctrl+C untuk stop" -ForegroundColor Gray
    Write-Host "========================================`n" -ForegroundColor Cyan

    while ($listener.IsListening) {
        $context  = $listener.GetContext()
        $request  = $context.Request
        $response = $context.Response

        $rawPath  = $request.Url.LocalPath.TrimStart('/')
        if ($rawPath -eq "") { $rawPath = "index.html" }

        $filePath = Join-Path $dashboardPath $rawPath

        if (Test-Path $filePath -PathType Leaf) {
            $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
            $response.ContentType = switch ($ext) {
                ".html" { "text/html; charset=utf-8" }
                ".css"  { "text/css" }
                ".js"   { "application/javascript" }
                ".json" { "application/json; charset=utf-8" }
                default { "application/octet-stream" }
            }
            $bytes = [System.IO.File]::ReadAllBytes($filePath)
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
        } else {
            $response.StatusCode = 404
            $msg = [System.Text.Encoding]::UTF8.GetBytes("Not found: $rawPath")
            $response.OutputStream.Write($msg, 0, $msg.Length)
        }

        $response.OutputStream.Close()
    }
} finally {
    $listener.Stop()
}
