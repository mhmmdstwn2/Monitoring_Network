# =============================================================
# Collect-Metrics.ps1
# Polling CPU, Memory, Temperature via SSH ke semua device
# Output: data/metrics.json (dibaca oleh dashboard web)
# =============================================================

param(
    [string]$ConfigPath = "$PSScriptRoot\..\config\devices.csv",
    [string]$DataPath   = "$PSScriptRoot\..\dashboard\data"
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
    # Cek format S310 ("System CPU Using Percentage : 9%")
    if ($output -match "System CPU Using Percentage\s*:\s*(\d+)") { return [int]$Matches[1] }
    # Cek format S5700 ("CPU Usage : 23%"). Abaikan jika ada kata "Max"
    if ($output -match "(?<!Max\s)CPU Usage\s*:\s*(\d+)") { return [int]$Matches[1] }
    if ($output -match "(\d+)%") { return [int]$Matches[1] }
    return $null
}

# ── Parsing output Huawei Memory ─────────────────────────
function Parse-HuaweiMemory {
    param($output)
    # Cek format S310 ("Physical Memory Using Percentage: 55%")
    if ($output -match "Physical Memory Using Percentage\s*:\s*(\d+)") { return [int]$Matches[1] }
    # Cek format S5700 ("Memory Using Ratio  :  45%")
    if ($output -match "Memory Using Ratio\s*:\s*(\d+)") { return [int]$Matches[1] }
    if ($output -match "(\d+)%") { return [int]$Matches[1] }
    return $null
}

# ── Parsing output Huawei Temperature ────────────────────
function Parse-HuaweiTemp {
    param($output)
    # Cek format S5700 ("Current Temperature : 42" atau "Temperature: 42")
    if ($output -match "Temperature.*?:\s*(\d{2,3})") { return [int]$Matches[1] }
    
    # Cek format Tabel S310 (Mencari baris LSW_TEMP secara spesifik, melewati 5 kolom batas suhu)
    if ($output -match "LSW_TEMP\s+Normal\s+(?:\d+\s+){5}(\d+)") { return [int]$Matches[1] }
    # Fallback Tabel (Ambil baris pertama yang berstatus Normal)
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

    # Ping check
    $reachable = Test-Connection -ComputerName $device.ip -Count 1 -Quiet -TimeoutSeconds 3
    if (-not $reachable) {
        $result.status = "offline"
        $result.error  = "Ping gagal"
        return $result
    }

    # DEKLARASI $sid DI SINI AGAR TIDAK ERROR SAAT GAGAL LOGIN
    $sid = $null

    try {
        $pass    = ConvertTo-SecureString $device.password -AsPlainText -Force
        $cred    = New-Object System.Management.Automation.PSCredential($device.username, $pass)
        
        # 1. Buka sesi SSH
        $session = New-SSHSession -ComputerName $device.ip -Port $device.port `
                    -Credential $cred -AcceptKey -ConnectionTimeout 10 -ErrorAction Stop

        $sid = $session.SessionId

        # 2. Tangkap semua keluarga Huawei, termasuk S310 dan S5720
        if ($device.type -match "HUAWEI|S310|S5720|S5700") {
            
            $stream = New-SSHShellStream -SessionId $sid -TerminalName "vt100"
            Start-Sleep -Milliseconds 800
            
            # Matikan pagination
            $stream.WriteLine("screen-length 0 temporary")
            Start-Sleep -Milliseconds 500
            $null = $stream.Read()

            # CPU
            $stream.WriteLine("display cpu-usage")
            Start-Sleep -Milliseconds 800
            $cpuOut = $stream.Read()

            # Memory (Kirim dua perintah sekaligus untuk S310 dan S5700)
            $stream.WriteLine("display memory-usage")
            Start-Sleep -Milliseconds 500
            $stream.WriteLine("display memory") 
            Start-Sleep -Milliseconds 800
            $memOut = $stream.Read()

            # Temperature (Kirim dua perintah agar S310 memunculkan tabelnya)
            $stream.WriteLine("display temperature")
            Start-Sleep -Milliseconds 500
            $stream.WriteLine("display device temperature") 
            Start-Sleep -Milliseconds 800
            $tmpOut = $stream.Read()

            # Uptime
            $stream.WriteLine("display version")
            Start-Sleep -Milliseconds 800
            $uptOut = $stream.Read()

            # Interface
            $stream.WriteLine("display interface brief")
            Start-Sleep -Milliseconds 1200
            $intOut = $stream.Read()

            # Parsing data menggunakan fungsi yang sudah diperbaiki
            $result.cpu         = Parse-HuaweiCPU    $cpuOut
            $result.memory      = Parse-HuaweiMemory $memOut
            $result.temperature = Parse-HuaweiTemp   $tmpOut

            # Uptime
            if ($uptOut -match "uptime is (.+)") { $result.uptime = $Matches[1].Trim() }

            # Interface up/down count (Perbaikan hitungan Array)
            $intLines = $intOut -split "\r?\n"
            $up   = @($intLines | Where-Object { $_ -match "\bup\b" }).Count
            $down = @($intLines | Where-Object { $_ -match "\bdown\b" }).Count
            $result.interfaces = @{ up = $up; down = $down }

        } else {
            # Exec Channel untuk device non-Huawei
            $cpuOut = (Invoke-SSHCommand -SessionId $sid -Command "show processes cpu" -TimeOut 10).Output -join "`n"
            $memOut = (Invoke-SSHCommand -SessionId $sid -Command "show memory"         -TimeOut 10).Output -join "`n"

            if ($cpuOut -match "(\d+)%") { $result.cpu    = [int]$Matches[1] }
            if ($memOut -match "(\d+)%") { $result.memory = [int]$Matches[1] }
        }

        # Tutup sesi
        Remove-SSHSession -SessionId $sid | Out-Null
        $result.status = "online"

    } catch {
        $result.status = "error"
        $result.error  = $_.Exception.Message
        # Karena $sid sudah dideklarasikan di luar try, baris ini aman dieksekusi
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

    # ATURAN TELNET DIMATIKAN SEMENTARA AGAR RBG_AS_TIM_CLAY BISA MASUK VIA SSH
    # if ($device.type -match "AT-x230") {
    #     $device.protocol = "TELNET"
    #     $device.port = 23
    # }

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