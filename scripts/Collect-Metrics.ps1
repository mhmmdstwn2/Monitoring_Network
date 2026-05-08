# =============================================================
# Collect-Metrics.ps1
# Polling CPU, Memory, Temperature via SSH ke semua device
# Output: data/metrics.json (dibaca oleh dashboard web)
# Auto-Push ke GitHub untuk Vercel Deployment
# =============================================================

param(
    [string]$ConfigPath = "$PSScriptRoot\..\config\devices.csv",
    [string]$DataPath   = "$PSScriptRoot\..\data" # Disesuaikan ke folder data/ di root repo
)

# Install Posh-SSH jika belum ada
if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
    Write-Host "Installing Posh-SSH..." -ForegroundColor Yellow
    Install-Module -Name Posh-SSH -Force -Scope CurrentUser
}
Import-Module Posh-SSH

if (-not (Test-Path $DataPath)) { New-Item -ItemType Directory -Path $DataPath | Out-Null }

# ── Parsing output Huawei CPU ─────────────────────────────
function Parse-HuaweiCPU {
    param($output)
    if ($output -match "System CPU Using Percentage\s*:\s*(\d+)") { return [int]$Matches[1] }
    if ($output -match "(?<!Max\s)CPU Usage\s*:\s*(\d+)") { return [int]$Matches[1] }
    if ($output -match "(\d+)%") { return [int]$Matches[1] }
    return $null
}

# ── Parsing output Huawei Memory ─────────────────────────
function Parse-HuaweiMemory {
    param($output)
    if ($output -match "Physical Memory Using Percentage\s*:\s*(\d+)") { return [int]$Matches[1] }
    if ($output -match "Memory Using Ratio\s*:\s*(\d+)") { return [int]$Matches[1] }
    if ($output -match "(\d+)%") { return [int]$Matches[1] }
    return $null
}

# ── Parsing output Huawei Temperature ────────────────────
function Parse-HuaweiTemp {
    param($output)
    if ($output -match "Temperature.*?:\s*(\d{2,3})") { return [int]$Matches[1] }
    if ($output -match "LSW_TEMP\s+Normal\s+(?:\d+\s+){5}(\d+)") { return [int]$Matches[1] }
    if ($output -match "Normal\s+(?:\d+\s+){5}(\d+)") { return [int]$Matches[1] }
    if ($output -match "(\d{2,3})\s*[Cc]") { return [int]$Matches[1] }
    return $null
}

# ── Polling satu device via SSH ───────────────────────────
function Poll-Device {
    param($device)

    $result = [ordered]@{
        hostname    = $device.hostname
        ip          = $device.ip
        protocol    = $device.protocol
        type        = $device.type
        status      = "offline"
        cpu         = $null
        memory      = $null
        temperature = $null
        uptime      = $null
        interfaces  = @()
        last_update = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        error       = $null
    }

    $reachable = Test-Connection -ComputerName $device.ip -Count 1 -Quiet -TimeoutSeconds 3
    if (-not $reachable) {
        $result.status = "offline"
        $result.error  = "Ping gagal"
        return $result
    }

    $sid = $null

    try {
        $pass    = ConvertTo-SecureString $device.password -AsPlainText -Force
        $cred    = New-Object System.Management.Automation.PSCredential($device.username, $pass)
        
        # 1. Buka sesi SSH (Timeout 15s)
        $session = New-SSHSession -ComputerName $device.ip -Port $device.port `
                    -Credential $cred -AcceptKey -ConnectionTimeout 15 -ErrorAction Stop

        Start-Sleep -Milliseconds 500
        $sid = $session.SessionId

        if ($device.type -match "HUAWEI|S310|S5720|S5700") {
            
            $stream = New-SSHShellStream -SessionId $sid -TerminalName "vt100"
            Start-Sleep -Milliseconds 800
            
            $stream.WriteLine("screen-length 0 temporary")
            Start-Sleep -Milliseconds 500
            $null = $stream.Read()

            $stream.WriteLine("display cpu-usage")
            Start-Sleep -Milliseconds 800
            $cpuOut = $stream.Read()

            $stream.WriteLine("display memory-usage")
            Start-Sleep -Milliseconds 500
            $stream.WriteLine("display memory") 
            Start-Sleep -Milliseconds 800
            $memOut = $stream.Read()

            # Temperature (Bombardir 4 variasi command)
            $stream.WriteLine("display temperature")
            Start-Sleep -Milliseconds 300
            $stream.WriteLine("display device temperature") 
            Start-Sleep -Milliseconds 300
            $stream.WriteLine("display temperature all")
            Start-Sleep -Milliseconds 300
            $stream.WriteLine("display device temperature all")
            Start-Sleep -Milliseconds 800
            $tmpOut = $stream.Read()

            $stream.WriteLine("display version")
            Start-Sleep -Milliseconds 800
            $uptOut = $stream.Read()

            $stream.WriteLine("display interface brief")
            Start-Sleep -Milliseconds 1200
            $intOut = $stream.Read()

            $result.cpu         = Parse-HuaweiCPU    $cpuOut
            $result.memory      = Parse-HuaweiMemory $memOut
            $result.temperature = Parse-HuaweiTemp   $tmpOut

            if ($uptOut -match "uptime is (.+)") { $result.uptime = $Matches[1].Trim() }

            $intLines = $intOut -split "\r?\n"
            $up   = @($intLines | Where-Object { $_ -match "\bup\b" }).Count
            $down = @($intLines | Where-Object { $_ -match "\bdown\b" }).Count
            $result.interfaces = @{ up = $up; down = $down }

        } else {
            $cpuOut = (Invoke-SSHCommand -SessionId $sid -Command "show processes cpu" -TimeOut 10).Output -join "`n"
            $memOut = (Invoke-SSHCommand -SessionId $sid -Command "show memory"         -TimeOut 10).Output -join "`n"

            if ($cpuOut -match "(\d+)%") { $result.cpu    = [int]$Matches[1] }
            if ($memOut -match "(\d+)%") { $result.memory = [int]$Matches[1] }
        }

        Remove-SSHSession -SessionId $sid | Out-Null
        $result.status = "online"

    } catch {
        $result.status = "error"
        $result.error  = $_.Exception.Message
        if ($null -ne $sid) { Remove-SSHSession -SessionId $sid -ErrorAction SilentlyContinue | Out-Null }
    }

    return $result
}

