$ErrorActionPreference = "Stop"

Add-Type -AssemblyName Microsoft.VisualBasic

# ==========================================================
# 摄影镜像同步 V3.3
# ==========================================================

$SourceRoot = "G:\摄影"
$BackupRoot = "I:\备份\摄影"
$DriveMarker = "I:\PHOTO_BACKUP.ID"

$ManifestPath = Join-Path $SourceRoot "manifest.json"
$ManifestTemp = Join-Path $SourceRoot "manifest.json.tmp"
$ManifestBackup = Join-Path $SourceRoot "manifest.json.bak"

$ExcludedNames = @(
    "摄影手动同步.bat",
    "摄影同步核心.ps1",
    "manifest.json",
    "manifest.json.tmp",
    "manifest.json.bak"
)

$StartedAt = Get-Date
$Phase = "初始化"

$SourceScan = $null
$BackupBefore = $null
$BackupAfter = $null
$BackupFinal = $null

$CopyVerified = $false
$ManifestSaved = $false
$IdentityBaseline = $false

$CopyExitCode = 0

$Counts = @{
    SourceNewFiles = 0
    SourceNewDirs = 0
    SourceModifiedFiles = 0

    SourceRenamedFiles = 0
    SourceRenamedDirs = 0
    SourceMovedFiles = 0
    SourceMovedDirs = 0

    SourceDeletedFiles = 0
    SourceDeletedDirs = 0

    BackupNewFiles = 0
    BackupNewDirs = 0
    BackupModifiedFiles = 0

    BackupRenamedFiles = 0
    BackupRenamedDirs = 0
    BackupMovedFiles = 0
    BackupMovedDirs = 0

    BackupRecycledFiles = 0
    BackupRecycledDirs = 0

    BackupFailedFiles = 0
    BackupFailedDirs = 0
}

$PendingFiles = @{}
$PendingDirs = @{}

$FolderPlans = New-Object System.Collections.ArrayList
$FilePlans = New-Object System.Collections.ArrayList

$AppliedFolderMoves = New-Object System.Collections.ArrayList
$AppliedFileMoves = New-Object System.Collections.ArrayList

$OperationErrors = New-Object 'System.Collections.Generic.List[string]'


# ==========================================================
# 1. NTFS 文件 ID
# ==========================================================

$NativeCode = @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class PhotoBackupIdentityV33
{
    [StructLayout(LayoutKind.Sequential)]
    private struct FileTime
    {
        public uint Low;
        public uint High;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileInformation
    {
        public uint Attributes;
        public FileTime CreationTime;
        public FileTime AccessTime;
        public FileTime WriteTime;
        public uint VolumeSerial;
        public uint SizeHigh;
        public uint SizeLow;
        public uint LinkCount;
        public uint IndexHigh;
        public uint IndexLow;
    }

    [DllImport(
        "kernel32.dll",
        EntryPoint = "CreateFileW",
        CharSet = CharSet.Unicode,
        SetLastError = true
    )]
    private static extern SafeFileHandle CreateFile(
        string path,
        uint access,
        uint share,
        IntPtr security,
        uint disposition,
        uint flags,
        IntPtr templateFile
    );

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(
        SafeFileHandle handle,
        out FileInformation information
    );

    public static string GetId(string path)
    {
        const uint READ_ATTRIBUTES = 0x80;
        const uint SHARE_ALL = 0x07;
        const uint OPEN_EXISTING = 3;
        const uint BACKUP_SEMANTICS = 0x02000000;

        using (SafeFileHandle handle = CreateFile(
            path,
            READ_ATTRIBUTES,
            SHARE_ALL,
            IntPtr.Zero,
            OPEN_EXISTING,
            BACKUP_SEMANTICS,
            IntPtr.Zero
        ))
        {
            if (handle.IsInvalid)
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error()
                );
            }

            FileInformation info;

            if (!GetFileInformationByHandle(handle, out info))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error()
                );
            }

            return String.Format(
                "{0:X8}:{1:X8}{2:X8}",
                info.VolumeSerial,
                info.IndexHigh,
                info.IndexLow
            );
        }
    }
}
"@

Add-Type -TypeDefinition $NativeCode -ErrorAction Stop


# ==========================================================
# 2. 通用函数
# ==========================================================

function Show-Count {
    param(
        [string]$Label,
        [int]$Value,
        [string]$Color = "Green"
    )

    if ($Value -gt 0) {
        Write-Host "${Label}：$Value" -ForegroundColor $Color
    }
}

function Test-ExactPath {
    param(
        [string]$Left,
        [string]$Right
    )

    return [string]::Equals(
        $Left,
        $Right,
        [StringComparison]::Ordinal
    )
}

