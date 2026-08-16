<#
.SYNOPSIS
    WinMedia Builder - builds FAT32-ready Windows installation media: splits install.wim,
    rebuilds a bootable ISO, and writes a bootable USB stick.

.DESCRIPTION
    Takes a Windows ISO (or a bare install.wim/.esd), splits the image into <4 GB .swm parts so the
    media can live on a FAT32 USB stick (required for plain UEFI boot), and rebuilds a *new* bootable
    ISO. The source file is opened read-only and is never modified.

    Optionally prepares a USB stick: wipes it via diskpart, creates an active FAT32 boot partition
    (capped at 32 GB, since format.com will not make a larger FAT32 volume) plus an optional NTFS
    partition for the remaining space, and copies the media across.

    Everything runs in a background runspace, so the window stays responsive and streams live output.

.PARAMETER SourcePath
    Optional. Pre-fills the source ISO/WIM/ESD path.

.PARAMETER WorkRoot
    Optional. Scratch folder for the extracted media. Needs ~1.1x the source size.

.PARAMETER OutputRoot
    Optional. Folder the new ISO / .swm set is written to. Never the same as the source folder.

.PARAMETER LogDirectory
    Optional. Folder for the run log.

.PARAMETER SplitSizeMB
    Optional. Max size per .swm part. Default 4000 (safe for FAT32's 4 GiB file limit).

.NOTES
    Requires: Windows PowerShell 5.1 or PowerShell 7+ (Windows), local administrator
             (Mount-DiskImage and diskpart), Windows ADK Deployment Tools (oscdimg.exe)
             for the ISO rebuild.
    Author:  Simon Skotheimsvik
    Version: 3.0
#>

[CmdletBinding()]
param(
    [string]$SourcePath,
    [string]$WorkRoot,
    [string]$OutputRoot,
    [string]$LogDirectory,
    [ValidateRange(100, 32000)]
    [int]$SplitSizeMB = 4000
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

#region ---------------------------------------------------------------- Constants

# AppName is the display name; AppSlug is the space-free form used for every path,
# folder and filename so nothing has to be quoted or escaped downstream.
$script:AppName    = 'WinMedia Builder'
$script:AppSlug    = 'WinMediaBuilder'
$script:AppVersion = '3.0'

# Pinned ADK download links (verified against Microsoft Learn, adk-install).
# ADK 10.1.26100.2454 (December 2024) is the mainline release covering Win11 25H2/24H2 + Server 2025.
$script:AdkFwLink   = 'https://go.microsoft.com/fwlink/?linkid=2289980'
$script:AdkPeFwLink = 'https://go.microsoft.com/fwlink/?linkid=2289981'
$script:AdkDocsUrl  = 'https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install'

$script:SettingsPath = Join-Path $env:APPDATA "$($script:AppSlug)\settings.json"

$script:StepsSplit = @(
    'Validate environment',
    'Extract source media',
    'Locate Windows image',
    'Split image into .swm parts',
    'Rebuild bootable ISO',
    'Verify and clean up'
)

$script:StepsUsb = @(
    'Validate target disk',
    'Partition and format (diskpart)',
    'Copy media to USB',
    'Verify'
)

# diskpart/format.com refuse to create a FAT32 volume larger than 32 GB, so the boot
# partition is capped and the remainder optionally handed to NTFS.
$script:Fat32MaxMB = 32000

#endregion

#region ---------------------------------------------------------------- Engine
# Dot-sourced into this scope AND injected verbatim into the worker runspace, so the
# same code path is used whether it is called from the UI thread or the background thread.

$Engine = {

    # ---- logging / UI messaging -------------------------------------------------
    # $script:WimLogPath and $script:WimQueue are set per-scope by the host.

    function Write-WimLog {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
            [ValidateSet('Info', 'Ok', 'Warn', 'Error', 'Cmd', 'Raw')][string]$Level = 'Info'
        )
        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $line = if ($Level -eq 'Raw') { $Message } else { '{0}  {1,-5}  {2}' -f $stamp, $Level.ToUpper(), $Message }

        if ($script:WimLogPath) {
            # Never let a logging failure abort the run.
            try { Add-Content -LiteralPath $script:WimLogPath -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
        }
        if ($script:WimQueue) {
            $script:WimQueue.Enqueue([pscustomobject]@{ Kind = 'Log'; Level = $Level; Text = $line })
        }
        else {
            Write-Host $line
        }
    }

    function Send-WimUi {
        param([Parameter(Mandatory)][hashtable]$Payload)
        if ($script:WimQueue) { $script:WimQueue.Enqueue([pscustomobject]$Payload) }
    }

    function Set-WimStep {
        param(
            [Parameter(Mandatory)][int]$Index,
            [Parameter(Mandatory)][ValidateSet('Pending', 'Running', 'Done', 'Failed', 'Skipped')][string]$State,
            [string]$Detail = ''
        )
        Send-WimUi @{ Kind = 'Step'; Index = $Index; State = $State; Detail = $Detail }
    }

    function Set-WimProgress {
        param([double]$Percent = -1, [string]$Text = '')
        Send-WimUi @{ Kind = 'Progress'; Percent = $Percent; Text = $Text }
    }

    # ---- environment ------------------------------------------------------------

    function Test-WimElevated {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    }

    function Get-WimOscdimgPath {
        <# Locates oscdimg.exe. Prefers the native architecture, falls back to a registry-driven
           lookup of the ADK install root so non-default ADK locations still work. #>
        $kitRoots = @()
        foreach ($hive in 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots',
                          'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots') {
            try {
                $v = (Get-ItemProperty -Path $hive -Name 'KitsRoot10' -ErrorAction Stop).KitsRoot10
                if ($v) { $kitRoots += $v }
            }
            catch { }
        }
        $kitRoots += 'C:\Program Files (x86)\Windows Kits\10\'
        $kitRoots += 'C:\Program Files\Windows Kits\10\'

        $archOrder = switch ($env:PROCESSOR_ARCHITECTURE) {
            'ARM64' { @('arm64', 'amd64', 'x86') }
            'x86'   { @('x86', 'amd64') }
            default { @('amd64', 'x86', 'arm64') }
        }

        foreach ($root in ($kitRoots | Select-Object -Unique)) {
            foreach ($arch in $archOrder) {
                $candidate = Join-Path $root "Assessment and Deployment Kit\Deployment Tools\$arch\Oscdimg\oscdimg.exe"
                if (Test-Path -LiteralPath $candidate) { return $candidate }
            }
        }
        return $null
    }

    function Get-WimFreeSpaceBytes {
        param([Parameter(Mandatory)][string]$Path)
        $root = [System.IO.Path]::GetPathRoot((Resolve-WimFullPath $Path))
        try { return (New-Object System.IO.DriveInfo($root)).AvailableFreeSpace }
        catch { return -1 }
    }

    function Resolve-WimFullPath {
        param([Parameter(Mandatory)][string]$Path)
        [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path))
    }

    function Test-WimSyncedPath {
        <# Large scratch files inside OneDrive/Dropbox get uploaded. Warn, do not block. #>
        param([Parameter(Mandatory)][string]$Path)
        $p = $Path.ToLowerInvariant()
        foreach ($marker in 'onedrive', 'dropbox', 'google drive', 'icloud') {
            if ($p -like "*$marker*") { return $true }
        }
        return $false
    }

    function Format-WimSize {
        param([Parameter(Mandatory)][double]$Bytes)
        $units = 'B', 'KB', 'MB', 'GB', 'TB'
        $i = 0
        while ($Bytes -ge 1024 -and $i -lt $units.Count - 1) { $Bytes /= 1024; $i++ }
        '{0:N2} {1}' -f $Bytes, $units[$i]
    }

    # ---- process runner ---------------------------------------------------------

    function Invoke-WimProcess {
        <#  Runs a console tool and streams its output.

            Two things this has to get right:
            * stderr is drained asynchronously from the moment the process starts. Draining stdout
              to EOF first and only then reading stderr deadlocks as soon as the child fills the
              stderr pipe buffer - which DISM does on exactly the error paths that matter.
            * stdout is read in async chunks with a 100 ms timeout rather than a blocking Read(),
              so Cancel still works for tools that go quiet for minutes (oscdimg's UDF write).

            Lines are assembled manually on CR *or* LF so carriage-return progress output
            (DISM, oscdimg) is surfaced instead of arriving as one giant line at the end.
            Returns the process exit code, or -1 if it was killed. #>
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$FilePath,
            [Parameter(Mandatory)][string]$Arguments,
            [scriptblock]$OnLine,
            [hashtable]$Sync
        )

        Write-WimLog "> $FilePath $Arguments" -Level Cmd

        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName               = $FilePath
        $psi.Arguments              = $Arguments
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true

        $proc = [System.Diagnostics.Process]::new()
        $proc.StartInfo = $psi
        $null = $proc.Start()

        $errTask  = $proc.StandardError.ReadToEndAsync()
        $out      = $proc.StandardOutput
        $buffer   = [char[]]::new(4096)
        $sb       = [System.Text.StringBuilder]::new()
        $readTask = $null
        $killed   = $false

        try {
            while ($true) {
                if ($null -eq $readTask) { $readTask = $out.ReadAsync($buffer, 0, $buffer.Length) }

                $completed = $false
                try { $completed = $readTask.Wait(100) }
                catch { break }   # stream faulted / closed

                if ($completed) {
                    $count = $readTask.Result
                    $readTask = $null
                    if ($count -le 0) { break }

                    for ($i = 0; $i -lt $count; $i++) {
                        $c = $buffer[$i]
                        if ($c -eq "`n" -or $c -eq "`r") {
                            if ($sb.Length -gt 0) {
                                $line = $sb.ToString().Trim()
                                $null = $sb.Clear()
                                if ($line -and $OnLine) { & $OnLine $line }
                            }
                        }
                        else {
                            $null = $sb.Append($c)
                        }
                    }
                }

                if ($Sync -and $Sync.Cancel -and -not $proc.HasExited) {
                    Write-WimLog "Cancellation requested - terminating $([System.IO.Path]::GetFileName($FilePath))." -Level Warn
                    try { $proc.Kill() } catch { }
                    $killed = $true
                    break
                }
            }

            if (-not $killed -and $sb.Length -gt 0 -and $OnLine) { & $OnLine $sb.ToString().Trim() }

            $proc.WaitForExit()

            if (-not $killed) {
                $stdErr = ''
                try { $stdErr = $errTask.Result } catch { }
                if ($stdErr -and $stdErr.Trim()) { Write-WimLog $stdErr.Trim() -Level Warn }
            }
            return $proc.ExitCode
        }
        finally {
            $proc.Dispose()
        }
    }

    # ---- ADK --------------------------------------------------------------------

    function Install-WimAdk {
        <# Tries winget first (deterministic, patched, no HTML scraping); falls back to the
           pinned Microsoft fwlink installers when winget is unavailable or blocked. #>
        [CmdletBinding()]
        param([hashtable]$Sync)

        $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
        if ($winget) {
            Write-WimLog 'winget found - installing Windows ADK + WinPE add-on.' -Level Info
            $ok = $true
            foreach ($pkg in 'Microsoft.WindowsADK', 'Microsoft.ADKPEAddon') {
                $wgArgs = "install --id $pkg --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity"
                $code = Invoke-WimProcess -FilePath $winget.Source -Arguments $wgArgs -Sync $Sync -OnLine {
                    param($l) Write-WimLog $l -Level Raw
                }
                # 0 = installed, -1978335189 = already installed / no applicable upgrade
                if ($code -ne 0 -and $code -ne -1978335189) {
                    Write-WimLog "winget returned $code for $pkg - falling back to direct download." -Level Warn
                    $ok = $false
                }
            }
            if ($ok) { return $true }
        }
        else {
            Write-WimLog 'winget not available - using direct Microsoft download links.' -Level Warn
        }

        $dl = Join-Path $env:TEMP "$($script:AppSlug)\adk"
        $null = New-Item -ItemType Directory -Path $dl -Force

        $jobs = @(
            @{ Url = $script:AdkFwLink;   File = 'adksetup.exe';       Name = 'Windows ADK' }
            @{ Url = $script:AdkPeFwLink; File = 'adkwinpesetup.exe';  Name = 'Windows PE add-on' }
        )

        foreach ($j in $jobs) {
            $target = Join-Path $dl $j.File
            Write-WimLog "Downloading $($j.Name)..." -Level Info
            $oldPref = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'   # 10-50x faster Invoke-WebRequest
            try {
                Invoke-WebRequest -Uri $j.Url -OutFile $target -UseBasicParsing -MaximumRedirection 10
            }
            finally { $ProgressPreference = $oldPref }

            if (-not (Test-Path -LiteralPath $target)) { throw "Download failed: $($j.Name)" }
            Write-WimLog "Installing $($j.Name) (Deployment Tools feature)..." -Level Info

            # Only the Deployment Tools feature is needed for oscdimg - keeps the install small.
            $feature = if ($j.File -eq 'adksetup.exe') { ' /features OptionId.DeploymentTools' } else { '' }
            $code = Invoke-WimProcess -FilePath $target -Arguments "/quiet /norestart /ceip off$feature" -Sync $Sync -OnLine {
                param($l) Write-WimLog $l -Level Raw
            }
            if ($code -ne 0 -and $code -ne 3010) { throw "$($j.Name) installer exited with code $code." }
        }
        return $true
    }

    # ---- USB target -------------------------------------------------------------

    function Get-WimUsbDisk {
        <#  Returns only disks on the USB bus, and never the disk Windows boots from.
            Deliberately conservative: this feature destroys data, so a USB SSD in a fixed-
            reporting enclosure being absent from the list is the correct failure mode. #>
        [CmdletBinding()]
        param()

        $sysDisk = $null
        try {
            $sysDrive = ($env:SystemDrive).TrimEnd(':')
            $sysDisk = (Get-Partition -DriveLetter $sysDrive -ErrorAction Stop).DiskNumber
        }
        catch { }

        $out = @()
        foreach ($d in (Get-Disk -ErrorAction SilentlyContinue)) {
            if ($d.BusType -ne 'USB') { continue }
            if ($null -ne $sysDisk -and $d.Number -eq $sysDisk) { continue }
            if ($d.IsBoot -or $d.IsSystem) { continue }

            $letters = @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue |
                    Where-Object { $_.DriveLetter } | ForEach-Object { "$($_.DriveLetter):" })

            $out += [pscustomobject]@{
                Number       = $d.Number
                FriendlyName = $d.FriendlyName
                SerialNumber = "$($d.SerialNumber)".Trim()
                SizeBytes    = $d.Size
                SizeText     = (Format-WimSize $d.Size)
                Letters      = ($letters -join ' ')
                Display      = '[Disk {0}]  {1}  -  {2}{3}' -f $d.Number, $d.FriendlyName, (Format-WimSize $d.Size),
                                 $(if ($letters) { "  ($($letters -join ' '))" } else { '' })
            }
        }
        # No unary comma here: callers wrap in @() themselves, and emitting a single nested
        # array silently breaks every downstream Count / Where-Object / property access.
        $out | Sort-Object Number
    }

    function Test-WimBootableMedia {
        <# A stick with no boot loader is a wasted wipe. Check before destroying anything. #>
        param([Parameter(Mandatory)][string]$Path)
        $bios = Test-Path -LiteralPath (Join-Path $Path 'bootmgr')
        $uefi = Test-Path -LiteralPath (Join-Path $Path 'efi\boot\bootx64.efi')
        $arm  = Test-Path -LiteralPath (Join-Path $Path 'efi\boot\bootaa64.efi')
        if (-not ($bios -or $uefi -or $arm)) {
            throw "The media at '$Path' contains no boot loader (no bootmgr, no efi\boot\boot*.efi). It would not produce a bootable stick, so the disk was left untouched. Point at a full set of Windows media, not just the .swm files."
        }
    }

    function Test-WimFat32Payload {
        <# Nothing on a FAT32 stick may be >= 4 GiB. Fail before wiping the disk, not after. #>
        param([Parameter(Mandatory)][string]$Path)
        $big = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Length -ge 4GB })
        if ($big) {
            $names = ($big | ForEach-Object { "$($_.Name) ($(Format-WimSize $_.Length))" }) -join ', '
            throw "These files are 4 GiB or larger and cannot be copied to FAT32: $names. Run the split first."
        }
    }

    function Invoke-WimUsbPrep {
        <#  Wipes the selected disk and lays down:
              partition 1 - primary, FAT32, active, capped at 32 GB (boot + setup media)
              partition 2 - primary, NTFS, remaining space (optional)
            Then robocopies the media across.

            diskpart is used rather than the Storage cmdlets because this is the sequence
            that is documented, reproducible by hand, and verifiable in the log. #>
        [CmdletBinding()]
        param([Parameter(Mandatory)][hashtable]$Job, [Parameter(Mandatory)][hashtable]$Sync)

        $mountedIso = $null
        $result = @{ Success = $false; Message = ''; OutputPath = '' }

        function Assert-NotCancelled {
            if ($Sync.Cancel) { throw [System.OperationCanceledException]::new('Cancelled by user.') }
        }

        try {
            # === Step 0: validate ==============================================
            Set-WimStep 0 Running
            Set-WimProgress -Percent -1 -Text 'Validating target disk'

            Write-WimLog "$($script:AppName) $($script:AppVersion) - USB preparation started." -Level Info

            if (-not (Test-WimElevated)) { throw 'Administrator rights are required to partition a disk.' }

            $diskNumber = [int]$Job.DiskNumber
            $all  = @(Get-WimUsbDisk)
            $disk = @($all | Where-Object { $_.Number -eq $diskNumber })[0]
            if (-not $disk) {
                throw "Disk $diskNumber is no longer present as a removable USB disk. Refresh the list and try again."
            }

            # Disk numbers are recycled. Between confirmation and execution (which can be 30+
            # minutes when chained after a split) the user may have swapped sticks, so re-verify
            # the identity that was actually confirmed - not just the number.
            if ($Job.ExpectSerial -or $Job.ExpectSize) {
                $sameSerial = (-not $Job.ExpectSerial) -or ($disk.SerialNumber -eq $Job.ExpectSerial)
                $sameSize   = (-not $Job.ExpectSize) -or ([long]$disk.SizeBytes -eq [long]$Job.ExpectSize)
                $sameName   = (-not $Job.ExpectName) -or ($disk.FriendlyName -eq $Job.ExpectName)
                if (-not ($sameSerial -and $sameSize -and $sameName)) {
                    throw "Disk $diskNumber is not the disk you confirmed. Confirmed: '$($Job.ExpectName)' $(Format-WimSize ([long]$Job.ExpectSize)) serial '$($Job.ExpectSerial)'. Present: '$($disk.FriendlyName)' $($disk.SizeText) serial '$($disk.SerialNumber)'. Nothing was erased."
                }
            }

            Write-WimLog "Target: $($disk.Display)" -Level Warn
            Write-WimLog "Serial: '$($disk.SerialNumber)'" -Level Info
            Write-WimLog 'ALL DATA ON THIS DISK WILL BE DESTROYED.' -Level Warn

            # Resolve the media source: a folder is used as-is, an ISO is mounted read-only.
            $media = Resolve-WimFullPath $Job.MediaPath
            if (-not (Test-Path -LiteralPath $media)) { throw "Media source not found: $media" }

            if ((Get-Item -LiteralPath $media).PSIsContainer) {
                $mediaRoot = $media
            }
            else {
                if ([System.IO.Path]::GetExtension($media).ToLowerInvariant() -ne '.iso') {
                    throw 'Media source must be a folder or an ISO file.'
                }
                Write-WimLog "Mounting media ISO read-only: $media" -Level Info
                $null = Mount-DiskImage -ImagePath $media -StorageType ISO -Access ReadOnly -PassThru
                $mountedIso = $media
                $vol = $null
                for ($try = 0; $try -lt 20 -and -not $vol; $try++) {
                    $vol = Get-DiskImage -ImagePath $media | Get-Volume |
                        Where-Object { $_.DriveLetter } | Select-Object -First 1
                    if (-not $vol) { Start-Sleep -Milliseconds 250 }
                }
                if (-not $vol) { throw 'The media ISO mounted but exposed no drive letter.' }
                $mediaRoot = "$($vol.DriveLetter):\"
            }

            Write-WimLog "Media source: $mediaRoot" -Level Info
            Test-WimFat32Payload -Path $mediaRoot
            Test-WimBootableMedia -Path $mediaRoot

            $mediaBytes = (Get-ChildItem -LiteralPath $mediaRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum).Sum
            if (-not $mediaBytes) { throw "Media source is empty: $mediaRoot" }
            Write-WimLog "Media size: $(Format-WimSize $mediaBytes)" -Level Info

            $bootMB = [Math]::Min($script:Fat32MaxMB, [int]([Math]::Floor($disk.SizeBytes / 1MB)) - 8)
            if (($bootMB * 1MB) -lt $mediaBytes) {
                throw "The media is $(Format-WimSize $mediaBytes) but the FAT32 boot partition can only be $(Format-WimSize ($bootMB * 1MB)). Use a larger stick."
            }

            $remainderMB = [int]([Math]::Floor($disk.SizeBytes / 1MB)) - $bootMB - 8
            $wantNtfs = [bool]$Job.CreateNtfsRemainder -and $remainderMB -gt 1024

            Set-WimStep 0 Done
            Assert-NotCancelled

            # === Step 1: partition and format ==================================
            Set-WimStep 1 Running
            Set-WimProgress -Percent -1 -Text 'Partitioning and formatting'

            $lines = @(
                "select disk $diskNumber"
                'clean'
                'convert mbr noerr'   # redundant after clean, but harmless and explicit; noerr so
                                      # an already-MBR disk does not abort the rest of the script
                "create partition primary size=$bootMB"
                'select partition 1'
                "format fs=fat32 quick label=$($Job.BootLabel)"
                'active'
                'assign'
            )
            if ($wantNtfs) {
                $lines += @(
                    'create partition primary'
                    'select partition 2'
                    "format fs=ntfs quick label=$($Job.DataLabel)"
                    'assign'
                )
                Write-WimLog "Second partition: NTFS, $(Format-WimSize ($remainderMB * 1MB))" -Level Info
            }
            $lines += 'list partition'

            $scriptFile = Join-Path $env:TEMP ("$($script:AppSlug)_diskpart_{0}.txt" -f ([guid]::NewGuid().ToString('N')))
            Set-Content -LiteralPath $scriptFile -Value $lines -Encoding ASCII

            Write-WimLog 'diskpart script:' -Level Info
            foreach ($l in $lines) { Write-WimLog "    $l" -Level Raw }

            try {
                $code = Invoke-WimProcess -FilePath "$env:SystemRoot\System32\diskpart.exe" `
                    -Arguments "/s `"$scriptFile`"" -Sync $Sync -OnLine {
                    param($line) Write-WimLog $line -Level Raw
                }
            }
            finally {
                Remove-Item -LiteralPath $scriptFile -Force -ErrorAction SilentlyContinue
            }

            Assert-NotCancelled
            if ($code -ne 0) { throw "diskpart failed with exit code $code. The disk may be left in a partially modified state." }

            # Do not trust diskpart's text output - ask the storage stack where the volume landed.
            $bootVol = $null
            for ($try = 0; $try -lt 24 -and -not $bootVol; $try++) {
                Start-Sleep -Milliseconds 500
                $bootVol = Get-Partition -DiskNumber $diskNumber -ErrorAction SilentlyContinue |
                    Where-Object { $_.PartitionNumber -eq 1 -and $_.DriveLetter } |
                    Select-Object -First 1
            }
            if (-not $bootVol) { throw 'The FAT32 partition was created but Windows did not assign it a drive letter.' }

            $usbRoot = "$($bootVol.DriveLetter):"
            $fs = (Get-Volume -DriveLetter $bootVol.DriveLetter).FileSystem
            Write-WimLog "Boot partition ready at $usbRoot ($fs)" -Level Ok
            if ($fs -ne 'FAT32') { throw "Partition 1 formatted as '$fs', not FAT32. Aborting before copy." }

            Set-WimStep 1 Done
            Assert-NotCancelled

            # === Step 2: copy ==================================================
            Set-WimStep 2 Running
            Set-WimProgress -Percent 0 -Text 'Copying media to USB'

            $totalFiles = @(Get-ChildItem -LiteralPath $mediaRoot -Recurse -File -Force -ErrorAction SilentlyContinue).Count
            Write-WimLog "Copying $totalFiles files to $usbRoot" -Level Info

            $counter = @{ Done = 0 }
            # A bare "X:" means "current directory on X:", not its root - so drive roots are
            # emitted unquoted with a trailing backslash (they cannot contain spaces anyway).
            $rcSrc = if ($mediaRoot -match '^[A-Za-z]:\\?$') { $mediaRoot.TrimEnd('\') + '\' }
                     else { '"' + $mediaRoot.TrimEnd('\') + '"' }
            $rcArgs = '{0} {1}\ /E /COPY:DAT /R:1 /W:2 /NP /NJH /NJS /NDL /BYTES' -f $rcSrc, $usbRoot.TrimEnd('\')
            $rc = Invoke-WimProcess -FilePath "$env:SystemRoot\System32\robocopy.exe" -Arguments $rcArgs -Sync $Sync -OnLine {
                param($line)
                $counter.Done++
                if ($totalFiles -gt 0) {
                    $n = [Math]::Min($counter.Done, $totalFiles)
                    Set-WimProgress -Percent (($n / $totalFiles) * 100) -Text "Copying: $n / $totalFiles files"
                }
            }

            Assert-NotCancelled
            if ($rc -ge 8) { throw "robocopy failed with exit code $rc while writing to the USB stick." }

            Set-WimStep 2 Done

            # === Step 3: verify ================================================
            Set-WimStep 3 Running
            Set-WimProgress -Percent -1 -Text 'Verifying'

            $missing = @()
            foreach ($p in 'sources', 'boot', 'efi') {
                if ((Test-Path -LiteralPath (Join-Path $mediaRoot $p)) -and
                    -not (Test-Path -LiteralPath (Join-Path "$usbRoot\" $p))) { $missing += $p }
            }
            if ($missing) { throw "Missing from the USB after copy: $($missing -join ', ')" }

            $bootMgr = Test-Path -LiteralPath (Join-Path "$usbRoot\" 'bootmgr')
            $efiBoot = Test-Path -LiteralPath (Join-Path "$usbRoot\" 'efi\boot\bootx64.efi')
            Write-WimLog "bootmgr present: $bootMgr    efi\boot\bootx64.efi present: $efiBoot" -Level Info
            if (-not $bootMgr -and -not $efiBoot) {
                Write-WimLog 'Neither bootmgr nor efi\boot\bootx64.efi is on the stick - it may not boot.' -Level Warn
            }

            $swm = @(Get-ChildItem -LiteralPath (Join-Path "$usbRoot\" 'sources') -Filter '*.swm' -File -ErrorAction SilentlyContinue)
            if ($swm) { Write-WimLog "$($swm.Count) .swm part(s) on the stick." -Level Ok }

            Set-WimStep 3 Done
            Set-WimProgress -Percent 100 -Text 'USB ready'

            $result.Success = $true
            $result.OutputPath = "$usbRoot\"
            $result.Message = "USB ready at $usbRoot.`n`nFAT32 boot partition: $(Format-WimSize ($bootMB * 1MB))" +
                $(if ($wantNtfs) { "`nNTFS data partition: $(Format-WimSize ($remainderMB * 1MB))" } else { '' })
            return $result
        }
        catch [System.OperationCanceledException] {
            Write-WimLog 'USB preparation cancelled. The disk may be partially modified.' -Level Warn
            $result.Message = 'Cancelled. The target disk may be left partially modified - re-run to finish.'
            return $result
        }
        catch {
            Write-WimLog "FAILED: $($_.Exception.Message)" -Level Error
            $result.Message = $_.Exception.Message
            return $result
        }
        finally {
            if ($mountedIso) {
                try { Dismount-DiskImage -ImagePath $mountedIso -ErrorAction Stop | Out-Null }
                catch { Write-WimLog "Could not dismount $mountedIso : $($_.Exception.Message)" -Level Warn }
            }
        }
    }

    # ---- main pipeline ----------------------------------------------------------

    function Invoke-WimSplitJob {
        [CmdletBinding()]
        param([Parameter(Mandatory)][hashtable]$Job, [Parameter(Mandatory)][hashtable]$Sync)

        $mountedIso = $null
        $workDir    = $null
        # MediaRoot is what a follow-on USB write should copy from - the extracted tree if it
        # survives cleanup, otherwise the rebuilt ISO.
        $result     = @{ Success = $false; Message = ''; OutputPath = ''; MediaRoot = '' }

        function Assert-NotCancelled {
            if ($Sync.Cancel) { throw [System.OperationCanceledException]::new('Cancelled by user.') }
        }

        try {
            $source     = Resolve-WimFullPath $Job.SourcePath
            $workRoot   = Resolve-WimFullPath $Job.WorkRoot
            $outputRoot = Resolve-WimFullPath $Job.OutputRoot
            $ext        = [System.IO.Path]::GetExtension($source).ToLowerInvariant()
            $baseName   = [System.IO.Path]::GetFileNameWithoutExtension($source)
            # oscdimg's -bootdata argument is fragile around spaces; keep the scratch path space-free.
            $safeName   = ($baseName -replace '[^\w\-]', '_')

            # === Step 0: validate ===============================================
            Set-WimStep 0 Running
            Set-WimProgress -Percent -1 -Text 'Validating environment'

            Write-WimLog "$($script:AppName) $($script:AppVersion) - run started." -Level Info
            Write-WimLog "Source     : $source" -Level Info
            Write-WimLog "Work root  : $workRoot" -Level Info
            Write-WimLog "Output root: $outputRoot" -Level Info
            Write-WimLog "Split size : $($Job.SplitSizeMB) MB" -Level Info

            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Source not found: $source" }
            if ($ext -notin '.iso', '.wim', '.esd') { throw "Unsupported source type '$ext'. Use .iso, .wim or .esd." }

            $sourceInfo  = Get-Item -LiteralPath $source
            $sourceBytes = $sourceInfo.Length
            Write-WimLog "Source size: $(Format-WimSize $sourceBytes)" -Level Info

            # Hard guard: never let output or work land in the source folder.
            $sourceDir = [System.IO.Path]::GetDirectoryName($source).TrimEnd('\')
            foreach ($p in @{ n = 'Output folder'; v = $outputRoot }, @{ n = 'Work folder'; v = $workRoot }) {
                if ($p.v.TrimEnd('\').Equals($sourceDir, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "$($p.n) must not be the same folder as the source file. The source must stay untouched."
                }
            }

            # Work and Output usually land on the same volume, so requirements must be summed
            # per volume - checking them independently understates the need by ~2x.
            $folders = @()
            if ($ext -eq '.iso') { $folders += @{ n = 'Work'; v = $workRoot; f = 1.15 } }
            $folders += @{ n = 'Output'; v = $outputRoot; f = 1.15 }

            $volumeNeeds = @{}
            foreach ($p in $folders) {
                $null = New-Item -ItemType Directory -Path $p.v -Force
                if (Test-WimSyncedPath $p.v) {
                    Write-WimLog "$($p.n) folder is inside a cloud-synced location - multi-GB files will be uploaded. Consider a local path." -Level Warn
                }
                $root = [System.IO.Path]::GetPathRoot((Resolve-WimFullPath $p.v)).ToUpperInvariant()
                if (-not $volumeNeeds.ContainsKey($root)) { $volumeNeeds[$root] = @{ Bytes = [long]0; Names = @() } }
                $volumeNeeds[$root].Bytes += [long]($sourceBytes * $p.f)
                $volumeNeeds[$root].Names += $p.n
            }

            foreach ($root in $volumeNeeds.Keys) {
                $needed = $volumeNeeds[$root].Bytes
                $who    = $volumeNeeds[$root].Names -join ' + '
                $free   = Get-WimFreeSpaceBytes $root
                if ($free -lt 0) { continue }
                Write-WimLog "$root free: $(Format-WimSize $free) - need ~$(Format-WimSize $needed) for $who" -Level Info
                if ($free -lt $needed) {
                    throw "Not enough free space on $root. Need ~$(Format-WimSize $needed) for $who, have $(Format-WimSize $free)."
                }
            }

            if ($ext -eq '.iso') {
                if (-not (Test-WimElevated)) { throw 'Administrator rights are required to mount an ISO. Restart elevated.' }
                $script:OscdimgPath = Get-WimOscdimgPath
                if (-not $script:OscdimgPath) {
                    throw "oscdimg.exe not found. Install the Windows ADK Deployment Tools (use the ADK button), then retry."
                }
                Write-WimLog "oscdimg    : $($script:OscdimgPath)" -Level Info
            }

            Set-WimStep 0 Done
            Assert-NotCancelled

            # === Step 1: extract ================================================
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

            if ($ext -eq '.iso') {
                Set-WimStep 1 Running
                Set-WimProgress -Percent 0 -Text 'Mounting ISO'

                $workDir = Join-Path $workRoot "$safeName`_$stamp"
                $null = New-Item -ItemType Directory -Path $workDir -Force

                # ReadOnly is explicit belt-and-braces: the source ISO is never written to.
                $null = Mount-DiskImage -ImagePath $source -StorageType ISO -Access ReadOnly -PassThru
                $mountedIso = $source

                # The volume is not always surfaced the instant Mount-DiskImage returns, and a
                # multi-partition image exposes more than one. Wait for a lettered volume, take the first.
                $vol = $null
                for ($try = 0; $try -lt 20 -and -not $vol; $try++) {
                    $vol = Get-DiskImage -ImagePath $source | Get-Volume |
                        Where-Object { $_.DriveLetter } | Select-Object -First 1
                    if (-not $vol) { Start-Sleep -Milliseconds 250 }
                }
                if (-not $vol) { throw 'The ISO mounted but no volume with a drive letter appeared.' }

                $drive = "$($vol.DriveLetter):"
                $isoLabel = $vol.FileSystemLabel
                Write-WimLog "ISO mounted read-only at $drive (label: '$isoLabel')" -Level Ok

                Set-WimProgress -Percent 0 -Text 'Counting source files'
                $totalFiles = @(Get-ChildItem -LiteralPath "$drive\" -Recurse -File -Force -ErrorAction SilentlyContinue).Count
                Write-WimLog "Copying $totalFiles files to $workDir" -Level Info

                # Hashtable so the callback (which runs in its own scope) can mutate the counter.
                $counter = @{ Done = 0 }
                # NOT "{0}\" - a trailing backslash inside quotes escapes the quote under CRT argv
                # parsing and robocopy sees a malformed source. A drive root cannot contain a space.
                $rcArgs = '{0}\ "{1}" /E /COPY:DAT /DCOPY:T /R:2 /W:2 /NP /NJH /NJS /NDL /BYTES' -f $drive, $workDir
                $rc = Invoke-WimProcess -FilePath "$env:SystemRoot\System32\robocopy.exe" -Arguments $rcArgs -Sync $Sync -OnLine {
                    param($line)
                    $counter.Done++
                    if ($totalFiles -gt 0) {
                        $n = [Math]::Min($counter.Done, $totalFiles)
                        Set-WimProgress -Percent (($n / $totalFiles) * 100) -Text "Extracting: $n / $totalFiles files"
                    }
                }

                Assert-NotCancelled
                # Robocopy: 0-7 are success / informational, >=8 means at least one copy failed.
                if ($rc -ge 8) { throw "robocopy failed with exit code $rc." }
                Write-WimLog "Extraction complete (robocopy exit $rc)." -Level Ok

                Dismount-DiskImage -ImagePath $source | Out-Null
                $mountedIso = $null
                Write-WimLog 'ISO dismounted.' -Level Info

                # Files copied off an ISO carry the read-only attribute; clear it so DISM/oscdimg can work.
                $null = Invoke-WimProcess -FilePath "$env:SystemRoot\System32\attrib.exe" -Arguments "-R `"$workDir\*`" /S /D" -Sync $Sync

                Set-WimStep 1 Done
            }
            else {
                Set-WimStep 1 Skipped 'not an ISO'
                Write-WimLog 'Source is a bare image file - no extraction needed.' -Level Info
                $isoLabel = $null
            }
            Assert-NotCancelled

            # === Step 2: locate image ==========================================
            Set-WimStep 2 Running
            Set-WimProgress -Percent -1 -Text 'Locating Windows image'

            if ($ext -eq '.iso') {
                $sourcesDir = Join-Path $workDir 'sources'
                $wimPath = Join-Path $sourcesDir 'install.wim'
                $esdPath = Join-Path $sourcesDir 'install.esd'

                if (-not (Test-Path -LiteralPath $wimPath)) {
                    if (Test-Path -LiteralPath $esdPath) {
                        Write-WimLog 'Found install.esd instead of install.wim. Exporting to WIM so it can be split (this is slow).' -Level Warn
                        $images = Get-WindowsImage -ImagePath $esdPath
                        foreach ($im in $images) {
                            Write-WimLog "Exporting index $($im.ImageIndex): $($im.ImageName)" -Level Info
                            Export-WindowsImage -SourceImagePath $esdPath -SourceIndex $im.ImageIndex `
                                -DestinationImagePath $wimPath -CompressionType Max -CheckIntegrity | Out-Null
                            Assert-NotCancelled
                        }
                        Remove-Item -LiteralPath $esdPath -Force
                        Write-WimLog 'ESD converted to WIM and original ESD removed from the working copy.' -Level Ok
                    }
                    else {
                        throw "Neither sources\install.wim nor sources\install.esd was found in the extracted media."
                    }
                }
            }
            else {
                $wimPath = $source
                $sourcesDir = $outputRoot
            }

            $wimBytes = (Get-Item -LiteralPath $wimPath).Length
            $limit    = [long]$Job.SplitSizeMB * 1MB
            Write-WimLog "Image: $wimPath ($(Format-WimSize $wimBytes))" -Level Info

            try {
                foreach ($im in (Get-WindowsImage -ImagePath $wimPath)) {
                    Write-WimLog ("  index {0}: {1}" -f $im.ImageIndex, $im.ImageName) -Level Raw
                }
            }
            catch { Write-WimLog "Could not enumerate image indexes: $($_.Exception.Message)" -Level Warn }

            Set-WimStep 2 Done
            Assert-NotCancelled

            # === Step 3: split =================================================
            if ($wimBytes -le $limit) {
                Set-WimStep 3 Skipped 'already under the size limit'
                Write-WimLog "Image is already $(Format-WimSize $wimBytes), under the $($Job.SplitSizeMB) MB limit. No split needed - this media already works on FAT32." -Level Ok
                Set-WimStep 4 Skipped
                Set-WimStep 5 Skipped
                $result.Success = $true
                # MediaRoot deliberately left empty: nothing was produced, so a chained USB
                # write must not fire and must never fall back to a previous run's path.
                $result.Message = "No action needed. The image is already FAT32-compatible ($(Format-WimSize $wimBytes))."
                return $result
            }

            Set-WimStep 3 Running
            Set-WimProgress -Percent 0 -Text 'Splitting image'

            $swmDir = if ($ext -eq '.iso') { $sourcesDir } else { Join-Path $outputRoot "$baseName`_$stamp" }
            $null = New-Item -ItemType Directory -Path $swmDir -Force
            $swmName = if ($ext -eq '.iso') { 'install.swm' } else { "$baseName.swm" }
            $swmPath = Join-Path $swmDir $swmName

            Get-ChildItem -LiteralPath $swmDir -Filter '*.swm' -File -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue

            $dismArgs = '/English /Split-Image /ImageFile:"{0}" /SWMFile:"{1}" /FileSize:{2}' -f $wimPath, $swmPath, $Job.SplitSizeMB
            $code = Invoke-WimProcess -FilePath "$env:SystemRoot\System32\dism.exe" -Arguments $dismArgs -Sync $Sync -OnLine {
                param($line)
                if ($line -match '(\d+(?:[.,]\d+)?)\s*%') {
                    Set-WimProgress -Percent ([double]($Matches[1] -replace ',', '.')) -Text 'Splitting image'
                }
                elseif ($line -notmatch '^\[[\s=%.]*\]$') {
                    Write-WimLog $line -Level Raw
                }
            }
            Assert-NotCancelled   # a killed process reports -1; report that as cancelled, not failed
            if ($code -ne 0) { throw "DISM /Split-Image failed with exit code $code." }

            $swmFiles = @(Get-ChildItem -LiteralPath $swmDir -Filter '*.swm' -File | Sort-Object Name)
            if ($swmFiles.Count -eq 0) { throw 'DISM reported success but produced no .swm files. Aborting - nothing was deleted.' }
            Write-WimLog "Created $($swmFiles.Count) .swm part(s):" -Level Ok
            foreach ($f in $swmFiles) { Write-WimLog ("  {0} - {1}" -f $f.Name, (Format-WimSize $f.Length)) -Level Raw }

            $oversize = $swmFiles | Where-Object { $_.Length -ge 4GB }
            if ($oversize) { throw "One or more .swm parts are >= 4 GiB and will not fit on FAT32: $($oversize.Name -join ', ')" }

            # Only now is it safe to drop the WIM - and only from the working copy, never the source.
            if ($ext -eq '.iso') {
                Remove-Item -LiteralPath $wimPath -Force
                Write-WimLog 'Removed install.wim from the working copy (source ISO untouched).' -Level Info
            }

            Set-WimStep 3 Done
            Assert-NotCancelled

            # === Step 4: rebuild ISO ===========================================
            if ($ext -ne '.iso') {
                Set-WimStep 4 Skipped 'source was a bare image'
                $result.Success = $true
                $result.OutputPath = $swmDir
                $result.MediaRoot = $swmDir
                $result.Message = "Split complete. $($swmFiles.Count) .swm part(s) written to:`n$swmDir"
                Set-WimStep 5 Done
                return $result
            }

            Set-WimStep 4 Running
            Set-WimProgress -Percent 0 -Text 'Building bootable ISO'

            $newIso = Join-Path $outputRoot "$baseName`_FAT32.iso"
            if (Test-Path -LiteralPath $newIso) {
                $newIso = Join-Path $outputRoot "$baseName`_FAT32_$stamp.iso"
            }

            $biosBoot = Join-Path $workDir 'boot\etfsboot.com'
            $uefiBoot = Join-Path $workDir 'efi\microsoft\boot\efisys.bin'
            $hasBios  = Test-Path -LiteralPath $biosBoot
            $hasUefi  = Test-Path -LiteralPath $uefiBoot

            if (-not $hasUefi) {
                throw "efi\microsoft\boot\efisys.bin is missing from the extracted media - the rebuilt ISO could not boot UEFI."
            }

            # This is the part the old script was missing entirely: without -bootdata the ISO is not bootable.
            $bootData = if ($hasBios) {
                '-bootdata:2#p0,e,b"{0}"#pEF,e,b"{1}"' -f $biosBoot, $uefiBoot
            }
            else {
                Write-WimLog 'boot\etfsboot.com not present (UEFI-only / ARM64 media) - building a UEFI-only bootable ISO.' -Level Warn
                '-bootdata:1#pEF,e,b"{0}"' -f $uefiBoot
            }

            # oscdimg takes the label as -l<value> with no quoting support, so strip anything awkward.
            $label = if ($isoLabel) { ($isoLabel -replace '[^\w\-]', '_').Trim('_') } else { '' }
            if ($label.Length -gt 32) { $label = $label.Substring(0, 32) }
            $labelArg = if ($label) { " -l$label" } else { '' }

            $oscArgs = '-m -o -u2 -udfver102{0} {1} "{2}" "{3}"' -f $labelArg, $bootData, $workDir, $newIso
            $code = Invoke-WimProcess -FilePath $script:OscdimgPath -Arguments $oscArgs -Sync $Sync -OnLine {
                param($line)
                if ($line -match '(\d+)%') { Set-WimProgress -Percent ([double]$Matches[1]) -Text 'Building bootable ISO' }
                else { Write-WimLog $line -Level Raw }
            }
            Assert-NotCancelled
            if ($code -ne 0) { throw "oscdimg failed with exit code $code." }
            if (-not (Test-Path -LiteralPath $newIso)) { throw 'oscdimg reported success but no ISO was produced.' }

            Set-WimStep 4 Done
            Assert-NotCancelled

            # === Step 5: verify + clean up =====================================
            Set-WimStep 5 Running
            Set-WimProgress -Percent -1 -Text 'Verifying output'

            $isoInfo = Get-Item -LiteralPath $newIso
            Write-WimLog "New ISO: $newIso ($(Format-WimSize $isoInfo.Length))" -Level Ok
            if ($isoInfo.Length -lt ($sourceBytes * 0.5)) {
                Write-WimLog 'New ISO is much smaller than the source - verify its contents before use.' -Level Warn
            }

            if ($Job.ComputeHash) {
                Set-WimProgress -Percent -1 -Text 'Computing SHA256'
                $hash = (Get-FileHash -LiteralPath $newIso -Algorithm SHA256).Hash
                Write-WimLog "SHA256: $hash" -Level Info
            }

            # Keeping the extracted tree lets a follow-on USB write copy files directly instead
            # of re-mounting the ISO we just built.
            if ($Job.CleanWorkFolder -and -not $Job.KeepMediaForUsb) {
                Write-WimLog "Removing working folder $workDir" -Level Info
                Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
                $result.MediaRoot = $newIso
                $workDir = $null
            }
            else {
                Write-WimLog "Working folder kept at $workDir" -Level Info
                $result.MediaRoot = $workDir
            }

            Set-WimStep 5 Done
            Set-WimProgress -Percent 100 -Text 'Complete'

            $result.Success = $true
            $result.OutputPath = $newIso
            $result.Message = "Done. Bootable FAT32-ready ISO created:`n$newIso`n`n$($swmFiles.Count) .swm part(s), largest $(Format-WimSize ($swmFiles | Measure-Object Length -Maximum).Maximum)."
            return $result
        }
        catch [System.OperationCanceledException] {
            Write-WimLog 'Run cancelled by user.' -Level Warn
            $result.Message = 'Cancelled.'
            return $result
        }
        catch {
            Write-WimLog "FAILED: $($_.Exception.Message)" -Level Error
            if ($_.ScriptStackTrace) { Write-WimLog $_.ScriptStackTrace -Level Raw }
            $result.Message = $_.Exception.Message
            return $result
        }
        finally {
            # Always release the ISO, even on a hard failure - the old script leaked mounts.
            if ($mountedIso) {
                try {
                    Dismount-DiskImage -ImagePath $mountedIso -ErrorAction Stop | Out-Null
                    Write-WimLog 'Source ISO dismounted during cleanup.' -Level Info
                }
                catch { Write-WimLog "Could not dismount $mountedIso : $($_.Exception.Message)" -Level Warn }
            }
        }
    }
}

. $Engine

#endregion

#region ---------------------------------------------------------------- Settings

function Get-WimSettings {
    $defaults = [ordered]@{
        WorkRoot        = Join-Path $env:SystemDrive 'WinMediaBuilder\Work'
        OutputRoot      = Join-Path $env:SystemDrive 'WinMediaBuilder\Output'
        LogDirectory    = Join-Path $env:SystemDrive 'WinMediaBuilder\Logs'
        SplitSizeMB     = 4000
        CleanWorkFolder = $true
        ComputeHash     = $false
        LastSource      = ''
        CreateNtfsRemainder = $true
    }
    if (Test-Path -LiteralPath $script:SettingsPath) {
        try {
            $saved = Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json
            foreach ($k in @($defaults.Keys)) {
                if ($saved.PSObject.Properties.Name -contains $k -and $null -ne $saved.$k) { $defaults[$k] = $saved.$k }
            }
        }
        catch { }
    }
    $defaults
}

function Save-WimSettings {
    param([Parameter(Mandatory)]$Settings)
    try {
        $dir = Split-Path -Parent $script:SettingsPath
        $null = New-Item -ItemType Directory -Path $dir -Force
        $Settings | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
    }
    catch { }
}

#endregion

#region ---------------------------------------------------------------- UI

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Warning "PowerShell is running MTA. Relaunch with: powershell.exe -STA -File `"$PSCommandPath`""
}

$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WinMedia Builder" Height="880" Width="1240"
        ResizeMode="CanMinimize" SizeToContent="Manual"
        WindowStartupLocation="CenterScreen" Background="#FF2E3440"
        FontFamily="Segoe UI" TextOptions.TextFormattingMode="Display" UseLayoutRounding="True">

  <Window.Resources>
    <SolidColorBrush x:Key="Bg0"    Color="#2E3440"/>
    <SolidColorBrush x:Key="Bg1"    Color="#343B49"/>
    <SolidColorBrush x:Key="Bg2"    Color="#3B4252"/>
    <SolidColorBrush x:Key="Bg3"    Color="#4C566A"/>
    <SolidColorBrush x:Key="Line"   Color="#434C5E"/>
    <SolidColorBrush x:Key="Fg0"    Color="#ECEFF4"/>
    <SolidColorBrush x:Key="Fg1"    Color="#D8DEE9"/>
    <SolidColorBrush x:Key="Muted"  Color="#8A94A6"/>
    <SolidColorBrush x:Key="Accent" Color="#88C0D0"/>
    <SolidColorBrush x:Key="Deep"   Color="#5E81AC"/>
    <SolidColorBrush x:Key="Ok"     Color="#A3BE8C"/>
    <SolidColorBrush x:Key="Warn"   Color="#EBCB8B"/>
    <SolidColorBrush x:Key="Err"    Color="#BF616A"/>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource Bg1}"/>
      <Setter Property="CornerRadius" Value="10"/>
      <Setter Property="Padding" Value="18,15"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
    </Style>

    <Style x:Key="CardTitle" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Accent}"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
      <Setter Property="Opacity" Value="0.95"/>
    </Style>

    <Style x:Key="FieldLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Margin" Value="0,0,12,0"/>
    </Style>

    <Style x:Key="Field" TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource Bg2}"/>
      <Setter Property="Foreground" Value="{StaticResource Fg0}"/>
      <Setter Property="CaretBrush" Value="{StaticResource Accent}"/>
      <Setter Property="SelectionBrush" Value="{StaticResource Deep}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="6"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"
                    Padding="{TemplateBinding Padding}">
              <ScrollViewer x:Name="PART_ContentHost" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource Accent}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Background" Value="{StaticResource Bg3}"/>
      <Setter Property="Foreground" Value="{StaticResource Fg0}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Padding" Value="16,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="6"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.82"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.65"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.3"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="{StaticResource Deep}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Padding" Value="30,10"/>
    </Style>

    <Style x:Key="Chk" TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource Fg1}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,24,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="box" Width="17" Height="17" CornerRadius="4"
                      Background="{StaticResource Bg2}" BorderBrush="{StaticResource Bg3}" BorderThickness="1"
                      VerticalAlignment="Center">
                <Path x:Name="tick" Data="M 2,6 L 6,10 L 12,2" Stroke="#2E3440" StrokeThickness="2"
                      Visibility="Collapsed" StrokeEndLineCap="Round" StrokeStartLineCap="Round"
                      HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <ContentPresenter Margin="9,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="box" Property="Background" Value="{StaticResource Accent}"/>
                <Setter TargetName="box" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter TargetName="tick" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="DarkCombo" TargetType="ComboBox">
      <Setter Property="Foreground" Value="{StaticResource Fg0}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="ItemContainerStyle">
        <Setter.Value>
          <Style TargetType="ComboBoxItem">
            <Setter Property="Foreground" Value="{StaticResource Fg0}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Padding" Value="11,7"/>
            <Setter Property="Template">
              <Setter.Value>
                <ControlTemplate TargetType="ComboBoxItem">
                  <Border x:Name="ib" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
                    <ContentPresenter/>
                  </Border>
                  <ControlTemplate.Triggers>
                    <Trigger Property="IsHighlighted" Value="True">
                      <Setter TargetName="ib" Property="Background" Value="{StaticResource Deep}"/>
                    </Trigger>
                  </ControlTemplate.Triggers>
                </ControlTemplate>
              </Setter.Value>
            </Setter>
          </Style>
        </Setter.Value>
      </Setter>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid TextElement.Foreground="{StaticResource Fg0}">
              <ToggleButton Focusable="False" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border Background="{StaticResource Bg2}" CornerRadius="6"
                            BorderBrush="{StaticResource Line}" BorderThickness="1">
                      <Grid>
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="*"/>
                          <ColumnDefinition Width="26"/>
                        </Grid.ColumnDefinitions>
                        <Path Grid.Column="1" Data="M 0,0 L 8,0 L 4,5 Z" Fill="{StaticResource Fg1}"
                              HorizontalAlignment="Center" VerticalAlignment="Center"/>
                      </Grid>
                    </Border>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter Margin="11,0,32,0" VerticalAlignment="Center" IsHitTestVisible="False"
                                Content="{TemplateBinding SelectionBoxItem}"
                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
              <Popup x:Name="PART_Popup" Placement="Bottom" AllowsTransparency="True" Focusable="False"
                     IsOpen="{TemplateBinding IsDropDownOpen}" PopupAnimation="Fade">
                <Border Background="{StaticResource Bg2}" BorderBrush="{StaticResource Line}" BorderThickness="1"
                        CornerRadius="6" Margin="0,3,0,0" MaxHeight="260"
                        MinWidth="{TemplateBinding ActualWidth}">
                  <ScrollViewer><ItemsPresenter/></ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Implicit (no x:Key) so it also themes the log console and the combo dropdown,
         which would otherwise show bright default Windows scrollbars inside a dark UI. -->
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Width" Value="10"/>
      <Setter Property="MinWidth" Value="10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent" SnapsToDevicePixels="True">
              <Track x:Name="PART_Track" Orientation="{TemplateBinding Orientation}" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False" IsTabStop="False"/>
                </Track.DecreaseRepeatButton>
                <Track.Thumb>
                  <Thumb x:Name="th">
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border x:Name="tb" Background="{StaticResource Bg3}" CornerRadius="5" Margin="2"/>
                        <ControlTemplate.Triggers>
                          <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="tb" Property="Background" Value="{StaticResource Muted}"/>
                          </Trigger>
                          <Trigger Property="IsDragging" Value="True">
                            <Setter TargetName="tb" Property="Background" Value="{StaticResource Accent}"/>
                          </Trigger>
                        </ControlTemplate.Triggers>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False" IsTabStop="False"/>
                </Track.IncreaseRepeatButton>
              </Track>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="Orientation" Value="Horizontal">
                <Setter TargetName="PART_Track" Property="IsDirectionReversed" Value="False"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="10"/>
          <Setter Property="MinHeight" Value="10"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="Bar" TargetType="ProgressBar">
      <Setter Property="Height" Value="6"/>
      <Setter Property="Foreground" Value="{StaticResource Accent}"/>
      <Setter Property="Background" Value="{StaticResource Bg2}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid x:Name="root" ClipToBounds="True">
              <Border CornerRadius="3" Background="{TemplateBinding Background}"/>
              <Border x:Name="PART_Track"/>
              <Border x:Name="PART_Indicator" CornerRadius="3" Background="{TemplateBinding Foreground}"
                      HorizontalAlignment="Left"/>
              <Border x:Name="pulse" CornerRadius="3" Background="{TemplateBinding Foreground}"
                      Opacity="0" Visibility="Collapsed"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsIndeterminate" Value="True">
                <Setter TargetName="PART_Indicator" Property="Visibility" Value="Collapsed"/>
                <Setter TargetName="pulse" Property="Visibility" Value="Visible"/>
                <Trigger.EnterActions>
                  <BeginStoryboard x:Name="pulseSb">
                    <Storyboard RepeatBehavior="Forever">
                      <DoubleAnimation Storyboard.TargetName="pulse" Storyboard.TargetProperty="Opacity"
                                       From="0.12" To="0.85" Duration="0:0:0.9" AutoReverse="True"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <StopStoryboard BeginStoryboardName="pulseSb"/>
                </Trigger.ExitActions>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <!-- Fixed-size window: the layout is sized to fit, so only the log console scrolls. -->
  <Grid Margin="22,18,22,18">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*" MinHeight="200"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- Header -->
    <Grid Grid.Row="0" Margin="0,0,0,16">
      <StackPanel>
        <TextBlock Text="WinMedia Builder" Foreground="{StaticResource Fg0}" FontSize="24" FontWeight="Light"/>
        <TextBlock x:Name="TxtSubtitle" Foreground="{StaticResource Muted}" FontSize="12" Margin="0,3,0,0"
                   Text="Split install.wim for FAT32, rebuild a bootable ISO, and write a bootable USB stick"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
        <Border x:Name="BadgeAdmin" CornerRadius="11" Padding="11,4" Background="{StaticResource Bg2}" Margin="0,0,8,0">
          <TextBlock x:Name="TxtAdmin" FontSize="11" Foreground="{StaticResource Fg1}" Text="admin"/>
        </Border>
        <Border x:Name="BadgeAdk" CornerRadius="11" Padding="11,4" Background="{StaticResource Bg2}">
          <TextBlock x:Name="TxtAdk" FontSize="11" Foreground="{StaticResource Fg1}" Text="ADK"/>
        </Border>
      </StackPanel>
    </Grid>

    <!-- Source -->
    <Border Grid.Row="1" Style="{StaticResource Card}">
      <StackPanel>
        <TextBlock Text="SOURCE" Style="{StaticResource CardTitle}"/>
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBox x:Name="TxtSource" Grid.Column="0" Style="{StaticResource Field}"/>
          <Button x:Name="BtnBrowseSource" Grid.Column="1" Content="Browse..." Style="{StaticResource Btn}" Margin="10,0,0,0"/>
        </Grid>
        <TextBlock x:Name="TxtSourceInfo" Foreground="{StaticResource Muted}" FontSize="11" Margin="2,8,0,0"
                   Text="Windows ISO, install.wim or install.esd. The source file is opened read-only and never modified."/>
      </StackPanel>
    </Border>

    <!-- Destinations + USB -->
    <Grid Grid.Row="2">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="440"/>
      </Grid.ColumnDefinitions>

    <Border Grid.Column="0" Style="{StaticResource Card}" Margin="0,0,12,12">
      <StackPanel>
        <TextBlock Text="DESTINATIONS" Style="{StaticResource CardTitle}"/>
        <Grid Margin="0,0,0,8">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="120"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock Grid.Column="0" Text="New ISO folder" Style="{StaticResource FieldLabel}"/>
          <TextBox   x:Name="TxtOutput" Grid.Column="1" Style="{StaticResource Field}"/>
          <Button    x:Name="BtnBrowseOutput" Grid.Column="2" Content="..." Style="{StaticResource Btn}" Width="42" Margin="10,0,0,0"/>
        </Grid>
        <Grid Margin="0,0,0,8">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="120"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock Grid.Column="0" Text="Log folder" Style="{StaticResource FieldLabel}"/>
          <TextBox   x:Name="TxtLog" Grid.Column="1" Style="{StaticResource Field}"/>
          <Button    x:Name="BtnBrowseLog" Grid.Column="2" Content="..." Style="{StaticResource Btn}" Width="42" Margin="10,0,0,0"/>
        </Grid>
        <Grid Margin="0,0,0,12">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="120"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock Grid.Column="0" Text="Work folder" Style="{StaticResource FieldLabel}"/>
          <TextBox   x:Name="TxtWork" Grid.Column="1" Style="{StaticResource Field}"/>
          <Button    x:Name="BtnBrowseWork" Grid.Column="2" Content="..." Style="{StaticResource Btn}" Width="42" Margin="10,0,0,0"/>
        </Grid>

        <Border Height="1" Background="{StaticResource Line}" Margin="0,4,0,12"/>

        <StackPanel Orientation="Horizontal">
          <TextBlock Text="Max part size" Style="{StaticResource FieldLabel}"/>
          <TextBox x:Name="TxtSplitSize" Style="{StaticResource Field}" Width="70" Margin="0,0,6,0"/>
          <TextBlock Text="MB" Style="{StaticResource FieldLabel}" Margin="0,0,28,0"/>
          <CheckBox x:Name="ChkClean" Style="{StaticResource Chk}" Content="Delete work folder when done"/>
          <CheckBox x:Name="ChkHash"  Style="{StaticResource Chk}" Content="SHA256 the new ISO"/>
        </StackPanel>
      </StackPanel>
    </Border>

    <!-- USB -->
    <Border Grid.Column="1" Style="{StaticResource Card}" Margin="0,0,0,12"
            BorderBrush="#FF6B4A50" BorderThickness="1">
      <StackPanel>
        <Grid Margin="0,0,0,10">
          <TextBlock Text="USB TARGET" Style="{StaticResource CardTitle}" Margin="0"/>
          <TextBlock HorizontalAlignment="Right" FontSize="10.5" Foreground="{StaticResource Err}"
                     Text="DESTRUCTIVE - ERASES THE WHOLE DISK" FontWeight="SemiBold"/>
        </Grid>

        <Grid Margin="0,0,0,8">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <ComboBox x:Name="CmbUsb" Grid.Column="0" Style="{StaticResource DarkCombo}"/>
          <Button x:Name="BtnRefreshUsb" Grid.Column="1" Content="Refresh" Style="{StaticResource Btn}"
                  Padding="12,7" Margin="8,0,0,0"/>
        </Grid>

        <Grid Margin="0,0,0,8">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBox x:Name="TxtMedia" Grid.Column="0" Style="{StaticResource Field}"/>
          <Button  x:Name="BtnBrowseMedia" Grid.Column="1" Content="..." Style="{StaticResource Btn}" Width="42" Margin="8,0,0,0"/>
        </Grid>
        <TextBlock Foreground="{StaticResource Muted}" FontSize="10.5" Margin="2,0,0,10" TextWrapping="Wrap"
                   Text="Media to copy: a folder or an ISO. Leave blank to use the media produced by the split run."/>

        <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
          <CheckBox x:Name="ChkNtfs" Style="{StaticResource Chk}" Content="NTFS partition for leftover space"/>
        </StackPanel>

        <TextBlock x:Name="TxtUsbPlan" Foreground="{StaticResource Warn}" FontSize="10.5" TextWrapping="Wrap"
                   Margin="2,0,0,10" Text="Select a disk to see the partition plan."/>

        <Border Height="1" Background="{StaticResource Line}" Margin="0,0,0,10"/>

        <Grid>
          <CheckBox x:Name="ChkUsbAfterSplit" Style="{StaticResource Chk}" VerticalAlignment="Center"
                    Content="Also write to USB after a split"/>
          <Button x:Name="BtnPrepUsb" Content="Prepare USB now" Style="{StaticResource Btn}"
                  HorizontalAlignment="Right" Background="#FF8B4A52"/>
        </Grid>
      </StackPanel>
    </Border>

    </Grid>

    <!-- Steps + log -->
    <Grid Grid.Row="3">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="290"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <Border Grid.Column="0" Style="{StaticResource Card}" Margin="0,0,12,12">
        <StackPanel>
          <TextBlock Text="PROGRESS" Style="{StaticResource CardTitle}"/>
          <ItemsControl x:Name="StepList"/>
        </StackPanel>
      </Border>

      <Border Grid.Column="1" Style="{StaticResource Card}" Margin="0,0,0,12" Padding="14,12">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <Grid Grid.Row="0" Margin="0,0,0,8">
            <TextBlock Text="LOG" Style="{StaticResource CardTitle}" Margin="0"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
              <Button x:Name="BtnOpenLog" Content="Open log file" Style="{StaticResource Btn}" Padding="10,4" FontSize="11" Margin="0,0,6,0"/>
              <Button x:Name="BtnCopyLog" Content="Copy" Style="{StaticResource Btn}" Padding="10,4" FontSize="11"/>
            </StackPanel>
          </Grid>
          <Border Grid.Row="1" Background="#FF262B35" CornerRadius="6">
            <TextBox x:Name="TxtConsole" Background="Transparent" Foreground="{StaticResource Fg1}"
                     BorderThickness="0" IsReadOnly="True" AcceptsReturn="True" TextWrapping="NoWrap"
                     FontFamily="Cascadia Mono, Consolas, Courier New" FontSize="11.5" Padding="10"
                     VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
          </Border>
        </Grid>
      </Border>
    </Grid>

    <!-- Footer -->
    <Grid Grid.Row="4">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <Grid Grid.Row="0" Margin="0,0,0,12">
        <ProgressBar x:Name="Bar" Style="{StaticResource Bar}" Minimum="0" Maximum="100" Value="0"/>
      </Grid>

      <Grid Grid.Row="1">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock x:Name="TxtStatus" Foreground="{StaticResource Muted}" FontSize="12" VerticalAlignment="Center" Text="Ready"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Button x:Name="BtnAdk"    Content="Install Windows ADK" Style="{StaticResource Btn}" Margin="0,0,8,0"/>
          <Button x:Name="BtnOpenOut" Content="Open output folder" Style="{StaticResource Btn}" Margin="0,0,8,0"/>
          <Button x:Name="BtnCancel" Content="Cancel" Style="{StaticResource Btn}" Margin="0,0,8,0" IsEnabled="False"/>
          <Button x:Name="BtnStart"  Content="Start" Style="{StaticResource BtnPrimary}"/>
        </StackPanel>
      </Grid>
    </Grid>
  </Grid>
</Window>
'@

$reader = [System.Xml.XmlNodeReader]::new([xml]$Xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$ui = @{}
foreach ($n in 'TxtSource', 'TxtOutput', 'TxtLog', 'TxtWork', 'TxtSplitSize', 'TxtConsole', 'TxtStatus',
    'TxtSourceInfo', 'TxtAdmin', 'TxtAdk', 'BadgeAdmin', 'BadgeAdk', 'ChkClean', 'ChkHash', 'Bar', 'StepList',
    'BtnBrowseSource', 'BtnBrowseOutput', 'BtnBrowseLog', 'BtnBrowseWork', 'BtnStart', 'BtnCancel',
    'BtnAdk', 'BtnOpenOut', 'BtnOpenLog', 'BtnCopyLog',
    'CmbUsb', 'BtnRefreshUsb', 'TxtMedia', 'BtnBrowseMedia', 'ChkNtfs', 'TxtUsbPlan',
    'ChkUsbAfterSplit', 'BtnPrepUsb') {
    $ui[$n] = $window.FindName($n)
}

$brush = {
    param($hex)
    [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString($hex))
}
$C = @{
    Fg0 = & $brush '#ECEFF4'; Fg1 = & $brush '#D8DEE9'; Muted = & $brush '#8A94A6'
    Accent = & $brush '#88C0D0'; Ok = & $brush '#A3BE8C'; Warn = & $brush '#EBCB8B'
    Err = & $brush '#BF616A'; Bg2 = & $brush '#3B4252'
}

# ---- step rows ------------------------------------------------------------
# The split pipeline and the USB pipeline have different step sets, so the list is
# rebuilt per run rather than being fixed at startup.
$script:StepRows = @()

function Set-StepPlan {
    param([Parameter(Mandatory)][string[]]$Names)

    $ui.StepList.Items.Clear()
    $script:StepRows = @()

    foreach ($name in $Names) {
        $row = [Windows.Controls.Grid]::new()
        $row.Margin = '0,0,0,11'
        $c1 = [Windows.Controls.ColumnDefinition]::new(); $c1.Width = 'Auto'
        $c2 = [Windows.Controls.ColumnDefinition]::new()
        $row.ColumnDefinitions.Add($c1); $row.ColumnDefinitions.Add($c2)

        $glyph = [Windows.Controls.TextBlock]::new()
        $glyph.Text = [char]0x25CB   # hollow circle
        $glyph.FontSize = 13
        $glyph.Width = 22
        $glyph.Foreground = $C.Muted
        $glyph.VerticalAlignment = 'Center'
        [Windows.Controls.Grid]::SetColumn($glyph, 0)

        $text = [Windows.Controls.TextBlock]::new()
        $text.Text = $name
        $text.FontSize = 12.5
        $text.TextWrapping = 'Wrap'
        $text.Foreground = $C.Muted
        $text.VerticalAlignment = 'Center'
        [Windows.Controls.Grid]::SetColumn($text, 1)

        $row.Children.Add($glyph) | Out-Null
        $row.Children.Add($text) | Out-Null
        $ui.StepList.Items.Add($row) | Out-Null
        $script:StepRows += , @{ Glyph = $glyph; Text = $text; Base = $name }
    }
}

function Set-StepVisual {
    param([int]$Index, [string]$State, [string]$Detail = '')
    if ($Index -lt 0 -or $Index -ge $script:StepRows.Count) { return }
    $r = $script:StepRows[$Index]
    switch ($State) {
        'Pending' { $r.Glyph.Text = [char]0x25CB; $r.Glyph.Foreground = $C.Muted;  $r.Text.Foreground = $C.Muted }
        'Running' { $r.Glyph.Text = [char]0x25D0; $r.Glyph.Foreground = $C.Accent; $r.Text.Foreground = $C.Fg0 }
        'Done'    { $r.Glyph.Text = [char]0x2714; $r.Glyph.Foreground = $C.Ok;     $r.Text.Foreground = $C.Fg1 }
        'Failed'  { $r.Glyph.Text = [char]0x2716; $r.Glyph.Foreground = $C.Err;    $r.Text.Foreground = $C.Err }
        'Skipped' { $r.Glyph.Text = [char]0x2013; $r.Glyph.Foreground = $C.Muted;  $r.Text.Foreground = $C.Muted }
    }
    $r.Text.Text = if ($Detail) { "$($r.Base)  -  $Detail" } else { $r.Base }
}

# ---- USB disk list --------------------------------------------------------
function Update-UsbList {
    $previous = if ($ui.CmbUsb.SelectedItem) { $ui.CmbUsb.SelectedItem.Number } else { $null }
    $ui.CmbUsb.Items.Clear()

    $disks = @(Get-WimUsbDisk)
    foreach ($d in $disks) { $null = $ui.CmbUsb.Items.Add($d) }
    $ui.CmbUsb.DisplayMemberPath = 'Display'

    if ($disks.Count -eq 0) {
        $ui.TxtUsbPlan.Text = 'No removable USB disks found. Plug one in and press Refresh.'
        $ui.TxtUsbPlan.Foreground = $C.Muted
        $ui.BtnPrepUsb.IsEnabled = $false
        $ui.ChkUsbAfterSplit.IsChecked = $false
        $ui.ChkUsbAfterSplit.IsEnabled = $false
        return
    }

    $ui.BtnPrepUsb.IsEnabled = $true
    $ui.ChkUsbAfterSplit.IsEnabled = $true
    $match = $disks | Where-Object { $_.Number -eq $previous } | Select-Object -First 1
    $ui.CmbUsb.SelectedItem = if ($match) { $match } else { $disks[0] }
    Update-UsbPlan
}

function Update-UsbPlan {
    $d = $ui.CmbUsb.SelectedItem
    if (-not $d) { return }

    $totalMB = [int]([Math]::Floor($d.SizeBytes / 1MB))
    $bootMB  = [Math]::Min($script:Fat32MaxMB, $totalMB - 8)
    $restMB  = $totalMB - $bootMB - 8
    $ntfs    = [bool]$ui.ChkNtfs.IsChecked -and $restMB -gt 1024

    $plan = "Disk $($d.Number) will be WIPED. Partition 1: FAT32 $(Format-WimSize ($bootMB * 1MB)), active, bootable."
    if ($ntfs) { $plan += " Partition 2: NTFS $(Format-WimSize ($restMB * 1MB))." }
    elseif ($restMB -gt 1024) { $plan += " $(Format-WimSize ($restMB * 1MB)) will be left unallocated." }
    $ui.TxtUsbPlan.Text = $plan
    $ui.TxtUsbPlan.Foreground = $C.Warn
}

# ---- console --------------------------------------------------------------
$script:ConsoleBuffer = [System.Text.StringBuilder]::new()

function Add-ConsoleText {
    param([string]$Text)
    $null = $script:ConsoleBuffer.AppendLine($Text)
    # Keep the control light on very long runs.
    if ($script:ConsoleBuffer.Length -gt 400000) {
        $s = $script:ConsoleBuffer.ToString()
        $null = $script:ConsoleBuffer.Clear()
        $null = $script:ConsoleBuffer.Append($s.Substring($s.Length - 200000))
    }
}

# ---- shared state ---------------------------------------------------------
$sync = [hashtable]::Synchronized(@{
        Queue   = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        Cancel  = $false
        Running = $false
        Result  = $null
    })

$script:WimQueue = $sync.Queue
$script:PsInstance     = $null
$script:RunspaceRef    = $null
$script:Handle         = $null
$script:LastOutput     = ''
$script:CurrentJobKind = 'Split'
$script:WimLogPath     = $null
$script:LastMediaRoot  = ''
$script:PendingUsb     = $null

# ---- helpers --------------------------------------------------------------
function Select-FolderDialog {
    param([string]$Description, [string]$Initial)
    $dlg = [System.Windows.Forms.FolderBrowserDialog]::new()
    $dlg.Description = $Description
    $dlg.ShowNewFolderButton = $true
    if ($Initial -and (Test-Path -LiteralPath $Initial)) { $dlg.SelectedPath = $Initial }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
    return $null
}

function Set-UiBusy {
    param([bool]$Busy)
    foreach ($n in 'BtnStart', 'BtnBrowseSource', 'BtnBrowseOutput', 'BtnBrowseLog', 'BtnBrowseWork',
        'BtnAdk', 'TxtSource', 'TxtOutput', 'TxtLog', 'TxtWork', 'TxtSplitSize', 'ChkClean', 'ChkHash',
        'CmbUsb', 'BtnRefreshUsb', 'TxtMedia', 'BtnBrowseMedia', 'ChkNtfs', 'ChkUsbAfterSplit', 'BtnPrepUsb') {
        $ui[$n].IsEnabled = -not $Busy
    }
    $ui.BtnCancel.IsEnabled = $Busy
}

function Update-Badges {
    $isAdmin = Test-WimElevated
    $ui.TxtAdmin.Text = if ($isAdmin) { 'Elevated' } else { 'Not elevated' }
    $ui.TxtAdmin.Foreground = if ($isAdmin) { $C.Ok } else { $C.Warn }

    $osc = Get-WimOscdimgPath
    $ui.TxtAdk.Text = if ($osc) { 'ADK ready' } else { 'ADK missing' }
    $ui.TxtAdk.Foreground = if ($osc) { $C.Ok } else { $C.Warn }
    $ui.BtnAdk.Content = if ($osc) { 'Reinstall Windows ADK' } else { 'Install Windows ADK' }
}

function Start-WimWorker {
    <# Spins up a background runspace carrying the engine plus a small body script.
       Used for both the split pipeline and the ADK install so neither blocks the UI. #>
    param(
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][hashtable]$Variables,
        [Parameter(Mandatory)][string]$Kind
    )
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync', $sync)
    $rs.SessionStateProxy.SetVariable('logPath', $script:WimLogPath)
    $rs.SessionStateProxy.SetVariable('appName', $script:AppName)
    $rs.SessionStateProxy.SetVariable('appSlug', $script:AppSlug)
    $rs.SessionStateProxy.SetVariable('appVersion', $script:AppVersion)
    $rs.SessionStateProxy.SetVariable('adkFwLink', $script:AdkFwLink)
    $rs.SessionStateProxy.SetVariable('adkPeFwLink', $script:AdkPeFwLink)
    $rs.SessionStateProxy.SetVariable('fat32MaxMB', $script:Fat32MaxMB)
    foreach ($k in $Variables.Keys) { $rs.SessionStateProxy.SetVariable($k, $Variables[$k]) }

    $prelude = @'
$ErrorActionPreference = 'Stop'
$script:WimQueue    = $sync.Queue
$script:WimLogPath  = $logPath
$script:AppName     = $appName
$script:AppSlug     = $appSlug
$script:AppVersion  = $appVersion
$script:AdkFwLink   = $adkFwLink
$script:AdkPeFwLink = $adkPeFwLink
$script:Fat32MaxMB  = $fat32MaxMB
'@

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript($Engine.ToString() + "`n" + $prelude + "`n" + $Body)

    $script:CurrentJobKind = $Kind
    $script:PsInstance     = $ps
    $script:RunspaceRef    = $rs
    $sync.Cancel  = $false
    $sync.Running = $true
    $script:Handle = $ps.BeginInvoke()
    $timer.Start()
}

function New-WimLogFile {
    $logDir = [Environment]::ExpandEnvironmentVariables($ui.TxtLog.Text)
    $null = New-Item -ItemType Directory -Path $logDir -Force
    $script:WimLogPath = Join-Path $logDir ("{0}_{1}.log" -f $script:AppSlug, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Set-Content -LiteralPath $script:WimLogPath -Value "# $($script:AppName) $($script:AppVersion) log - $(Get-Date -Format s)" -Encoding UTF8
    $script:WimLogPath
}

# ---- settings load --------------------------------------------------------
$settings = Get-WimSettings
$ui.TxtOutput.Text    = if ($OutputRoot) { $OutputRoot } else { $settings.OutputRoot }
$ui.TxtLog.Text       = if ($LogDirectory) { $LogDirectory } else { $settings.LogDirectory }
$ui.TxtWork.Text      = if ($WorkRoot) { $WorkRoot } else { $settings.WorkRoot }
$ui.TxtSplitSize.Text = if ($PSBoundParameters.ContainsKey('SplitSizeMB')) { $SplitSizeMB } else { $settings.SplitSizeMB }
$ui.TxtSource.Text    = if ($SourcePath) { $SourcePath } else { $settings.LastSource }
$ui.ChkClean.IsChecked = [bool]$settings.CleanWorkFolder
$ui.ChkHash.IsChecked  = [bool]$settings.ComputeHash
$ui.ChkNtfs.IsChecked  = [bool]$settings.CreateNtfsRemainder
$ui.TxtMedia.Text      = ''

Update-Badges
Set-StepPlan $script:StepsSplit
Update-UsbList
Add-ConsoleText "$($script:AppName) $($script:AppVersion) ready. Select a source and press Start."
$ui.TxtConsole.Text = $script:ConsoleBuffer.ToString()

# ---- dispatcher pump ------------------------------------------------------
$timer = [Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(120)

$timer.Add_Tick({
        try {
            $appended = $false
            $msg = $null
            $drained = 0
            while ($drained -lt 400 -and $sync.Queue.TryDequeue([ref]$msg)) {
                $drained++
                switch ($msg.Kind) {
                    'Log' { Add-ConsoleText $msg.Text; $appended = $true }
                    'Step' { Set-StepVisual -Index $msg.Index -State $msg.State -Detail $msg.Detail }
                    'Progress' {
                        if ($msg.Percent -lt 0) { $ui.Bar.IsIndeterminate = $true }
                        else { $ui.Bar.IsIndeterminate = $false; $ui.Bar.Value = [Math]::Min(100, [Math]::Max(0, $msg.Percent)) }
                        if ($msg.Text) { $ui.TxtStatus.Text = $msg.Text }
                    }
                }
            }
            if ($appended) {
                $ui.TxtConsole.Text = $script:ConsoleBuffer.ToString()
                $ui.TxtConsole.ScrollToEnd()
            }

            if ($sync.Running -and $script:Handle -and $script:Handle.IsCompleted) {
                $sync.Running = $false
                $timer.Stop()

                $res = $null
                try { $res = $script:PsInstance.EndInvoke($script:Handle) } catch { }
                try { $script:PsInstance.Dispose(); $script:RunspaceRef.Close(); $script:RunspaceRef.Dispose() } catch { }
                $script:PsInstance = $null

                # Drain anything the worker queued right before finishing.
                while ($sync.Queue.TryDequeue([ref]$msg)) {
                    if ($msg.Kind -eq 'Log') { Add-ConsoleText $msg.Text }
                    elseif ($msg.Kind -eq 'Step') { Set-StepVisual -Index $msg.Index -State $msg.State -Detail $msg.Detail }
                }
                $ui.TxtConsole.Text = $script:ConsoleBuffer.ToString()
                $ui.TxtConsole.ScrollToEnd()

                Set-UiBusy $false
                $ui.Bar.IsIndeterminate = $false

                if ($script:CurrentJobKind -eq 'Adk') {
                    $ok = [bool](Get-WimOscdimgPath)
                    $ui.Bar.Value = 0
                    $ui.TxtStatus.Text = if ($ok) { 'Windows ADK ready - oscdimg.exe located.' } else { 'ADK install finished but oscdimg.exe was not found. See the log.' }
                    $ui.TxtStatus.Foreground = if ($ok) { $C.Ok } else { $C.Err }
                    Update-Badges
                    return
                }

                $all = @($res)
                $r = if ($all.Count -gt 0) { $all[-1] } else { $null }
                if ($r -and $r.Success) {
                    $ui.Bar.Value = 100
                    $ui.TxtStatus.Text = 'Completed'
                    $ui.TxtStatus.Foreground = $C.Ok
                    $script:LastOutput = $r.OutputPath
                    $mediaFromRun = if ($r.ContainsKey('MediaRoot')) { $r.MediaRoot } else { '' }
                    if ($mediaFromRun) { $script:LastMediaRoot = $mediaFromRun }

                    $pending = $script:PendingUsb
                    $script:PendingUsb = $null   # cleared unconditionally - never leaks to a later run

                    # Chain into the USB write. The wipe was confirmed before the split started,
                    # so there is no second prompt - but every reason to abort is checked here.
                    if ($script:CurrentJobKind -eq 'Split' -and $pending) {
                        if ($sync.Cancel) {
                            Add-ConsoleText 'Cancel was requested - skipping the USB write. The disk was not touched.'
                            $ui.TxtStatus.Text = 'Split finished; USB write skipped (cancelled).'
                            $ui.TxtStatus.Foreground = $C.Warn
                        }
                        elseif (-not $mediaFromRun) {
                            # e.g. the image was already under the size limit, so nothing was produced.
                            Add-ConsoleText 'The split produced no media to write - skipping the USB write. The disk was not touched.'
                            $ui.TxtStatus.Text = 'Nothing to write to USB.'
                            $ui.TxtStatus.Foreground = $C.Warn
                        }
                        else {
                            try {
                                $chain = $pending.Clone()
                                $chain.MediaPath = $mediaFromRun   # this run's output, never a cached path

                                Add-ConsoleText "Split finished. Writing $($chain.MediaPath) to disk $($chain.DiskNumber)."
                                $ui.TxtConsole.Text = $script:ConsoleBuffer.ToString()
                                $ui.TxtConsole.ScrollToEnd()

                                Set-StepPlan $script:StepsUsb
                                $ui.TxtStatus.Text = 'Preparing USB...'
                                $ui.TxtStatus.Foreground = $C.Fg1
                                $ui.Bar.Value = 0
                                Set-UiBusy $true
                                Start-WimWorker -Kind 'Usb' -Variables @{ usbJob = $chain } -Body 'Invoke-WimUsbPrep -Job $usbJob -Sync $sync'
                                return
                            }
                            catch {
                                # Do not leave the window permanently disabled if the handoff fails.
                                $sync.Running = $false
                                Set-UiBusy $false
                                Add-ConsoleText "Could not start the USB write: $($_.Exception.Message)"
                                $ui.TxtStatus.Text = 'Split completed; USB write could not be started.'
                                $ui.TxtStatus.Foreground = $C.Err
                            }
                        }
                    }

                    Update-UsbList
                    [void][System.Windows.MessageBox]::Show($r.Message, "$($script:AppName) - done",
                        'OK', 'Information')
                }
                else {
                    $ui.Bar.Value = 0
                    $msgText = if ($r) { $r.Message } else { 'The worker terminated unexpectedly. See the log.' }
                    $ui.TxtStatus.Text = "Failed: $msgText"
                    $ui.TxtStatus.Foreground = $C.Err
                    for ($i = 0; $i -lt $script:StepRows.Count; $i++) {
                        if ($script:StepRows[$i].Glyph.Text -eq [string][char]0x25D0) { Set-StepVisual -Index $i -State 'Failed' }
                    }
                    # A failed or cancelled split must not fall through into wiping a disk.
                    $script:PendingUsb = $null
                    Update-UsbList
                    [void][System.Windows.MessageBox]::Show($msgText, "$($script:AppName) - failed", 'OK', 'Error')
                }
                Update-Badges
            }
        }
        catch {
            Add-ConsoleText "UI pump error: $($_.Exception.Message)"
        }
    })

# ---- event handlers -------------------------------------------------------
$ui.BtnBrowseSource.Add_Click({
        try {
            $dlg = [System.Windows.Forms.OpenFileDialog]::new()
            $dlg.Title = 'Select a Windows ISO or image file'
            $dlg.Filter = 'Windows media (*.iso;*.wim;*.esd)|*.iso;*.wim;*.esd|ISO files (*.iso)|*.iso|Image files (*.wim;*.esd)|*.wim;*.esd|All files (*.*)|*.*'
            if ($ui.TxtSource.Text -and (Test-Path -LiteralPath $ui.TxtSource.Text)) {
                $dlg.InitialDirectory = Split-Path -Parent $ui.TxtSource.Text
            }
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $ui.TxtSource.Text = $dlg.FileName
                $f = Get-Item -LiteralPath $dlg.FileName
                $ui.TxtSourceInfo.Text = "$($f.Name)  -  $(Format-WimSize $f.Length)  -  modified $($f.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))"
            }
        }
        catch { [void][System.Windows.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') }
    })

$ui.BtnBrowseOutput.Add_Click({ $p = Select-FolderDialog 'Folder for the new ISO' $ui.TxtOutput.Text; if ($p) { $ui.TxtOutput.Text = $p } })
$ui.BtnBrowseLog.Add_Click({ $p = Select-FolderDialog 'Folder for log files' $ui.TxtLog.Text; if ($p) { $ui.TxtLog.Text = $p } })
$ui.BtnBrowseWork.Add_Click({ $p = Select-FolderDialog 'Scratch folder for extracted media' $ui.TxtWork.Text; if ($p) { $ui.TxtWork.Text = $p } })

$ui.BtnCopyLog.Add_Click({
        try { Set-Clipboard -Value $script:ConsoleBuffer.ToString() } catch { }
    })

# ---- USB ------------------------------------------------------------------
$ui.BtnRefreshUsb.Add_Click({ try { Update-UsbList } catch { Add-ConsoleText "Disk enumeration failed: $($_.Exception.Message)" } })
$ui.CmbUsb.Add_SelectionChanged({ try { Update-UsbPlan } catch { } })
$ui.ChkNtfs.Add_Click({ try { Update-UsbPlan } catch { } })

$ui.BtnBrowseMedia.Add_Click({
        try {
            $answer = [System.Windows.MessageBox]::Show(
                "Pick a FOLDER of prepared media?`n`nYes = folder`nNo = ISO file", 'Media source', 'YesNoCancel', 'Question')
            if ($answer -eq 'Cancel') { return }
            if ($answer -eq 'Yes') {
                $p = Select-FolderDialog 'Folder containing the prepared Windows media' $ui.TxtMedia.Text
                if ($p) { $ui.TxtMedia.Text = $p }
            }
            else {
                $dlg = [System.Windows.Forms.OpenFileDialog]::new()
                $dlg.Title = 'Select the ISO to write to the USB'
                $dlg.Filter = 'ISO files (*.iso)|*.iso|All files (*.*)|*.*'
                if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $ui.TxtMedia.Text = $dlg.FileName }
            }
        }
        catch { [void][System.Windows.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') }
    })

function Confirm-UsbWipe {
    <# Two-stage confirmation. This wipes a whole disk; one careless click is not enough. #>
    param([Parameter(Mandatory)]$Disk)

    $first = [System.Windows.MessageBox]::Show(
        "About to ERASE this disk completely:`n`n  $($Disk.Display)`n`n" +
        "Every partition and all data on it will be destroyed and cannot be recovered.`n`n" +
        "$($ui.TxtUsbPlan.Text)`n`nContinue?",
        'Confirm disk erase', 'YesNo', 'Warning')
    if ($first -ne 'Yes') { return $false }

    $second = [System.Windows.MessageBox]::Show(
        "Final check.`n`nDisk $($Disk.Number) - $($Disk.FriendlyName) - $($Disk.SizeText)$(if ($Disk.Letters) { "`nCurrently mounted as: $($Disk.Letters)" })`n`n" +
        'Is this the correct disk? Choosing Yes starts diskpart immediately.',
        'Last chance', 'YesNo', 'Warning')
    return ($second -eq 'Yes')
}

$ui.BtnPrepUsb.Add_Click({
        try {
            if ($sync.Running) { return }
            if (-not (Test-WimElevated)) {
                [void][System.Windows.MessageBox]::Show('Partitioning a disk requires administrator rights. Restart this script elevated.', 'Not elevated', 'OK', 'Warning')
                return
            }

            $disk = $ui.CmbUsb.SelectedItem
            if (-not $disk) {
                [void][System.Windows.MessageBox]::Show('Select a USB disk first.', 'No target', 'OK', 'Warning')
                return
            }

            $media = $ui.TxtMedia.Text.Trim('"', ' ')
            if (-not $media) { $media = $script:LastMediaRoot }
            if (-not $media -or -not (Test-Path -LiteralPath $media)) {
                [void][System.Windows.MessageBox]::Show(
                    "Select the media to copy - a folder of prepared Windows files, or an ISO.`n`nRun a split first if you have not already; its output folder is used automatically.",
                    'No media', 'OK', 'Warning')
                return
            }

            if (-not (Confirm-UsbWipe -Disk $disk)) { return }

            Save-WimSettings ([ordered]@{
                    WorkRoot            = $ui.TxtWork.Text
                    OutputRoot          = $ui.TxtOutput.Text
                    LogDirectory        = $ui.TxtLog.Text
                    SplitSizeMB         = $ui.TxtSplitSize.Text
                    CleanWorkFolder     = [bool]$ui.ChkClean.IsChecked
                    ComputeHash         = [bool]$ui.ChkHash.IsChecked
                    LastSource          = $ui.TxtSource.Text
                    CreateNtfsRemainder = [bool]$ui.ChkNtfs.IsChecked
                })

            $null = New-WimLogFile
            $null = $script:ConsoleBuffer.Clear()
            Add-ConsoleText "Log file: $($script:WimLogPath)"
            $ui.TxtConsole.Text = $script:ConsoleBuffer.ToString()

            Set-StepPlan $script:StepsUsb
            $ui.TxtStatus.Foreground = $C.Fg1
            $ui.TxtStatus.Text = 'Preparing USB...'
            $ui.Bar.Value = 0
            Set-UiBusy $true

            $usbJob = @{
                DiskNumber          = $disk.Number
                ExpectName          = $disk.FriendlyName
                ExpectSerial        = $disk.SerialNumber
                ExpectSize          = [long]$disk.SizeBytes
                MediaPath           = $media
                CreateNtfsRemainder = [bool]$ui.ChkNtfs.IsChecked
                BootLabel           = 'WINSETUP'
                DataLabel           = 'DATA'
            }

            Start-WimWorker -Kind 'Usb' -Variables @{ usbJob = $usbJob } -Body 'Invoke-WimUsbPrep -Job $usbJob -Sync $sync'
        }
        catch {
            $sync.Running = $false
            Set-UiBusy $false
            [void][System.Windows.MessageBox]::Show("Could not start: $($_.Exception.Message)", 'Error', 'OK', 'Error')
        }
    })

$ui.BtnOpenLog.Add_Click({
        if ($script:WimLogPath -and (Test-Path -LiteralPath $script:WimLogPath)) { Start-Process notepad.exe $script:WimLogPath }
        elseif (Test-Path -LiteralPath $ui.TxtLog.Text) { Start-Process explorer.exe $ui.TxtLog.Text }
    })

$ui.BtnOpenOut.Add_Click({
        $target = if ($script:LastOutput -and (Test-Path -LiteralPath $script:LastOutput)) {
            if ((Get-Item -LiteralPath $script:LastOutput).PSIsContainer) { $script:LastOutput }
            else { "/select,`"$script:LastOutput`"" }
        }
        elseif (Test-Path -LiteralPath $ui.TxtOutput.Text) { $ui.TxtOutput.Text }
        else { $null }
        if ($target) { Start-Process explorer.exe $target }
    })

$ui.BtnCancel.Add_Click({
        $sync.Cancel = $true
        $ui.BtnCancel.IsEnabled = $false
        $ui.TxtStatus.Text = 'Cancelling - waiting for the current tool to stop...'
        $ui.TxtStatus.Foreground = $C.Warn
    })

$ui.BtnAdk.Add_Click({
        try {
            if ($sync.Running) { return }
            if (-not (Test-WimElevated)) {
                [void][System.Windows.MessageBox]::Show('Installing the Windows ADK requires administrator rights. Restart this script elevated.', 'Not elevated', 'OK', 'Warning')
                return
            }
            $answer = [System.Windows.MessageBox]::Show(
                "Install the Windows ADK Deployment Tools?`n`nwinget is used when available, otherwise the pinned Microsoft installers are downloaded. This can take several minutes.`n`n$($script:AdkDocsUrl)",
                'Install Windows ADK', 'YesNo', 'Question')
            if ($answer -ne 'Yes') { return }

            $null = New-WimLogFile
            $null = $script:ConsoleBuffer.Clear()
            Add-ConsoleText "Log file: $($script:WimLogPath)"
            $ui.TxtConsole.Text = $script:ConsoleBuffer.ToString()

            Set-UiBusy $true
            $ui.Bar.IsIndeterminate = $true
            $ui.TxtStatus.Text = 'Installing Windows ADK...'
            $ui.TxtStatus.Foreground = $C.Fg1

            Start-WimWorker -Kind 'Adk' -Variables @{} -Body 'Install-WimAdk -Sync $sync | Out-Null'
        }
        catch {
            $sync.Running = $false
            Set-UiBusy $false
            $ui.Bar.IsIndeterminate = $false
            [void][System.Windows.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error')
        }
    })

$ui.BtnStart.Add_Click({
        try {
            if ($sync.Running) { return }

            $src = $ui.TxtSource.Text.Trim('"', ' ')
            if (-not $src -or -not (Test-Path -LiteralPath $src -PathType Leaf)) {
                [void][System.Windows.MessageBox]::Show('Select a valid ISO, WIM or ESD file first.', 'No source', 'OK', 'Warning')
                return
            }
            $sizeMB = 0
            if (-not [int]::TryParse($ui.TxtSplitSize.Text, [ref]$sizeMB) -or $sizeMB -lt 100 -or $sizeMB -gt 32000) {
                [void][System.Windows.MessageBox]::Show('Max part size must be a number between 100 and 32000 MB. 4000 is the safe FAT32 value.', 'Invalid size', 'OK', 'Warning')
                return
            }

            # If the run is going to end by wiping a disk, confirm that now rather than
            # springing a destructive prompt on the user 20 minutes later.
            $script:PendingUsb = $null
            if ($ui.ChkUsbAfterSplit.IsChecked) {
                if (-not (Test-WimElevated)) {
                    [void][System.Windows.MessageBox]::Show('Writing to USB requires administrator rights. Restart elevated or clear the USB option.', 'Not elevated', 'OK', 'Warning')
                    return
                }
                $disk = $ui.CmbUsb.SelectedItem
                if (-not $disk) {
                    [void][System.Windows.MessageBox]::Show('Select a USB disk, or clear "Also write to USB after a split".', 'No USB target', 'OK', 'Warning')
                    return
                }
                if (-not (Confirm-UsbWipe -Disk $disk)) { return }
                # Identity is captured at confirm time and re-verified before the wipe - the
                # split can take 30+ minutes, and disk numbers get recycled when sticks are swapped.
                $script:PendingUsb = @{
                    DiskNumber          = $disk.Number
                    ExpectName          = $disk.FriendlyName
                    ExpectSerial        = $disk.SerialNumber
                    ExpectSize          = [long]$disk.SizeBytes
                    MediaPath           = ''       # filled in from the split result
                    CreateNtfsRemainder = [bool]$ui.ChkNtfs.IsChecked
                    BootLabel           = 'WINSETUP'
                    DataLabel           = 'DATA'
                }
            }

            # Persist choices for next launch.
            Save-WimSettings ([ordered]@{
                    WorkRoot            = $ui.TxtWork.Text
                    OutputRoot          = $ui.TxtOutput.Text
                    LogDirectory        = $ui.TxtLog.Text
                    SplitSizeMB         = $sizeMB
                    CleanWorkFolder     = [bool]$ui.ChkClean.IsChecked
                    ComputeHash         = [bool]$ui.ChkHash.IsChecked
                    LastSource          = $src
                    CreateNtfsRemainder = [bool]$ui.ChkNtfs.IsChecked
                })

            $null = New-WimLogFile
            $null = $script:ConsoleBuffer.Clear()
            Add-ConsoleText "Log file: $($script:WimLogPath)"
            $ui.TxtConsole.Text = $script:ConsoleBuffer.ToString()

            $plan = @($script:StepsSplit)
            if ($script:PendingUsb) { $plan += 'Write to USB' }
            Set-StepPlan $plan

            $ui.TxtStatus.Foreground = $C.Fg1
            $ui.TxtStatus.Text = 'Starting...'
            $ui.Bar.Value = 0
            Set-UiBusy $true

            $job = @{
                SourcePath      = $src
                WorkRoot        = $ui.TxtWork.Text
                OutputRoot      = $ui.TxtOutput.Text
                SplitSizeMB     = $sizeMB
                CleanWorkFolder = [bool]$ui.ChkClean.IsChecked
                ComputeHash     = [bool]$ui.ChkHash.IsChecked
                KeepMediaForUsb = [bool]$script:PendingUsb
            }

            Start-WimWorker -Kind 'Split' -Variables @{ job = $job } -Body 'Invoke-WimSplitJob -Job $job -Sync $sync'
        }
        catch {
            $sync.Running = $false
            Set-UiBusy $false
            [void][System.Windows.MessageBox]::Show("Could not start: $($_.Exception.Message)", 'Error', 'OK', 'Error')
        }
    })

$window.Add_Closing({
        param($eventSender, $e)
        if ($sync.Running) {
            $a = [System.Windows.MessageBox]::Show('A run is in progress. Cancel it and close?', 'Still running', 'YesNo', 'Warning')
            if ($a -ne 'Yes') { $e.Cancel = $true; return }
            $sync.Cancel = $true
        }
        try { $timer.Stop() } catch { }
        try { if ($script:PsInstance) { $script:PsInstance.Stop(); $script:PsInstance.Dispose() } } catch { }
        try { if ($script:RunspaceRef) { $script:RunspaceRef.Close(); $script:RunspaceRef.Dispose() } } catch { }
    })

# Warn once, up front, rather than failing three minutes into a run.
if (-not (Test-WimElevated)) {
    Add-ConsoleText 'WARNING: not running elevated. Mounting an ISO requires administrator rights.'
    $ui.TxtConsole.Text = $script:ConsoleBuffer.ToString()
}

$null = $window.ShowDialog()

#endregion