# ── Polling Telnet ────────────────────────────────────────
function Poll-Telnet-Device {
    param($device)

    $result = [ordered]@{
        hostname    = $device.hostname
        ip          = $device.ip
        protocol    = "TELNET"
        type        = $device.type
        status      = "offline"
        cpu         = $null
        memory      = $null
        temperature = $null
        uptime      = $null
        interfaces  = @()
        last_update = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        error       = $null
    }

    $reachable = Test-Connection -ComputerName $device.ip -Count 1 -Quiet -TimeoutSeconds 3
    if (-not $reachable) { $result.error = "Ping gagal"; return $result }

    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $conn   = $client.BeginConnect($device.ip, [int]$device.port, $null, $null)
        if (-not $conn.AsyncWaitHandle.WaitOne(5000, $false)) { throw "Timeout" }
        $client.EndConnect($conn)

        $stream = $client.GetStream()
        $writer = New-Object System.IO.StreamWriter($stream); $writer.AutoFlush = $true
        $reader = New-Object System.IO.StreamReader($stream)
        Start-Sleep -Milliseconds 800
        $writer.WriteLine($device.username); Start-Sleep -Milliseconds 400
        $writer.WriteLine($device.password); Start-Sleep -Milliseconds 800
        $writer.WriteLine("display cpu-usage"); Start-Sleep -Milliseconds 1000

        $buf  = New-Object char[] 8192
        $read = $stream.Read($buf, 0, 8192)
        $out  = New-Object string($buf, 0, $read)

        $result.cpu    = Parse-HuaweiCPU $out
        $result.memory = Parse-HuaweiMemory $out

        $writer.WriteLine("quit")
        $client.Close()
        $result.status = "online"

    } catch {
        $result.status = "error"
        $result.error  = $_.Exception.Message
    }

    return $result
}

# ── MAIN ──────────────────────────────────────────────────
Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Mulai polling metrics..." -ForegroundColor Cyan

$csvData = Import-Csv -Path $ConfigPath 
$allData = @()

foreach ($row in $csvData) {
    if ([string]::IsNullOrWhiteSpace($row.IP)) { continue }

    $device = [PSCustomObject]@{
        hostname = $row.Hostname
        ip       = $row.IP
        type     = $row.Type
        username = $row.user       
        password = $row.Password
        protocol = "SSH"           
        port     = 22              
    }

    Write-Host "  -> $($device.hostname) ($($device.ip))..." -NoNewline
    
    if ($device.protocol -eq "TELNET") {
        $data = Poll-Telnet-Device -device $device
    } else {
        $data = Poll-Device -device $device
    }
    
    $allData += $data
    
    Write-Host " $($data.status.ToUpper())" -NoNewline -ForegroundColor $(
        if ($data.status -eq "online") { "Green" }
        elseif ($data.status -eq "offline") { "Yellow" }
        else { "Red" }
    )

    if ($data.status -eq "error") {
        Write-Host " -> Detail: $($data.error)" -ForegroundColor DarkRed
    } else {
        Write-Host "" 
    }
}

$output = @{
    generated_at = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    total        = $allData.Count
    online       = ($allData | Where-Object { $_.status -eq "online" }).Count
    offline      = ($allData | Where-Object { $_.status -ne "online" }).Count
    devices      = $allData
}

$jsonPath = "$DataPath\metrics.json"
$output | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonPath -Encoding UTF8

Write-Host "`n✅ Data tersimpan: $jsonPath" -ForegroundColor Green
Write-Host "   Online: $($output.online) / $($output.total) device`n" -ForegroundColor Cyan

# ── PUSH KE GITHUB (UNTUK VERCEL) ─────────────────────────
Write-Host "--- Mengirim data ke GitHub untuk Auto-Deploy Vercel ---" -ForegroundColor Cyan

try {
    # Pindah ke root folder repository (Satu tingkat di atas folder scripts)
    Set-Location -Path "$PSScriptRoot\.."
    
    # Amankan dengan git pull sebelum push untuk mencegah konflik error
    git pull --rebase origin main
    
    git add data/metrics.json
    git commit -m "Auto-update metrics $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    git push origin main
    
    Write-Host "✅ Data berhasil dikirim ke GitHub! Vercel akan update dalam beberapa detik." -ForegroundColor Green
} catch {
    Write-Host "❌ Gagal mengirim ke GitHub. Pastikan Git sudah ter-install dan terkoneksi." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
}