function Test-WithinPath {
    param(
        [string]$Path,
        [string]$Parent
    )

    return (
        [string]::Equals(
            $Path,
            $Parent,
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        $Path.StartsWith(
            $Parent + "\",
            [StringComparison]::OrdinalIgnoreCase
        )
    )
}

function Assert-RelativePath {
    param([string]$Relative)

    if (
        [string]::IsNullOrWhiteSpace($Relative) -or
        [IO.Path]::IsPathRooted($Relative) -or
        $Relative.StartsWith("\") -or
        $Relative.EndsWith("\") -or
        $Relative -match '[<>:"/|?*]' -or
        $Relative -match '[\x00-\x1F]' -or
        $Relative -match '(^|\\)\.\.?($|\\)'
    ) {
        throw "发现不安全的相对路径：$Relative"
    }
}

function Assert-ManagedPath {
    param([string]$Relative)

    Assert-RelativePath $Relative

    if ($Relative -in $ExcludedNames) {
        throw "同步管理文件不能参与备份操作：$Relative"
    }
}

function Assert-NoReparsePoint {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $Item = Get-Item -LiteralPath $Path -Force

    if (
        $Item.Attributes -band
        [IO.FileAttributes]::ReparsePoint
    ) {
        throw "发现链接或目录联接，已停止：$Path"
    }
}

function Assert-BackupPath {
    param([string]$Relative)

    Assert-ManagedPath $Relative

    foreach ($Path in @("I:\", "I:\备份", $BackupRoot)) {
        Assert-NoReparsePoint $Path
    }

    $Current = $BackupRoot

    foreach ($Part in $Relative.Split("\")) {
        $Current = Join-Path $Current $Part
        Assert-NoReparsePoint $Current
    }
}

function Get-Identity {
    param($Entry)

    if (
        [string]::IsNullOrWhiteSpace([string]$Entry.Id) -or
        [string]::IsNullOrWhiteSpace([string]$Entry.Created)
    ) {
        throw "文件身份信息不完整：$($Entry.Path)"
    }

    return "$($Entry.Id)|$($Entry.Created)"
}

function Get-Depth {
    param([string]$Relative)

    return ($Relative -split "\\").Count
}


# ==========================================================
# 3. 扫描文件和文件夹
# ==========================================================

function Get-DirectorySnapshot {
    param(
        [string]$Root,
        [switch]$WithIdentity,
        [switch]$IsSource
    )

    $Files = @{}
    $Directories = @{}

    $RootItem = Get-Item -LiteralPath $Root -ErrorAction Stop

    Assert-NoReparsePoint $Root

    $RootFullPath = $RootItem.FullName.TrimEnd("\")

    $Stack = New-Object 'System.Collections.Generic.Stack[string]'
    $Stack.Push($RootFullPath)

    while ($Stack.Count -gt 0) {

        $CurrentDirectory = $Stack.Pop()

        $Items = Get-ChildItem `
            -LiteralPath $CurrentDirectory `
            -Force `
            -ErrorAction Stop

        foreach ($Item in $Items) {

            if (
                $Item.Attributes -band
                [IO.FileAttributes]::ReparsePoint
            ) {
                throw "检测到链接项目，请先检查：$($Item.FullName)"
            }

            $Relative = $Item.FullName.Substring(
                $RootFullPath.Length
            ).TrimStart("\")

            Assert-RelativePath $Relative

            if (
                $IsSource -and
                -not $Item.PSIsContainer -and
                $Relative -in $ExcludedNames
            ) {
                continue
            }

            $Identity = ""

            if ($WithIdentity) {

                try {
                    $Identity = [PhotoBackupIdentityV33]::GetId(
                        $Item.FullName
                    )
                }
                catch {
                    throw "无法读取文件ID：$Relative；$($_.Exception.Message)"
                }
            }

            $Entry = [pscustomobject]@{
                Path = $Relative
                Id = $Identity
                Created = [string]$Item.CreationTimeUtc.Ticks
                Size = $(if ($Item.PSIsContainer) {
                    [long]0
                } else {
                    [long]$Item.Length
                })
                Modified = [string]$Item.LastWriteTimeUtc.Ticks
            }

            if ($Item.PSIsContainer) {

                $Directories[$Relative] = $Entry
                $Stack.Push($Item.FullName)
            }
            else {

                $Files[$Relative] = $Entry
            }
        }
    }

    return @{
        Files = $Files
        Directories = $Directories
    }
}

function New-IdentityIndex {
    param([hashtable]$Items)

    $Index = @{}

    foreach ($Entry in $Items.Values) {

        $Key = Get-Identity $Entry

        if ($Index.ContainsKey($Key)) {
            throw "存在重复文件ID，无法安全识别重命名：$($Entry.Path)"
        }

        $Index[$Key] = $Entry
    }

    return $Index
}

function Test-SnapshotUnchanged {
    param(
        [hashtable]$Before,
        [hashtable]$After
    )

    if (
        $Before.Files.Count -ne $After.Files.Count -or
        $Before.Directories.Count -ne $After.Directories.Count
    ) {
        return $false
    }

    foreach ($Path in $Before.Files.Keys) {

        if (-not $After.Files.ContainsKey($Path)) {
            return $false
        }

        $OldFile = $Before.Files[$Path]
        $NewFile = $After.Files[$Path]

        if (
            $OldFile.Id -ne $NewFile.Id -or
            $OldFile.Created -ne $NewFile.Created -or
            $OldFile.Size -ne $NewFile.Size -or
            $OldFile.Modified -ne $NewFile.Modified
        ) {
            return $false
        }
    }

    foreach ($Path in $Before.Directories.Keys) {

        if (-not $After.Directories.ContainsKey($Path)) {
            return $false
        }

        $OldDir = $Before.Directories[$Path]
        $NewDir = $After.Directories[$Path]

        if (
            $OldDir.Id -ne $NewDir.Id -or
            $OldDir.Created -ne $NewDir.Created
        ) {
            return $false
        }
    }

    return $true
}


# ==========================================================
# 4. 路径变化处理
# ==========================================================

function Convert-ByPlans {
    param(
        [string]$Relative,
        [System.Collections.IEnumerable]$Plans,
        [switch]$ExactOnly
    )

    $Result = $Relative

    foreach ($Plan in $Plans) {

        $OldPath = [string]$Plan.From
        $NewPath = [string]$Plan.To

        if (
            [string]::Equals(
                $Result,
                $OldPath,
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            $Result = $NewPath
        }
        elseif (
            -not $ExactOnly -and
            $Result.StartsWith(
                $OldPath + "\",
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            $Result = $NewPath + $Result.Substring($OldPath.Length)
        }
    }

    return $Result
}

function Get-ChangeKind {
    param(
        [string]$From,
        [string]$To
    )

    $OldParent = Split-Path -Path $From -Parent
    $NewParent = Split-Path -Path $To -Parent

    if ($OldParent -ieq $NewParent) {
        return "Rename"
    }

    return "Move"
}

function Move-BackupEntry {
    param(
        [string]$From,
        [string]$To
    )

    Assert-BackupPath $From
    Assert-BackupPath $To

    $OldFullPath = Join-Path $BackupRoot $From
    $NewFullPath = Join-Path $BackupRoot $To

    if (Test-ExactPath $From $To) {
        return "unchanged"
    }

    if ($From -ieq $To) {
        throw "暂不支持仅大小写变化的重命名：$From"
    }

    $OldExists = Test-Path -LiteralPath $OldFullPath
    $NewExists = Test-Path -LiteralPath $NewFullPath

    if ($OldExists -and $NewExists) {
        throw "备份目标已存在，禁止覆盖：$To"
    }

    if (-not $OldExists) {

        if ($NewExists) {
            return "already"
        }

        return "missing"
    }

    $Parent = Split-Path -Path $NewFullPath -Parent

    if (-not (Test-Path -LiteralPath $Parent)) {

        New-Item `
            -ItemType Directory `
            -Path $Parent `
            -Force `
            -ErrorAction Stop |
            Out-Null
    }

    Move-Item `
        -LiteralPath $OldFullPath `
        -Destination $NewFullPath `
        -ErrorAction Stop

    return "moved"
}


# ==========================================================
# 5. 操作前检查路径冲突
# ==========================================================

function Assert-MovePlansSafe {

    $VirtualFiles = @{}
    $VirtualDirs = @{}

    foreach ($Path in $BackupBefore.Files.Keys) {
        $VirtualFiles[$Path] = $true
    }

    foreach ($Path in $BackupBefore.Directories.Keys) {
        $VirtualDirs[$Path] = $true
    }

    foreach ($Plan in $FolderPlans) {

        $From = [string]$Plan.From
        $To = [string]$Plan.To

        Assert-BackupPath $From
        Assert-BackupPath $To

        if ($From -ieq $To) {
            throw "暂不支持仅大小写变化的文件夹重命名：$From"
        }

        if (Test-WithinPath $To $From) {
            throw "不允许把文件夹移动到自身内部：$From -> $To"
        }

        if (-not $VirtualDirs.ContainsKey($From)) {
            continue
        }

        if (
            $VirtualDirs.ContainsKey($To) -or
            $VirtualFiles.ContainsKey($To)
        ) {
            throw "备份文件夹目标已存在：$To"
        }

        $AffectedDirs = @(
            $VirtualDirs.Keys |
            Where-Object { Test-WithinPath $_ $From }
        )

        $AffectedFiles = @(
            $VirtualFiles.Keys |
            Where-Object { Test-WithinPath $_ $From }
        )

        foreach ($Path in $AffectedDirs) {
            [void]$VirtualDirs.Remove($Path)
        }

        foreach ($Path in $AffectedFiles) {
            [void]$VirtualFiles.Remove($Path)
        }

        foreach ($Path in $AffectedDirs) {

            $Mapped = $To + $Path.Substring($From.Length)

            if (
                $VirtualDirs.ContainsKey($Mapped) -or
                $VirtualFiles.ContainsKey($Mapped)
            ) {
                throw "文件夹移动后出现目录冲突：$Mapped"
            }

            $VirtualDirs[$Mapped] = $true
        }

        foreach ($Path in $AffectedFiles) {

            $Mapped = $To + $Path.Substring($From.Length)

            if (
                $VirtualFiles.ContainsKey($Mapped) -or
                $VirtualDirs.ContainsKey($Mapped)
            ) {
                throw "文件夹移动后出现文件冲突：$Mapped"
            }

            $VirtualFiles[$Mapped] = $true
        }
    }

    foreach ($Plan in $FilePlans) {

        $From = [string]$Plan.From
        $To = [string]$Plan.To

        Assert-BackupPath $From
        Assert-BackupPath $To

        if ($From -ieq $To) {
            throw "暂不支持仅大小写变化的文件重命名：$From"
        }

        if (-not $VirtualFiles.ContainsKey($From)) {
            continue
        }

        if (
            $VirtualFiles.ContainsKey($To) -or
            $VirtualDirs.ContainsKey($To)
        ) {
            throw "备份文件目标已存在：$To"
        }

        [void]$VirtualFiles.Remove($From)
        $VirtualFiles[$To] = $true
    }

    foreach ($Path in $SourceScan.Files.Keys) {

        if ($VirtualDirs.ContainsKey($Path)) {
            throw "备份中同名位置是文件夹，不能写入文件：$Path"
        }
    }

    foreach ($Path in $SourceScan.Directories.Keys) {

        if ($VirtualFiles.ContainsKey($Path)) {
            throw "备份中同名位置是文件，不能创建文件夹：$Path"
        }
    }

    # 检查每一级目标父目录不能是普通文件
    $DesiredPaths = @(
        @($SourceScan.Files.Keys) +
        @($SourceScan.Directories.Keys) +
        @($FolderPlans | ForEach-Object { $_.To }) +
        @($FilePlans | ForEach-Object { $_.To })
    )

    foreach ($Path in $DesiredPaths) {

        $Parts = $Path.Split("\")
        $Parent = ""

        for ($Index = 0; $Index -lt $Parts.Count - 1; $Index++) {

            if ($Parent.Length -eq 0) {
                $Parent = $Parts[$Index]
            }
            else {
                $Parent += "\" + $Parts[$Index]
            }

            if ($VirtualFiles.ContainsKey($Parent)) {
                throw "目标父路径被文件占用：$Parent"
            }
        }
    }
}


# ==========================================================
# 6. 保存同步记录
# ==========================================================

function Save-SyncManifest {
    param(
        [hashtable]$Snapshot,
        [string]$RootIdentity
    )

    $FileRecords = @(
        $Snapshot.Files.Values |
        Sort-Object Path |
        ForEach-Object {
            [ordered]@{
                Id = $_.Id
                Created = $_.Created
                Path = $_.Path
                Size = $_.Size
                Modified = $_.Modified
            }
        }
    )

    $DirRecords = @(
        $Snapshot.Directories.Values |
        Sort-Object Path |
        ForEach-Object {
            [ordered]@{
                Id = $_.Id
                Created = $_.Created
                Path = $_.Path
            }
        }
    )

    $Data = [ordered]@{
        Version = 3
        UpdatedAt = (Get-Date).ToString("o")
        SourceRootId = $RootIdentity
        Files = $FileRecords
        Directories = $DirRecords
        PendingFiles = @($PendingFiles.Keys | Sort-Object)
        PendingDirectories = @($PendingDirs.Keys | Sort-Object)
    }

    $Json = ConvertTo-Json -InputObject $Data -Depth 8

    [IO.File]::WriteAllText(
        $ManifestTemp,
        $Json,
        (New-Object System.Text.UTF8Encoding($false))
    )

    if (Test-Path -LiteralPath $ManifestPath -PathType Leaf) {

        [IO.File]::Replace(
            $ManifestTemp,
            $ManifestPath,
            $ManifestBackup
        )
    }
    else {

        [IO.File]::Move(
            $ManifestTemp,
            $ManifestPath
        )
    }
}


# ==========================================================
# 7. 显示同步结果
# ==========================================================

function Show-SyncResult {
    param(
        [string]$Status,
        [string[]]$Reasons
    )

    $Elapsed = (Get-Date) - $StartedAt

    $SourceColor = if ($CopyVerified) {
        "Green"
    } else {
        "Red"
    }

    $DeleteColor = "Green"

    if (
        $Counts.BackupFailedFiles -gt 0 -or
        $Counts.BackupFailedDirs -gt 0
    ) {
        $DeleteColor = "Red"
    }
    elseif (
        $PendingFiles.Count -gt 0 -or
        $PendingDirs.Count -gt 0
    ) {
        $DeleteColor = "Yellow"
    }

    Write-Host ""
    Write-Host "========================================"
    Write-Host "           镜像同步结果 V3.3"
    Write-Host "========================================"
    Write-Host ""

    Write-Host "源目录：$SourceRoot"
    Write-Host "备份目录：$BackupRoot"
    Write-Host ""

    if ($null -ne $SourceScan) {
        Write-Host "源目录文件数量：$($SourceScan.Files.Count)"
        Write-Host "源目录文件夹数量：$($SourceScan.Directories.Count)"
    }

    $ShownBackup = $BackupFinal

    if ($null -eq $ShownBackup) {
        $ShownBackup = $BackupAfter
    }

    if ($null -eq $ShownBackup) {
        $ShownBackup = $BackupBefore
    }

    if ($null -ne $ShownBackup) {
        Write-Host ""
        Write-Host "备份目录文件数量：$($ShownBackup.Files.Count)"
        Write-Host "备份目录文件夹数量：$($ShownBackup.Directories.Count)"
    }

    Write-Host ""

    # 源目录变化统计
    Show-Count "源目录检测到新增文件" `
        $Counts.SourceNewFiles $SourceColor

    Show-Count "源目录检测到新增文件夹" `
        $Counts.SourceNewDirs $SourceColor

    Show-Count "源目录检测到修改文件" `
        $Counts.SourceModifiedFiles $SourceColor

    Show-Count "源目录检测到重命名文件" `
        $Counts.SourceRenamedFiles $SourceColor

    Show-Count "源目录检测到重命名文件夹" `
        $Counts.SourceRenamedDirs $SourceColor

    Show-Count "源目录检测到移动文件" `
        $Counts.SourceMovedFiles $SourceColor

    Show-Count "源目录检测到移动文件夹" `
        $Counts.SourceMovedDirs $SourceColor

    Show-Count "源目录检测到删除文件" `
        $Counts.SourceDeletedFiles $DeleteColor

    Show-Count "源目录检测到删除文件夹" `
        $Counts.SourceDeletedDirs $DeleteColor

    # 备份实际完成的操作
    $HasBackupResults = (
        $Counts.BackupNewFiles -gt 0 -or
        $Counts.BackupNewDirs -gt 0 -or
        $Counts.BackupModifiedFiles -gt 0 -or
        $Counts.BackupRenamedFiles -gt 0 -or
        $Counts.BackupRenamedDirs -gt 0 -or
        $Counts.BackupMovedFiles -gt 0 -or
        $Counts.BackupMovedDirs -gt 0 -or
        $Counts.BackupRecycledFiles -gt 0 -or
        $Counts.BackupRecycledDirs -gt 0
    )

    if ($HasBackupResults) {
        Write-Host ""
    }

    Show-Count "备份新增文件" $Counts.BackupNewFiles "Green"
    Show-Count "备份新增文件夹" $Counts.BackupNewDirs "Green"
    Show-Count "备份修改文件" $Counts.BackupModifiedFiles "Green"

    Show-Count "备份重命名文件" $Counts.BackupRenamedFiles "Green"
    Show-Count "备份重命名文件夹" $Counts.BackupRenamedDirs "Green"

    Show-Count "备份移动文件" $Counts.BackupMovedFiles "Green"
    Show-Count "备份移动文件夹" $Counts.BackupMovedDirs "Green"

    Show-Count "备份文件移入回收站" $Counts.BackupRecycledFiles "Green"
    Show-Count "备份文件夹移入回收站" $Counts.BackupRecycledDirs "Green"

    # 待完成统计
    if ($PendingFiles.Count -gt 0 -or $PendingDirs.Count -gt 0) {
        Write-Host ""
    }

    Show-Count "备份待处理删除文件" $PendingFiles.Count "Yellow"
    Show-Count "备份待处理删除文件夹" $PendingDirs.Count "Yellow"

    # 失败统计
    Show-Count "备份删除失败文件" $Counts.BackupFailedFiles "Red"
    Show-Count "备份删除失败文件夹" $Counts.BackupFailedDirs "Red"

    Write-Host ""

    if ($Status -eq "已完成") {
        Write-Host "镜像同步状态：已完成" -ForegroundColor Green
    }
    elseif ($Status -eq "待完成") {
        Write-Host "镜像同步状态：待完成" -ForegroundColor Yellow
    }
    else {
        Write-Host "镜像同步状态：异常" -ForegroundColor Red
    }

    if ($Status -ne "已完成") {

        foreach ($Reason in $Reasons) {

            if ([string]::IsNullOrWhiteSpace($Reason)) {
                continue
            }

            if ($Status -eq "待完成") {
                Write-Host "待完成原因：$Reason" -ForegroundColor Yellow
            }
            else {
                Write-Host "异常原因：$Reason" -ForegroundColor Red
            }
        }
    }

    Write-Host ("总耗时：{0:hh\:mm\:ss}" -f $Elapsed)

    Write-Host ""
    Write-Host "同步记录：$ManifestPath"
    Write-Host "记录版本：V3"
    Write-Host "========================================"
}


# ==========================================================
# 8. 主程序
# ==========================================================

try {

    Write-Host ""
    Write-Host "========================================"
    Write-Host "           摄影镜像同步 V3.3"
    Write-Host "========================================"
    Write-Host ""

    Write-Host "源目录：$SourceRoot"
    Write-Host "备份目录：$BackupRoot"
    Write-Host "同步线程：8"
    Write-Host "文件身份：NTFS 文件 ID"
    Write-Host "删除方式：Windows 回收站"

    # ------------------------------------------------------
    # 8.1 环境检查
    # ------------------------------------------------------

    $Phase = "检查运行环境"

    if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
        throw "源目录不存在：$SourceRoot"
    }

    if (-not (Test-Path -LiteralPath $DriveMarker -PathType Leaf)) {
        throw "未检测到备份 SSD 标识：$DriveMarker"
    }

    Assert-NoReparsePoint "I:\"
    Assert-NoReparsePoint "I:\备份"
    Assert-NoReparsePoint $BackupRoot

    if (-not (Test-Path -LiteralPath $BackupRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $BackupRoot -Force |
            Out-Null
    }

    Assert-BackupPath "同步路径安全检查"

    if (
        -not (Test-Path -LiteralPath $ManifestPath) -and
        (
            (Test-Path -LiteralPath $ManifestTemp) -or
            (Test-Path -LiteralPath $ManifestBackup)
        )
    ) {
        throw "同步记录缺失，但发现旧记录副本，请检查后再运行"
    }

    $RootIdentity = [PhotoBackupIdentityV33]::GetId($SourceRoot)

    # ------------------------------------------------------
    # 8.2 读取上次同步记录
    # ------------------------------------------------------

    $Phase = "读取同步记录"

    $OldFilesById = @{}
    $OldDirsById = @{}

    $OldFilesByPath = @{}
    $OldDirsByPath = @{}

    $OldPendingFiles = @{}
    $OldPendingDirs = @{}

    if (Test-Path -LiteralPath $ManifestPath -PathType Leaf) {

        Write-Host ""
        Write-Host "[检查] 正在读取上次同步记录..."

        $Saved = Get-Content `
            -LiteralPath $ManifestPath `
            -Raw `
            -Encoding UTF8 |
            ConvertFrom-Json

        if ($null -eq $Saved -or $null -eq $Saved.Version) {
            throw "同步记录格式错误"
        }

        $Version = [int]$Saved.Version

        if ($Version -eq 3) {

            if ($Saved.SourceRootId -ne $RootIdentity) {
                throw "源目录身份发生变化，禁止使用旧记录继续同步"
            }

            foreach ($Entry in @($Saved.Files)) {

                if ($null -eq $Entry) { continue }

                Assert-ManagedPath ([string]$Entry.Path)

                $Key = Get-Identity $Entry

                if (
                    $OldFilesById.ContainsKey($Key) -or
                    $OldFilesByPath.ContainsKey([string]$Entry.Path)
                ) {
                    throw "旧记录存在重复文件：$($Entry.Path)"
                }

                $OldFilesById[$Key] = $Entry
                $OldFilesByPath[[string]$Entry.Path] = $Entry
            }

            foreach ($Entry in @($Saved.Directories)) {

                if ($null -eq $Entry) { continue }

                Assert-ManagedPath ([string]$Entry.Path)

                $Key = Get-Identity $Entry

                if (
                    $OldDirsById.ContainsKey($Key) -or
                    $OldDirsByPath.ContainsKey([string]$Entry.Path)
                ) {
                    throw "旧记录存在重复文件夹：$($Entry.Path)"
                }

                $OldDirsById[$Key] = $Entry
                $OldDirsByPath[[string]$Entry.Path] = $Entry
            }

            foreach ($Path in @($Saved.PendingFiles)) {

                if ($null -eq $Path) { continue }

                Assert-ManagedPath ([string]$Path)
                $OldPendingFiles[[string]$Path] = $true
            }

            foreach ($Path in @($Saved.PendingDirectories)) {

                if ($null -eq $Path) { continue }

                Assert-ManagedPath ([string]$Path)
                $OldPendingDirs[[string]$Path] = $true
            }

            Write-Host "[正常] 上次同步记录读取完成" `
                -ForegroundColor Green
        }
        elseif ($Version -eq 1 -or $Version -eq 2) {

            $IdentityBaseline = $true

            Write-Host "[升级] 建立 V3 文件身份记录" `
                -ForegroundColor Cyan

            Write-Host "[提示] 本次不会根据旧版记录执行删除" `
                -ForegroundColor Yellow
        }
        else {
            throw "不支持的同步记录版本：$Version"
        }
    }
    else {

        $IdentityBaseline = $true

        Write-Host ""
        Write-Host "[首次运行] 将建立同步记录" `
            -ForegroundColor Cyan
    }

    # ------------------------------------------------------
    # 8.3 扫描源目录
    # ------------------------------------------------------

    $Phase = "扫描源目录"

    Write-Host ""
    Write-Host "[扫描] 正在读取源目录..."

    $SourceScan = Get-DirectorySnapshot `
        -Root $SourceRoot `
        -WithIdentity `
        -IsSource

    $CurrentFilesById = New-IdentityIndex $SourceScan.Files
    $CurrentDirsById = New-IdentityIndex $SourceScan.Directories

    Write-Host "源目录文件数量：$($SourceScan.Files.Count)"
    Write-Host "源目录文件夹数量：$($SourceScan.Directories.Count)"

    # ------------------------------------------------------
    # 8.4 扫描备份目录
    # ------------------------------------------------------

    $Phase = "扫描备份目录"

    Write-Host ""
    Write-Host "[扫描] 正在读取备份目录原有文件..."

    $BackupBefore = Get-DirectorySnapshot -Root $BackupRoot

    Write-Host "备份目录文件数量：$($BackupBefore.Files.Count)"
    Write-Host "备份目录文件夹数量：$($BackupBefore.Directories.Count)"

    # ------------------------------------------------------
    # 8.5 分析源目录变化
    # ------------------------------------------------------

    $Phase = "分析源目录变化"

    $DeletedFiles = @{}
    $DeletedDirs = @{}

    if (-not $IdentityBaseline) {

        # 新增、修改源文件
        foreach ($Entry in $SourceScan.Files.Values) {

            $Key = Get-Identity $Entry

            if ($OldFilesById.ContainsKey($Key)) {

                $Old = $OldFilesById[$Key]

                if (
                    [long]$Old.Size -ne [long]$Entry.Size -or
                    [string]$Old.Modified -ne [string]$Entry.Modified
                ) {
                    $Counts.SourceModifiedFiles++
                }
            }
            elseif ($OldFilesByPath.ContainsKey($Entry.Path)) {

                # 相同路径出现了不同文件身份
                $Counts.SourceModifiedFiles++
            }
            else {

                $Counts.SourceNewFiles++
            }
        }

        # 新增源文件夹
        foreach ($Entry in $SourceScan.Directories.Values) {

            $Key = Get-Identity $Entry

            if (
                -not $OldDirsById.ContainsKey($Key) -and
                -not $OldDirsByPath.ContainsKey($Entry.Path)
            ) {
                $Counts.SourceNewDirs++
            }
        }

        # 文件夹重命名、移动：由浅到深
        $SortedOldDirs = @(
            $OldDirsById.Values |
            Sort-Object { Get-Depth ([string]$_.Path) }
        )

        foreach ($Old in $SortedOldDirs) {

            $Key = Get-Identity $Old

            if (-not $CurrentDirsById.ContainsKey($Key)) {
                continue
            }

            $Current = $CurrentDirsById[$Key]

            $EffectiveOldPath = Convert-ByPlans `
                -Relative ([string]$Old.Path) `
                -Plans $FolderPlans

            $CurrentPath = [string]$Current.Path

            if (Test-ExactPath $EffectiveOldPath $CurrentPath) {
                continue
            }

            $Kind = Get-ChangeKind $EffectiveOldPath $CurrentPath

            [void]$FolderPlans.Add(
                [pscustomobject]@{
                    From = $EffectiveOldPath
                    To = $CurrentPath
                    Kind = $Kind
                }
            )

            if ($Kind -eq "Rename") {
                $Counts.SourceRenamedDirs++
            }
            else {
                $Counts.SourceMovedDirs++
            }
        }

        # 文件重命名、移动
        foreach ($Old in $OldFilesById.Values) {

            $Key = Get-Identity $Old

            if (-not $CurrentFilesById.ContainsKey($Key)) {
                continue
            }

            $Current = $CurrentFilesById[$Key]

            $EffectiveOldPath = Convert-ByPlans `
                -Relative ([string]$Old.Path) `
                -Plans $FolderPlans

            $CurrentPath = [string]$Current.Path

            if (Test-ExactPath $EffectiveOldPath $CurrentPath) {
                continue
            }

            $Kind = Get-ChangeKind $EffectiveOldPath $CurrentPath

            [void]$FilePlans.Add(
                [pscustomobject]@{
                    From = $EffectiveOldPath
                    To = $CurrentPath
                    Kind = $Kind
                }
            )

            if ($Kind -eq "Rename") {
                $Counts.SourceRenamedFiles++
            }
            else {
                $Counts.SourceMovedFiles++
            }
        }

        # 检测源文件删除
        foreach ($Key in $OldFilesById.Keys) {

            if ($CurrentFilesById.ContainsKey($Key)) {
                continue
            }

            $Old = $OldFilesById[$Key]

            $Mapped = Convert-ByPlans `
                -Relative ([string]$Old.Path) `
                -Plans $FolderPlans

            if (-not $SourceScan.Files.ContainsKey($Mapped)) {
                $DeletedFiles[$Mapped] = $true
            }
        }

        # 检测源文件夹删除
        foreach ($Key in $OldDirsById.Keys) {

            if ($CurrentDirsById.ContainsKey($Key)) {
                continue
            }

            $Old = $OldDirsById[$Key]

            $Mapped = Convert-ByPlans `
                -Relative ([string]$Old.Path) `
                -Plans $FolderPlans

            if (-not $SourceScan.Directories.ContainsKey($Mapped)) {
                $DeletedDirs[$Mapped] = $true
            }
        }

        # 上次没有确认的删除记录继续保留
        foreach ($Path in $OldPendingFiles.Keys) {

            $Mapped = Convert-ByPlans `
                -Relative $Path `
                -Plans $FolderPlans

            if (-not $SourceScan.Files.ContainsKey($Mapped)) {
                $DeletedFiles[$Mapped] = $true
            }
        }

        foreach ($Path in $OldPendingDirs.Keys) {

            $Mapped = Convert-ByPlans `
                -Relative $Path `
                -Plans $FolderPlans

            if (-not $SourceScan.Directories.ContainsKey($Mapped)) {
                $DeletedDirs[$Mapped] = $true
            }
        }
    }

    $Counts.SourceDeletedFiles = $DeletedFiles.Count
    $Counts.SourceDeletedDirs = $DeletedDirs.Count

    # ------------------------------------------------------
    # 8.6 操作前检查冲突
    # ------------------------------------------------------

    $Phase = "检查备份路径冲突"

    Assert-MovePlansSafe

    # ------------------------------------------------------
    # 8.7 显示检测结果
    # ------------------------------------------------------

    $HasDetectedChanges = (
        $Counts.SourceNewFiles -gt 0 -or
        $Counts.SourceNewDirs -gt 0 -or
        $Counts.SourceModifiedFiles -gt 0 -or
        $FolderPlans.Count -gt 0 -or
        $FilePlans.Count -gt 0 -or
        $DeletedFiles.Count -gt 0 -or
        $DeletedDirs.Count -gt 0
    )

    if ($HasDetectedChanges) {

        Write-Host ""
        Write-Host "[检测] 检测到更新内容：" `
            -ForegroundColor Cyan

        foreach ($Plan in $FolderPlans) {

            $Label = if ($Plan.Kind -eq "Rename") {
                "文件夹重命名"
            } else {
                "文件夹移动"
            }

            Write-Host "[$Label] $($Plan.From) -> $($Plan.To)" `
                -ForegroundColor Cyan
        }

        foreach ($Plan in $FilePlans) {

            $Label = if ($Plan.Kind -eq "Rename") {
                "文件重命名"
            } else {
                "文件移动"
            }

            Write-Host "[$Label] $($Plan.From) -> $($Plan.To)" `
                -ForegroundColor Cyan
        }

        Show-Count "源目录检测到新增文件" `
            $Counts.SourceNewFiles "Cyan"

        Show-Count "源目录检测到新增文件夹" `
            $Counts.SourceNewDirs "Cyan"

        Show-Count "源目录检测到修改文件" `
            $Counts.SourceModifiedFiles "Cyan"

        Show-Count "源目录检测到删除文件" `
            $Counts.SourceDeletedFiles "Yellow"

        Show-Count "源目录检测到删除文件夹" `
            $Counts.SourceDeletedDirs "Yellow"
    }

    # ------------------------------------------------------
    # 8.8 显示已删除内容并询问
    # ------------------------------------------------------

    $Phase = "确认备份删除"

    $DeleteApproved = $false

    foreach ($Path in $DeletedFiles.Keys) {
        $PendingFiles[$Path] = $true
    }

    foreach ($Path in $DeletedDirs.Keys) {
        $PendingDirs[$Path] = $true
    }

    if ($PendingFiles.Count -gt 0 -or $PendingDirs.Count -gt 0) {

        Write-Host ""
        Write-Host "========================================" `
            -ForegroundColor Yellow

        Write-Host "            源目录已删除内容" `
            -ForegroundColor Yellow

        Write-Host "========================================" `
            -ForegroundColor Yellow
		Write-Host ""

        # 直接展示已删除的相对路径，不重复显示数量
        $Items = @(
            @($PendingDirs.Keys | Sort-Object) +
            @($PendingFiles.Keys | Sort-Object)
        )

        $Limit = [Math]::Min(30, $Items.Count)

        for ($Index = 0; $Index -lt $Limit; $Index++) {
            Write-Host "  $($Items[$Index])" `
                -ForegroundColor Yellow
        }

        if ($Items.Count -gt 30) {
            Write-Host "  另有 $($Items.Count - 30) 项未展开" `
                -ForegroundColor Yellow
        }

        Write-Host ""

        do {

            $Answer = Read-Host "是否将备份对应内容移入回收站？(Y/N)"

            if ($Answer -notmatch '^[YyNn]$') {
                Write-Host "请输入 Y 或 N。" -ForegroundColor Yellow
            }

        } while ($Answer -notmatch '^[YyNn]$')

        $DeleteApproved = $Answer -match '^[Yy]$'
    }

    # ------------------------------------------------------
    # 8.9 执行文件夹重命名、移动
    # ------------------------------------------------------

    $Phase = "同步备份文件夹路径"

    foreach ($Plan in $FolderPlans) {

        $Result = Move-BackupEntry `
            -From $Plan.From `
            -To $Plan.To

        if ($Result -ne "moved") {
            continue
        }

        [void]$AppliedFolderMoves.Add($Plan)

        if ($Plan.Kind -eq "Rename") {

            $Counts.BackupRenamedDirs++

            Write-Host "[备份文件夹重命名] $($Plan.From) -> $($Plan.To)" `
                -ForegroundColor Cyan
        }
        else {

            $Counts.BackupMovedDirs++

            Write-Host "[备份文件夹移动] $($Plan.From) -> $($Plan.To)" `
                -ForegroundColor Cyan
        }
    }

    # ------------------------------------------------------
    # 8.10 执行文件重命名、移动
    # ------------------------------------------------------

    $Phase = "同步备份文件路径"

    foreach ($Plan in $FilePlans) {

        $Result = Move-BackupEntry `
            -From $Plan.From `
            -To $Plan.To

        if ($Result -ne "moved") {
            continue
        }

        [void]$AppliedFileMoves.Add($Plan)

        if ($Plan.Kind -eq "Rename") {

            $Counts.BackupRenamedFiles++

            Write-Host "[备份文件重命名] $($Plan.From) -> $($Plan.To)" `
                -ForegroundColor Cyan
        }
        else {

            $Counts.BackupMovedFiles++

            Write-Host "[备份文件移动] $($Plan.From) -> $($Plan.To)" `
                -ForegroundColor Cyan
        }
    }

    # ------------------------------------------------------
    # 8.11 8 线程增量复制
    # ------------------------------------------------------

    $Phase = "执行文件复制"

    Write-Host ""
    Write-Host "========================================"
    Write-Host "             开始镜像同步"
    Write-Host "========================================"
    Write-Host ""

    $CopyArguments = @(
        $SourceRoot
        $BackupRoot
        "/E"
        "/MT:8"
        "/R:2"
        "/W:3"
        "/XJ"
        "/FFT"
        "/COPY:DAT"
        "/DCOPY:DAT"
        "/NJH"
        "/NJS"
        "/XF"
        (Join-Path $SourceRoot "摄影手动同步.bat")
        (Join-Path $SourceRoot "摄影同步核心.ps1")
        $ManifestPath
        $ManifestTemp
        $ManifestBackup
    )

    & robocopy @CopyArguments

    $CopyExitCode = $LASTEXITCODE

    if ($CopyExitCode -ge 4) {
        throw "复制过程出现异常，请检查上方文件日志"
    }

    # ------------------------------------------------------
    # 8.12 复制后检查
    # ------------------------------------------------------

    $Phase = "验证备份内容"

    $BackupAfter = Get-DirectorySnapshot -Root $BackupRoot

    $TimeTolerance = [long]20000000

    foreach ($Entry in $SourceScan.Files.Values) {

        $Path = $Entry.Path

        if (-not $BackupAfter.Files.ContainsKey($Path)) {
            throw "备份缺少文件：$Path"
        }

        $Actual = $BackupAfter.Files[$Path]

        if ([long]$Entry.Size -ne [long]$Actual.Size) {
            throw "备份文件大小不一致：$Path"
        }

        $TimeDifference = [Math]::Abs(
            [long]$Entry.Modified - [long]$Actual.Modified
        )

        if ($TimeDifference -gt $TimeTolerance) {
            throw "备份文件修改时间不一致：$Path"
        }
    }

    foreach ($Entry in $SourceScan.Directories.Values) {

        if (-not $BackupAfter.Directories.ContainsKey($Entry.Path)) {
            throw "备份缺少文件夹：$($Entry.Path)"
        }
    }

    # 检查 G 盘在同步期间有没有变化
    $Phase = "检查源目录变化"

    $SourceAfter = Get-DirectorySnapshot `
        -Root $SourceRoot `
        -WithIdentity `
        -IsSource

    if (-not (
        Test-SnapshotUnchanged `
            -Before $SourceScan `
            -After $SourceAfter
    )) {
        throw "同步期间源目录发生变化，请完成文件操作后重新运行"
    }

    # ------------------------------------------------------
    # 8.13 统计本次备份新增、修改
    # ------------------------------------------------------

    $Phase = "统计备份变化"

    $EffectiveBeforeFiles = @{}
    $EffectiveBeforeDirs = @{}

    foreach ($Entry in $BackupBefore.Files.Values) {

        $Mapped = Convert-ByPlans `
            -Relative $Entry.Path `
            -Plans $AppliedFolderMoves

        $Mapped = Convert-ByPlans `
            -Relative $Mapped `
            -Plans $AppliedFileMoves `
            -ExactOnly

        if ($EffectiveBeforeFiles.ContainsKey($Mapped)) {
            throw "备份文件路径映射冲突：$Mapped"
        }

        $EffectiveBeforeFiles[$Mapped] = $Entry
    }

    foreach ($Entry in $BackupBefore.Directories.Values) {

        $Mapped = Convert-ByPlans `
            -Relative $Entry.Path `
            -Plans $AppliedFolderMoves

        if ($EffectiveBeforeDirs.ContainsKey($Mapped)) {
            throw "备份文件夹路径映射冲突：$Mapped"
        }

        $EffectiveBeforeDirs[$Mapped] = $Entry
    }

    foreach ($Entry in $SourceScan.Files.Values) {

        $Path = $Entry.Path

        if (-not $EffectiveBeforeFiles.ContainsKey($Path)) {

            $Counts.BackupNewFiles++
            continue
        }

        $Previous = $EffectiveBeforeFiles[$Path]
        $Current = $BackupAfter.Files[$Path]

        if (
            [long]$Previous.Size -ne [long]$Current.Size -or
            [string]$Previous.Modified -ne [string]$Current.Modified
        ) {
            $Counts.BackupModifiedFiles++
        }
    }

    foreach ($Entry in $SourceScan.Directories.Values) {

        if (-not $EffectiveBeforeDirs.ContainsKey($Entry.Path)) {
            $Counts.BackupNewDirs++
        }
    }

    $CopyVerified = $true

    # ------------------------------------------------------
    # 8.14 用户确认后处理备份文件删除
    # ------------------------------------------------------

    if ($DeleteApproved) {

        $Phase = "处理备份文件删除"

        foreach ($Path in @($PendingFiles.Keys)) {

            $SourcePath = Join-Path $SourceRoot $Path
            $BackupPath = Join-Path $BackupRoot $Path

            # 源目录仍然存在时，不删除备份
            if (Test-Path -LiteralPath $SourcePath) {

                [void]$PendingFiles.Remove($Path)
                continue
            }

            if (-not (Test-Path -LiteralPath $BackupPath)) {

                [void]$PendingFiles.Remove($Path)
                continue
            }

            try {

                Assert-BackupPath $Path

                if (-not (
                    Test-Path -LiteralPath $BackupPath -PathType Leaf
                )) {
                    throw "对应备份位置不是文件"
                }

                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                    $BackupPath,
                    [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                    [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
                )

                if (Test-Path -LiteralPath $BackupPath) {
                    throw "文件未成功移入回收站"
                }

                [void]$PendingFiles.Remove($Path)

                $Counts.BackupRecycledFiles++

                Write-Host "[备份文件已回收] $Path" `
                    -ForegroundColor Green
            }
            catch {

                $Counts.BackupFailedFiles++

                $Message = "备份文件删除失败：$Path；$($_.Exception.Message)"
                $OperationErrors.Add($Message)

                Write-Host "[异常] $Message" `
                    -ForegroundColor Red
            }
        }

        # --------------------------------------------------
        # 8.15 文件夹仅在完全为空时移入回收站
        # --------------------------------------------------

        $Phase = "处理备份文件夹删除"

        $SortedDirs = @(
            $PendingDirs.Keys |
            Sort-Object { Get-Depth $_ } -Descending
        )

        foreach ($Path in $SortedDirs) {

            $SourcePath = Join-Path $SourceRoot $Path
            $BackupPath = Join-Path $BackupRoot $Path

            if (Test-Path -LiteralPath $SourcePath) {

                [void]$PendingDirs.Remove($Path)
                continue
            }

            if (-not (Test-Path -LiteralPath $BackupPath)) {

                [void]$PendingDirs.Remove($Path)
                continue
            }

            try {

                Assert-BackupPath $Path

                if (-not (
                    Test-Path -LiteralPath $BackupPath -PathType Container
                )) {
                    throw "对应备份位置不是文件夹"
                }

                $Children = @(
                    Get-ChildItem `
                        -LiteralPath $BackupPath `
                        -Force `
                        -ErrorAction Stop
                )

                if ($Children.Count -gt 0) {

                    Write-Host "[保留非空备份文件夹] $Path" `
                        -ForegroundColor Yellow

                    continue
                }

                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
                    $BackupPath,
                    [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                    [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
                )

                if (Test-Path -LiteralPath $BackupPath) {
                    throw "文件夹未成功移入回收站"
                }

                [void]$PendingDirs.Remove($Path)

                $Counts.BackupRecycledDirs++

                Write-Host "[备份文件夹已回收] $Path" `
                    -ForegroundColor Green
            }
            catch {

                $Counts.BackupFailedDirs++

                $Message = "备份文件夹删除失败：$Path；$($_.Exception.Message)"
                $OperationErrors.Add($Message)

                Write-Host "[异常] $Message" `
                    -ForegroundColor Red
            }
        }
    }

    # ------------------------------------------------------
    # 8.16 最终检查
    # ------------------------------------------------------

    $Phase = "最终检查源目录"

    $SourceFinal = Get-DirectorySnapshot `
        -Root $SourceRoot `
        -WithIdentity `
        -IsSource

    if (-not (
        Test-SnapshotUnchanged `
            -Before $SourceScan `
            -After $SourceFinal
    )) {
        throw "源目录在同步期间再次发生变化，本次记录未保存"
    }

    $SourceScan = $SourceFinal

    $Phase = "最终检查备份目录"

    $BackupFinal = Get-DirectorySnapshot -Root $BackupRoot

    foreach ($Entry in $SourceScan.Files.Values) {

        if (-not $BackupFinal.Files.ContainsKey($Entry.Path)) {
            throw "最终检查发现缺少备份文件：$($Entry.Path)"
        }

        $Actual = $BackupFinal.Files[$Entry.Path]

        if ([long]$Actual.Size -ne [long]$Entry.Size) {
            throw "最终检查发现文件大小不一致：$($Entry.Path)"
        }
    }

    foreach ($Entry in $SourceScan.Directories.Values) {

        if (-not $BackupFinal.Directories.ContainsKey($Entry.Path)) {
            throw "最终检查发现缺少备份文件夹：$($Entry.Path)"
        }
    }

    # ------------------------------------------------------
    # 8.17 保存历史清单
    # ------------------------------------------------------

    $Phase = "保存同步记录"

    Save-SyncManifest `
        -Snapshot $SourceFinal `
        -RootIdentity $RootIdentity

    $ManifestSaved = $true

    # ------------------------------------------------------
    # 8.18 判断最终状态
    # ------------------------------------------------------

    $Reasons = @()

    if ($OperationErrors.Count -gt 0) {

        $Status = "异常"
        $Reasons = @($OperationErrors.ToArray())
    }
    elseif (
        $PendingFiles.Count -gt 0 -or
        $PendingDirs.Count -gt 0
    ) {

        $Status = "待完成"

        $Reasons = @(
            "仍有 $($PendingFiles.Count) 个备份文件、$($PendingDirs.Count) 个备份文件夹尚未处理"
        )
    }
    else {

        $Status = "已完成"
    }

    # ------------------------------------------------------
    # 8.19 按实际操作类型显示完成提示
    # ------------------------------------------------------

    Write-Host ""

    $HasCompleted = $false

    if (
        $Counts.BackupNewFiles -gt 0 -or
        $Counts.BackupNewDirs -gt 0
    ) {

        Write-Host "[完成] 备份新增同步完成" `
            -ForegroundColor Green

        $HasCompleted = $true
    }

    if ($Counts.BackupModifiedFiles -gt 0) {

        Write-Host "[完成] 备份文件修改完成" `
            -ForegroundColor Green

        $HasCompleted = $true
    }

    if (
        $Counts.BackupRenamedFiles -gt 0 -or
        $Counts.BackupRenamedDirs -gt 0
    ) {

        Write-Host "[完成] 备份重命名同步完成" `
            -ForegroundColor Green

        $HasCompleted = $true
    }

    if (
        $Counts.BackupMovedFiles -gt 0 -or
        $Counts.BackupMovedDirs -gt 0
    ) {

        Write-Host "[完成] 备份移动同步完成" `
            -ForegroundColor Green

        $HasCompleted = $true
    }

    if (
        $Counts.BackupRecycledFiles -gt 0 -or
        $Counts.BackupRecycledDirs -gt 0
    ) {

        Write-Host "[完成] 备份删除同步完成" `
            -ForegroundColor Green

        $HasCompleted = $true
    }

    if ($Status -eq "异常") {

        Write-Host "[异常] 存在处理失败的操作" `
            -ForegroundColor Red
    }
    elseif ($Status -eq "待完成") {

        Write-Host "[待处理] 仍有备份删除操作尚未完成" `
            -ForegroundColor Yellow
    }
    elseif (
        -not $HasCompleted -and
        -not $HasDetectedChanges -and
        (($CopyExitCode -band 1) -eq 0)
    ) {

        Write-Host "[检查] 没有变化，无需同步" `
            -ForegroundColor Green
    }
    elseif (-not $HasCompleted) {

        Write-Host "[检查] 备份内容已是最新" `
            -ForegroundColor Green
    }

    # ------------------------------------------------------
    # 8.20 输出最终同步结果
    # ------------------------------------------------------

    Show-SyncResult -Status $Status -Reasons $Reasons

    if ($Status -eq "异常") {
        exit 1
    }

    exit 0
}
catch {

    $Reason = "${Phase}：$($_.Exception.Message)"

    $Reasons = @($Reason)

    foreach ($Message in $OperationErrors) {
        $Reasons += $Message
    }

    Show-SyncResult -Status "异常" -Reasons $Reasons

    if (-not $ManifestSaved) {

        Write-Host ""
        Write-Host "[提示] 本次同步记录未保存，请检查异常后重新同步。" `
            -ForegroundColor Yellow
    }

    exit 1
}