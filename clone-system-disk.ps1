# clone-system-disk.ps1 - clone the RUNNING Windows system disk onto a blank disk in a USB enclosure, ready to swap in.
# Written and tested by Claude for the owner's PCs (2026-10-06). v3 = general version of the tool that cloned the
# owner's own PC (WD_BLACK 1TB -> 4TB) successfully the same night.
#
#   Run from an ELEVATED PowerShell (Run as administrator):
#   powershell -ExecutionPolicy Bypass -File clone-system-disk.ps1 -Mode plan    (read-only: checks + logs the plan)
#   powershell -ExecutionPolicy Bypass -File clone-system-disk.ps1 -Mode run     (plan, then waits for a file GO next
#                                                                                  to the script; -Go skips the wait)
#   -TargetSize <bytes>  exact size of the blank target disk (default 1000204886016 = a 1 TB WD_BLACK SN7100)
#   -TargetName <name>   its FriendlyName in Get-Disk (default 'Realtek RTL9210B-CG', the USB enclosure)
#
# What it does (run mode), in order:
#   1. Refuses unless the source is the GPT boot disk holding C: (512-byte sectors) and the target is exactly ONE blank
#      (RAW, no partitions, no MBR signature / GPT header at the handle level) online USB disk of exactly -TargetSize
#      bytes named -TargetName. Every mounted volume on the source must be NTFS/ReFS and NOT BitLocker-encrypted.
#   2. Plans the target: partitions before C: keep their offsets; if nothing after C: has a drive letter, the
#      partitions after C: (recovery / OEM) move to the END of the target in the same order and C:'s partition grows to
#      fill the gap (else every offset is kept and C: does not grow).
#   3. Waits for GO (file next to the script) unless -Go; STOP or ABORT cancels.
#   4. Copies every partition: volumes with a drive letter through a Volume Shadow Copy (frozen, consistent),
#      fingerprinting every 32 MiB block, then deletes the snapshot and re-reads the WHOLE copy to verify it;
#      partitions without a letter (EFI, MSR, Recovery, OEM) raw, compared in full afterwards.
#   5. Writes the partition table LAST, write-through: protective MBR + primary and backup GPT with the SAME disk GUID
#      and the same partition GUIDs/types/attributes/names, so Windows boots from it unchanged after the swap. Windows
#      then sees two disks with one ID and takes the target OFFLINE: expected, leave it offline (never click Online).
# The source disk is only ever opened read-only. Abort safely at any time: create a file named ABORT next to the
# script, or Ctrl+C in its window (don't close the window: that skips the clean-up).
# After DONE: Safely Remove the USB disk, Shift + Start > Power > Shut down (full shutdown), swap the drives, boot.
# Then (elevated): diskpart > select volume C > extend filesystem > exit   (only if the plan said C: grows), and
# reagentc /info (Windows Recovery should still say Enabled).
param(
    [ValidateSet('plan', 'run')][string]$Mode = 'plan',
    [long]$TargetSize = 1000204886016,
    [string]$TargetName = 'Realtek RTL9210B-CG',
    [switch]$Go,
    [int]$MinFreeGB = 6
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$logPath = Join-Path $here 'clone.log'
# The log is opened once with read/write sharing so it can be watched while the clone runs; logging never throws.
$logStream = New-Object IO.FileStream($logPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
$logWriter = New-Object IO.StreamWriter($logStream, (New-Object Text.UTF8Encoding($false)))
$logWriter.AutoFlush = $true
function Log([string]$message) {
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $message
    try { $logWriter.WriteLine($line) } catch {}
    try { Write-Host $line } catch {}
}

$cs = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class DiskRaw
{
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sec, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(SafeFileHandle h, IntPtr buffer, uint count, out uint done, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteFile(SafeFileHandle h, IntPtr buffer, uint count, out uint done, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetFilePointerEx(SafeFileHandle h, long distance, out long newPosition, uint method);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr VirtualAlloc(IntPtr address, UIntPtr size, uint type, uint protect);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool VirtualFree(IntPtr address, UIntPtr size, uint type);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool FlushFileBuffers(SafeFileHandle h);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle h, uint code, IntPtr inBuffer, uint inSize, IntPtr outBuffer, uint outSize, out uint returned, IntPtr overlapped);
    [DllImport("kernel32.dll")]
    static extern uint SetThreadExecutionState(uint flags);

    const uint GENERIC_READ = 0x80000000;
    const uint GENERIC_WRITE = 0x40000000;
    const uint FILE_SHARE_READ = 1;
    const uint FILE_SHARE_WRITE = 2;
    const uint OPEN_EXISTING = 3;
    const uint FILE_FLAG_NO_BUFFERING = 0x20000000;
    const uint FILE_FLAG_WRITE_THROUGH = 0x80000000;
    const uint MEM_COMMIT = 0x1000;
    const uint MEM_RESERVE = 0x2000;
    const uint MEM_RELEASE = 0x8000;
    const uint PAGE_READWRITE = 4;
    const uint IOCTL_STORAGE_GET_DEVICE_NUMBER = 0x2D1080;
    const uint IOCTL_DISK_GET_LENGTH_INFO = 0x7405C;
    public const int Sector = 512;

    // ES_CONTINUOUS | ES_SYSTEM_REQUIRED while copying (no sleep), ES_CONTINUOUS to release. Constants live in C#:
    // PowerShell 5.1 reads 0x80000001 as a negative Int32.
    public static void KeepAwake(bool on)
    {
        SetThreadExecutionState(on ? 0x80000001u : 0x80000000u);
    }

    // A Win32Exception whose message carries the Win32 error text and code (the code is read first).
    static Exception Fail(string what)
    {
        int e = Marshal.GetLastWin32Error();
        return new Win32Exception(e, what + ": " + new Win32Exception(e).Message + " (Win32 " + e + ")");
    }

    // write = false: read-only, others may read and write. write = true: read/write; exclusiveWrite refuses other
    // writers (Disk Management / diskpart cannot initialize the target mid-copy); writeThrough = FUA writes.
    public static SafeFileHandle Open(string path, bool write, bool exclusiveWrite, bool writeThrough)
    {
        uint access = write ? (GENERIC_READ | GENERIC_WRITE) : GENERIC_READ;
        uint share = (write && exclusiveWrite) ? FILE_SHARE_READ : (FILE_SHARE_READ | FILE_SHARE_WRITE);
        uint flags = FILE_FLAG_NO_BUFFERING | ((write && writeThrough) ? FILE_FLAG_WRITE_THROUGH : 0u);
        SafeFileHandle h = CreateFileW(path, access, share, IntPtr.Zero, OPEN_EXISTING, flags, IntPtr.Zero);
        if (h.IsInvalid)
        {
            throw Fail("CreateFile " + path);
        }
        return h;
    }

    public static int DeviceNumber(SafeFileHandle h)
    {
        IntPtr buffer = Marshal.AllocHGlobal(12);
        try
        {
            uint returned;
            if (!DeviceIoControl(h, IOCTL_STORAGE_GET_DEVICE_NUMBER, IntPtr.Zero, 0, buffer, 12, out returned, IntPtr.Zero))
            {
                throw Fail("IOCTL_STORAGE_GET_DEVICE_NUMBER");
            }
            // STORAGE_DEVICE_NUMBER: DeviceType @0, DeviceNumber @4, PartitionNumber @8
            return Marshal.ReadInt32(buffer, 4);
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    public static long Length(SafeFileHandle h)
    {
        IntPtr buffer = Marshal.AllocHGlobal(8);
        try
        {
            uint returned;
            if (!DeviceIoControl(h, IOCTL_DISK_GET_LENGTH_INFO, IntPtr.Zero, 0, buffer, 8, out returned, IntPtr.Zero))
            {
                throw Fail("IOCTL_DISK_GET_LENGTH_INFO");
            }
            return Marshal.ReadInt64(buffer);
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    static IntPtr Alloc(int size)
    {
        IntPtr p = VirtualAlloc(IntPtr.Zero, (UIntPtr)(uint)size, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
        if (p == IntPtr.Zero)
        {
            throw Fail("VirtualAlloc");
        }
        return p;
    }

    static void Free(IntPtr p)
    {
        VirtualFree(p, UIntPtr.Zero, MEM_RELEASE);
    }

    static void Seek(SafeFileHandle h, long position)
    {
        long ignored;
        if (!SetFilePointerEx(h, position, out ignored, 0))
        {
            throw Fail("SetFilePointerEx " + position);
        }
    }

    static void CheckAligned(long position, long count, string what)
    {
        if (position < 0 || count <= 0 || position % Sector != 0 || count % Sector != 0)
        {
            throw new ArgumentException(string.Format("{0}: unaligned position {1} / count {2}", what, position, count));
        }
    }

    static void ReadAt(SafeFileHandle h, long position, IntPtr buffer, int count)
    {
        CheckAligned(position, count, "read");
        Seek(h, position);
        uint done;
        if (!ReadFile(h, buffer, (uint)count, out done, IntPtr.Zero))
        {
            throw Fail("ReadFile at " + position);
        }
        if (done != (uint)count)
        {
            throw new Exception(string.Format("Short read at {0}: {1} of {2}", position, done, count));
        }
    }

    static void WriteAt(SafeFileHandle h, long position, IntPtr buffer, int count)
    {
        CheckAligned(position, count, "write");
        Seek(h, position);
        uint done;
        if (!WriteFile(h, buffer, (uint)count, out done, IntPtr.Zero))
        {
            throw Fail("WriteFile at " + position);
        }
        if (done != (uint)count)
        {
            throw new Exception(string.Format("Short write at {0}: {1} of {2}", position, done, count));
        }
    }

    // A 64-bit fingerprint of `count` bytes (count is a multiple of 512, so of 8).
    static ulong Fingerprint(IntPtr buffer, int count, long[] scratch)
    {
        int words = count / 8;
        Marshal.Copy(buffer, scratch, 0, words);
        ulong h = 14695981039346656037UL;
        unchecked
        {
            for (int i = 0; i < words; i++)
            {
                h ^= (ulong)scratch[i];
                h *= 1099511628211UL;
                h ^= h >> 29;
            }
            h ^= (ulong)count;
        }
        return h;
    }

    // Copies `length` bytes from src@srcOffset to dst@dstOffset in `chunk` pieces (page-aligned buffer). When `hashes`
    // is given, stores each piece's fingerprint at hashes[baseIndex + piece] (fingerprints are of what was written).
    public static void Copy(SafeFileHandle src, long srcOffset, SafeFileHandle dst, long dstOffset, long length, int chunk, ulong[] hashes, int baseIndex)
    {
        CheckAligned(srcOffset, length, "copy source");
        CheckAligned(dstOffset, length, "copy target");
        if (chunk <= 0 || chunk % 4096 != 0)
        {
            throw new ArgumentException("chunk must be a positive multiple of 4096");
        }
        IntPtr buffer = Alloc(chunk);
        long[] scratch = hashes != null ? new long[chunk / 8] : null;
        try
        {
            long done = 0;
            int piece = 0;
            while (done < length)
            {
                int n = (int)Math.Min((long)chunk, length - done);
                ReadAt(src, srcOffset + done, buffer, n);
                if (hashes != null)
                {
                    hashes[baseIndex + piece] = Fingerprint(buffer, n, scratch);
                }
                WriteAt(dst, dstOffset + done, buffer, n);
                done += n;
                piece++;
            }
        }
        finally
        {
            Free(buffer);
        }
    }

    // Re-reads `length` bytes at h@offset in `chunk` pieces and compares each piece's fingerprint with
    // hashes[baseIndex + piece]. Returns -1 when all match, else the byte offset (relative) of the first bad piece.
    public static long Verify(SafeFileHandle h, long offset, long length, int chunk, ulong[] hashes, int baseIndex)
    {
        CheckAligned(offset, length, "verify");
        IntPtr buffer = Alloc(chunk);
        long[] scratch = new long[chunk / 8];
        try
        {
            long done = 0;
            int piece = 0;
            while (done < length)
            {
                int n = (int)Math.Min((long)chunk, length - done);
                ReadAt(h, offset + done, buffer, n);
                if (Fingerprint(buffer, n, scratch) != hashes[baseIndex + piece])
                {
                    return done;
                }
                done += n;
                piece++;
            }
            return -1;
        }
        finally
        {
            Free(buffer);
        }
    }

    public static byte[] ReadBytes(SafeFileHandle h, long position, int count)
    {
        IntPtr buffer = Alloc(count);
        try
        {
            ReadAt(h, position, buffer, count);
            byte[] result = new byte[count];
            Marshal.Copy(buffer, result, 0, count);
            return result;
        }
        finally
        {
            Free(buffer);
        }
    }

    public static void WriteBytes(SafeFileHandle h, long position, byte[] data)
    {
        IntPtr buffer = Alloc(data.Length);
        try
        {
            Marshal.Copy(data, 0, buffer, data.Length);
            WriteAt(h, position, buffer, data.Length);
        }
        finally
        {
            Free(buffer);
        }
    }

    // True when `length` bytes at a@aOffset equal b@bOffset (static regions: EFI, MSR, Recovery, the C: tail).
    public static bool Same(SafeFileHandle a, long aOffset, SafeFileHandle b, long bOffset, long length, int chunk)
    {
        CheckAligned(aOffset, length, "compare a");
        CheckAligned(bOffset, length, "compare b");
        IntPtr bufferA = Alloc(chunk);
        IntPtr bufferB = Alloc(chunk);
        try
        {
            byte[] x = new byte[chunk];
            byte[] y = new byte[chunk];
            long done = 0;
            while (done < length)
            {
                int n = (int)Math.Min((long)chunk, length - done);
                ReadAt(a, aOffset + done, bufferA, n);
                ReadAt(b, bOffset + done, bufferB, n);
                Marshal.Copy(bufferA, x, 0, n);
                Marshal.Copy(bufferB, y, 0, n);
                for (int i = 0; i < n; i++)
                {
                    if (x[i] != y[i])
                    {
                        return false;
                    }
                }
                done += n;
            }
            return true;
        }
        finally
        {
            Free(bufferA);
            Free(bufferB);
        }
    }

    public static void Flush(SafeFileHandle h)
    {
        if (!FlushFileBuffers(h))
        {
            throw Fail("FlushFileBuffers");
        }
    }

    static uint[] crcTable;
    public static uint Crc32(byte[] data, int offset, int count)
    {
        if (crcTable == null)
        {
            uint[] t = new uint[256];
            for (uint i = 0; i < 256; i++)
            {
                uint c = i;
                for (int k = 0; k < 8; k++)
                {
                    c = ((c & 1) != 0) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
                }
                t[i] = c;
            }
            crcTable = t;
        }
        uint crc = 0xFFFFFFFFu;
        for (int i = offset; i < offset + count; i++)
        {
            crc = crcTable[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
        }
        return crc ^ 0xFFFFFFFFu;
    }
}
'@

$chunk = 32MB
$segment = [long]1GB      # a whole number of chunks
$align = [long]2048       # sectors (1 MiB)

$srcH = $null
$tgtH = $null
$shadowH = $null
$shadowId = $null
$snapshotTime = $null
$awake = $false
$tableStarted = $false
$completed = $false
$N = [long]0
$shadowFile = Join-Path $here 'shadow-id.txt'
$goFile = Join-Path $here 'GO'
$stopFile = Join-Path $here 'STOP'
$abortFile = Join-Path $here 'ABORT'

function Guid-From([byte[]]$bytes, [int]$offset) {
    $g = New-Object byte[] 16
    [Array]::Copy($bytes, $offset, $g, 0, 16)
    return (New-Object Guid (, $g)).ToString()
}
function Put-UInt64([byte[]]$bytes, [int]$offset, [long]$value) {
    $b = [BitConverter]::GetBytes([UInt64]$value)
    [Array]::Copy($b, 0, $bytes, $offset, 8)
}
function Put-UInt32([byte[]]$bytes, [int]$offset, [uint32]$value) {
    $b = [BitConverter]::GetBytes($value)
    [Array]::Copy($b, 0, $bytes, $offset, 4)
}
function Get-Admin {
    $p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Check-Abort {
    if (Test-Path -LiteralPath $abortFile) { throw 'Aborted (ABORT file).' }
}
function Delete-Shadow([string]$id) {
    if (-not $id) { return }
    try {
        Get-WmiObject Win32_ShadowCopy -Filter "ID='$id'" | ForEach-Object { $_.Delete() }
        Log "Shadow copy $id deleted."
        Remove-Item -LiteralPath $shadowFile -Force -ErrorAction SilentlyContinue
    }
    catch { Log "WARNING: shadow copy $id not deleted ($($_.Exception.Message)). Run elevated: vssadmin delete shadows /shadow=$id /quiet" }
}

# The target layout. $parts: source partitions sorted by offset, each @{ Number; First; Sectors; Letter }. $cNumber:
# C:'s partition number. Partitions before C: keep their place. If no partition after C: has a drive letter they move
# to the end of an $N-sector disk (same order, 1 MiB aligned) and C: grows up to them; else everything keeps its place.
# Returns @{ Grow; Map = @{ Number -> @{ First; Last } } }; throws when the layout does not fit.
function Plan-Layout($parts, [int]$cNumber, [long]$N, [long]$align) {
    $lastUsable = $N - 34
    $cIndex = -1
    for ($i = 0; $i -lt $parts.Count; $i++) { if ($parts[$i].Number -eq $cNumber) { $cIndex = $i } }
    if ($cIndex -lt 0) { throw 'C: is not on the source disk' }
    $after = @()
    for ($i = $cIndex + 1; $i -lt $parts.Count; $i++) { $after += $parts[$i] }
    $grow = (@($after | Where-Object { $_.Letter }).Count -eq 0)
    $map = @{}
    for ($i = 0; $i -lt $cIndex; $i++) {
        $p = $parts[$i]
        $map[$p.Number] = @{ First = [long]$p.First; Last = [long]$p.First + $p.Sectors - 1 }
    }
    $c = $parts[$cIndex]
    if ($grow) {
        $cursor = $lastUsable
        for ($i = $after.Count - 1; $i -ge 0; $i--) {
            $p = $after[$i]
            $start = [long]([Math]::Floor(($cursor - $p.Sectors + 1) / $align)) * $align
            $map[$p.Number] = @{ First = $start; Last = $start + $p.Sectors - 1 }
            $cursor = $start - 1
        }
        $map[$c.Number] = @{ First = [long]$c.First; Last = $cursor }
    }
    else {
        for ($i = $cIndex; $i -lt $parts.Count; $i++) {
            $p = $parts[$i]
            $map[$p.Number] = @{ First = [long]$p.First; Last = [long]$p.First + $p.Sectors - 1 }
        }
    }
    # Checks: inside the usable area, in the same order, no overlap, every size kept (C: at least kept).
    $prevLast = [long]33
    foreach ($p in $parts) {
        $m = $map[$p.Number]
        if ($m.First -le $prevLast) { throw "Layout overlap/order problem at partition $($p.Number)" }
        if ($m.Last -gt $lastUsable) { throw "Partition $($p.Number) does not fit on the target (ends at sector $($m.Last), disk usable to $lastUsable)" }
        $size = $m.Last - $m.First + 1
        if ($p.Number -eq $cNumber) {
            if ($size -lt $p.Sectors) { throw 'C: would shrink: the target is too small' }
        }
        elseif ($size -ne $p.Sectors) { throw "Partition $($p.Number) changed size" }
        $prevLast = $m.Last
    }
    return @{ Grow = $grow; Map = $map }
}

# The target's partition table from the source GPT header + entry array: same disk GUID and entries, each partition
# at $map[number] (via $slot: number -> entry index), headers for an $N-sector disk.
function Build-Gpt([byte[]]$hdr, [int]$hdrSize, [byte[]]$entries, $slot, $map, [long]$N) {
    $lastUsable = $N - 34
    $newEntries = [byte[]]$entries.Clone()
    foreach ($number in @($map.Keys)) {
        $o = [int]$slot[[int]$number] * 128
        Put-UInt64 $newEntries ($o + 32) $map[$number].First
        Put-UInt64 $newEntries ($o + 40) $map[$number].Last
    }
    $entriesCrc = [DiskRaw]::Crc32($newEntries, 0, 16384)

    $primary = New-Object byte[] 512
    [Array]::Copy($hdr, 0, $primary, 0, $hdrSize)
    Put-UInt64 $primary 24 1                 # MyLBA
    Put-UInt64 $primary 32 ($N - 1)          # AlternateLBA
    Put-UInt64 $primary 40 34                # FirstUsableLBA
    Put-UInt64 $primary 48 $lastUsable       # LastUsableLBA
    Put-UInt64 $primary 72 2                 # PartitionEntryLBA
    Put-UInt32 $primary 88 $entriesCrc
    Put-UInt32 $primary 16 0
    Put-UInt32 $primary 16 ([DiskRaw]::Crc32($primary, 0, $hdrSize))

    $backup = [byte[]]$primary.Clone()
    Put-UInt64 $backup 24 ($N - 1)
    Put-UInt64 $backup 32 1
    Put-UInt64 $backup 72 ($N - 33)
    Put-UInt32 $backup 16 0
    Put-UInt32 $backup 16 ([DiskRaw]::Crc32($backup, 0, $hdrSize))

    $mbr = New-Object byte[] 512
    $mbr[446 + 1] = 0x00; $mbr[446 + 2] = 0x02; $mbr[446 + 3] = 0x00   # CHS start (0/0/2)
    $mbr[446 + 4] = 0xEE                                                # protective GPT
    $mbr[446 + 5] = 0xFF; $mbr[446 + 6] = 0xFF; $mbr[446 + 7] = 0xFF   # CHS end
    Put-UInt32 $mbr (446 + 8) 1
    Put-UInt32 $mbr (446 + 12) ([uint32]([Math]::Min($N - 1, [long][uint32]::MaxValue)))
    $mbr[510] = 0x55; $mbr[511] = 0xAA
    return @{ Mbr = $mbr; Primary = $primary; Backup = $backup; Entries = $newEntries; EntriesCrc = $entriesCrc }
}

# True when the volume has no BitLocker/Device Encryption (fully decrypted). Unknown = refuse.
function Test-Decrypted([string]$letter) {
    try {
        $ev = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -ErrorAction Stop | Where-Object { $_.DriveLetter -eq ($letter + ':') }
        if ($ev) {
            $status = Invoke-CimMethod -InputObject $ev -MethodName GetConversionStatus -ErrorAction Stop
            return ($status.ConversionStatus -eq 0)   # 0 = FullyDecrypted
        }
        return $true   # not an encryptable volume
    }
    catch {
        $sh = New-Object -ComObject Shell.Application
        $v = $sh.NameSpace($letter + ':').Self.ExtendedProperty('System.Volume.BitLockerProtection')
        return ($null -eq $v -or $v -eq 0 -or $v -eq 2)   # 2 = off (decrypted); 1 on, 3/4/5 converting/locked
    }
}

try {
    Log "=== clone-system-disk.ps1 v3 mode=$Mode admin=$(Get-Admin) target='$TargetName' $TargetSize bytes ==="
    if (-not (Get-Admin)) { throw 'Needs an elevated (administrator) PowerShell.' }
    Add-Type -TypeDefinition $cs

    if (Get-Process DiskCloneUI, DiskCloneExecutor -ErrorAction SilentlyContinue) { throw 'Close Hasleo Disk Clone first.' }
    if (Get-Process diskpart, mmc -ErrorAction SilentlyContinue) { throw 'Close diskpart / Disk Management (mmc) first.' }
    if (Test-Path -LiteralPath $shadowFile) { Delete-Shadow ((Get-Content -LiteralPath $shadowFile -Raw).Trim()) }
    foreach ($f in @($goFile, $stopFile, $abortFile)) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }

    # ---- 1. Which disk is which ------------------------------------------------------------------------------------
    $cPartition = Get-Partition -DriveLetter C
    $src = Get-Disk -Number $cPartition.DiskNumber
    if (-not $src.IsBoot -or $src.PartitionStyle -ne 'GPT' -or $src.LogicalSectorSize -ne 512) {
        throw "Unsupported source disk: #$($src.Number) '$($src.FriendlyName)' boot=$($src.IsBoot) style=$($src.PartitionStyle) sector=$($src.LogicalSectorSize) (needs a GPT/UEFI boot disk with 512-byte sectors)"
    }
    $candidates = @(Get-Disk | Where-Object { $_.Number -ne $src.Number -and $_.FriendlyName -eq $TargetName -and $_.BusType -eq 'USB' -and [long]$_.Size -eq $TargetSize })
    if ($candidates.Count -ne 1) { throw "Expected exactly one USB disk named '$TargetName' of exactly $TargetSize bytes, found $($candidates.Count). Get-Disk shows: $((Get-Disk | ForEach-Object { "#$($_.Number) '$($_.FriendlyName)' $($_.BusType) $($_.Size)" }) -join '; ')" }
    $tgt = $candidates[0]
    if ($tgt.Number -eq $src.Number -or $tgt.IsBoot -or $tgt.IsSystem -or $tgt.IsOffline -or $tgt.IsReadOnly -or $tgt.PartitionStyle -ne 'RAW' -or $tgt.LogicalSectorSize -ne 512) {
        throw "Target disk #$($tgt.Number) is not a blank online RAW 512-byte disk (style=$($tgt.PartitionStyle) offline=$($tgt.IsOffline) ro=$($tgt.IsReadOnly)). It must be wiped (diskpart clean) first."
    }
    if (@(Get-Partition -DiskNumber $tgt.Number -ErrorAction SilentlyContinue).Count -ne 0) { throw 'Target disk already has partitions.' }
    Log "Source: disk $($src.Number) '$($src.FriendlyName)' $($src.BusType) $($src.Size) bytes GUID $($src.Guid)"
    Log "Target: disk $($tgt.Number) '$($tgt.FriendlyName)' $($tgt.Size) bytes (blank) $($tgt.Path)"

    $raw = @(Get-Partition -DiskNumber $src.Number | Sort-Object Offset)
    if ($raw.Count -lt 1) { throw 'Source has no partitions' }
    $parts = @()
    foreach ($p in $raw) {
        $letter = if ($p.DriveLetter -and [string]$p.DriveLetter -match '^[A-Za-z]$') { [string]$p.DriveLetter } else { '' }
        $fs = ''
        $volSize = [long]0
        $volFree = [long]0
        if ($letter) {
            $v = Get-Volume -DriveLetter $letter
            $fs = [string]$v.FileSystem
            $volSize = [long]$v.Size
            $volFree = [long]$v.SizeRemaining
            if ($fs -ne 'NTFS' -and $fs -ne 'ReFS') { throw "Partition $($p.PartitionNumber) ($letter`:) is $($fs): only NTFS/ReFS volumes can be snapshotted. Unsupported." }
            if (-not (Test-Decrypted $letter)) { throw "$letter`: is BitLocker / Device Encryption protected or still converting. Turn encryption OFF and wait until it is fully decrypted, then run again." }
            if ($volSize -gt [long]$p.Size -or $volSize % 4096 -ne 0 -or ([long]$p.Size - $volSize) -gt 1MB) { throw "Unexpected $letter`: volume size $volSize vs partition $($p.Size)" }
            if ($volFree -lt [long]$MinFreeGB * 1GB) { throw "$letter`: has only $([Math]::Round($volFree / 1GB, 1)) GB free: the shadow copy needs room (at least $MinFreeGB GB). Free some space first." }
        }
        if ([long]$p.Offset % 512 -ne 0 -or [long]$p.Size % 512 -ne 0) { throw "Partition $($p.PartitionNumber) is not sector aligned" }
        $parts += [pscustomobject]@{
            Number = [int]$p.PartitionNumber; Offset = [long]$p.Offset; Size = [long]$p.Size; First = [long]($p.Offset / 512)
            Sectors = [long]($p.Size / 512); Type = $p.GptType.Trim('{}').ToLower(); Guid = $p.Guid.Trim('{}').ToLower()
            Letter = $letter; FileSystem = $fs; VolSize = $volSize; VolFree = $volFree
        }
    }
    $pC = $parts | Where-Object { $_.Letter -eq 'C' }
    if (-not $pC) { throw 'C: not found on the source disk' }

    # ---- 2. Read and check the source GPT --------------------------------------------------------------------------
    $srcH = [DiskRaw]::Open($src.Path, $false, $false, $false)
    if ([DiskRaw]::DeviceNumber($srcH) -ne $src.Number) { throw 'Source handle is not the expected disk number' }
    $srcLen = [DiskRaw]::Length($srcH)
    if ($srcLen -ne [long]$src.Size) { throw "Source length $srcLen != $($src.Size)" }
    $hdr = [DiskRaw]::ReadBytes($srcH, 512, 512)
    if ([Text.Encoding]::ASCII.GetString($hdr, 0, 8) -ne 'EFI PART') { throw 'Source LBA1 is not a GPT header' }
    $hdrSize = [BitConverter]::ToUInt32($hdr, 12)
    if ($hdrSize -lt 92 -or $hdrSize -gt 512) { throw "Bad GPT header size $hdrSize" }
    $check = [byte[]]$hdr.Clone(); Put-UInt32 $check 16 0
    if ([DiskRaw]::Crc32($check, 0, $hdrSize) -ne [BitConverter]::ToUInt32($hdr, 16)) { throw 'Source GPT header CRC mismatch' }
    $entryLba = [BitConverter]::ToUInt64($hdr, 72)
    $entryCount = [BitConverter]::ToUInt32($hdr, 80)
    $entrySize = [BitConverter]::ToUInt32($hdr, 84)
    if ($entryLba -ne 2 -or $entryCount -ne 128 -or $entrySize -ne 128) { throw "Unexpected GPT entry array lba=$entryLba count=$entryCount size=$entrySize" }
    $entries = [DiskRaw]::ReadBytes($srcH, 1024, 16384)
    if ([DiskRaw]::Crc32($entries, 0, 16384) -ne [BitConverter]::ToUInt32($hdr, 88)) { throw 'Source GPT entry array CRC mismatch' }
    $diskGuid = Guid-From $hdr 56
    if ($diskGuid -ne $src.Guid.Trim('{}').ToLower()) { throw "GPT disk GUID $diskGuid != $($src.Guid)" }

    # Every used GPT entry must match exactly one partition (offset, size, unique GUID), and vice versa.
    $slot = @{}
    for ($i = 0; $i -lt 128; $i++) {
        $o = $i * 128
        $typeGuid = Guid-From $entries $o
        if ($typeGuid -eq '00000000-0000-0000-0000-000000000000') { continue }
        $first = [long][BitConverter]::ToUInt64($entries, $o + 32)
        $last = [long][BitConverter]::ToUInt64($entries, $o + 40)
        $uniq = Guid-From $entries ($o + 16)
        $match = @($parts | Where-Object { $_.First -eq $first -and $_.Sectors -eq ($last - $first + 1) -and $_.Guid -eq $uniq })
        if ($match.Count -ne 1) { throw "GPT entry $i ($typeGuid $first-$last) does not match a partition" }
        $slot[[int]$match[0].Number] = $i
    }
    if ($slot.Count -ne $parts.Count) { throw "Matched $($slot.Count) GPT entries for $($parts.Count) partitions" }

    # ---- 3. Target layout ------------------------------------------------------------------------------------------
    $N = [long]($TargetSize / 512)
    $layout = Plan-Layout $parts $pC.Number $N $align
    foreach ($p in $parts) {
        $m = $layout.Map[$p.Number]
        $how = if ($p.Letter) { "$($p.Letter): $($p.FileSystem) via shadow copy ($([Math]::Round(($p.VolSize - $p.VolFree) / 1GB, 1)) GB used)" } else { 'raw copy' }
        Log ('Plan: partition {0} type {1} {2:N2} GB @ sector {3} -> {4:N2} GB @ sector {5}  [{6}]' -f $p.Number, $p.Type, ($p.Size / 1GB), $p.First, ((($m.Last - $m.First + 1) * 512) / 1GB), $m.First, $how)
    }
    if ($layout.Grow) { Log ('C: grows from {0:N1} GB to {1:N1} GB (run "extend filesystem" after the swap).' -f ($pC.Size / 1GB), ((($layout.Map[$pC.Number].Last - $pC.First + 1) * 512) / 1GB)) }
    else { Log 'C: does NOT grow (a lettered partition follows it); the extra space stays unallocated.' }
    Log "Disk GUID $diskGuid and every partition GUID kept."
    try { Log "Existing shadow copies: $(@(Get-WmiObject Win32_ShadowCopy).Count)" } catch {}
    if ($Mode -eq 'plan') { Log 'Plan only: nothing written.'; $completed = $true; return }

    if (-not $Go) {
        Log "Waiting for GO (create a file named GO in $here) or STOP..."
        $waited = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $goFile)) {
            if ((Test-Path -LiteralPath $stopFile) -or (Test-Path -LiteralPath $abortFile)) { throw 'Stopped before writing anything.' }
            if ($waited.Elapsed.TotalMinutes -gt 60) { throw 'No GO within 60 minutes; nothing written.' }
            Start-Sleep -Seconds 2
        }
        Log 'GO received.'
    }

    # ---- 4. Open the target (write) and prove at the handle level that it is the blank disk ---------------------------
    $tgtNow = Get-Disk -Number $tgt.Number
    if ($tgtNow.Path -ne $tgt.Path -or $tgtNow.PartitionStyle -ne 'RAW' -or [long]$tgtNow.Size -ne $TargetSize -or $tgtNow.IsBoot -or $tgtNow.IsSystem) { throw 'Target disk changed since the checks' }
    try { $tgtH = [DiskRaw]::Open($tgt.Path, $true, $true, $false) }
    catch {
        Log "Exclusive open refused ($($_.Exception.Message)); opening shared. Do NOT open Disk Management or diskpart until DONE."
        $tgtH = [DiskRaw]::Open($tgt.Path, $true, $false, $false)
    }
    if ([DiskRaw]::DeviceNumber($tgtH) -ne $tgt.Number) { throw 'Target handle is not the expected disk number' }
    if ([DiskRaw]::Length($tgtH) -ne $TargetSize) { throw 'Target length changed' }
    $lba0 = [DiskRaw]::ReadBytes($tgtH, 0, 512)
    $lba1 = [DiskRaw]::ReadBytes($tgtH, 512, 512)
    $lbaLast = [DiskRaw]::ReadBytes($tgtH, $TargetSize - 512, 512)
    if (($lba0[510] -eq 0x55 -and $lba0[511] -eq 0xAA) -or [Text.Encoding]::ASCII.GetString($lba1, 0, 8) -eq 'EFI PART' -or [Text.Encoding]::ASCII.GetString($lbaLast, 0, 8) -eq 'EFI PART') {
        throw 'Target disk is not blank at the handle level (MBR signature or GPT header found); refusing to write.'
    }
    [DiskRaw]::KeepAwake($true)
    $awake = $true
    $watch = [Diagnostics.Stopwatch]::StartNew()

    # ---- 5. Copy every partition -----------------------------------------------------------------------------------
    foreach ($p in $parts) {
        Check-Abort
        $tOff = [long]$layout.Map[$p.Number].First * 512
        if (-not $p.Letter) {
            Log ('Copying partition {0} ({1:N2} GB, raw)...' -f $p.Number, ($p.Size / 1GB))
            [DiskRaw]::Copy($srcH, $p.Offset, $tgtH, $tOff, $p.Size, $chunk, $null, 0)
            continue
        }
        $volLen = $p.VolSize
        Log "Creating a shadow copy of $($p.Letter):..."
        $made = ([WMICLASS]'root\cimv2:Win32_ShadowCopy').Create("$($p.Letter):\", 'ClientAccessible')
        $shadowId = [string]$made.ShadowID
        if ($made.ReturnValue -ne 0) { throw "Shadow copy failed (Win32_ShadowCopy.Create returned $($made.ReturnValue))" }
        Set-Content -LiteralPath $shadowFile -Value $shadowId -Encoding ASCII
        $snapshotTime = Get-Date
        $shadow = Get-WmiObject Win32_ShadowCopy -Filter "ID='$shadowId'"
        if (-not $shadow) { throw 'Shadow copy not found after creation' }
        Log ('SNAPSHOT of {0}: TAKEN {1:HH:mm:ss}. The new disk gets it exactly as it was at this moment; anything saved after this is NOT on it. Leave the PC alone until DONE.' -f $p.Letter, $snapshotTime)
        Log "Shadow copy $shadowId at $($shadow.DeviceObject) (if this run is ever killed: vssadmin delete shadows /shadow=$shadowId /quiet)"
        $shadowH = [DiskRaw]::Open($shadow.DeviceObject, $false, $false, $false)
        try { $shadowLen = [DiskRaw]::Length($shadowH) } catch { $shadowLen = $volLen }
        if ($shadowLen -lt $volLen) { throw "Shadow volume ($shadowLen) is smaller than $($p.Letter): ($volLen)" }

        $pieces = [int][Math]::Ceiling($volLen / [double]$chunk)
        $hashes = New-Object 'UInt64[]' $pieces
        $copyWatch = [Diagnostics.Stopwatch]::StartNew()
        $beat = [Diagnostics.Stopwatch]::StartNew()
        $beatDone = [long]0
        $done = [long]0
        while ($done -lt $volLen) {
            Check-Abort
            $n = [Math]::Min($segment, $volLen - $done)
            [DiskRaw]::Copy($shadowH, $done, $tgtH, $tOff + $done, $n, $chunk, $hashes, [int]($done / $chunk))
            $done += $n
            if ($beat.Elapsed.TotalSeconds -ge 20 -or $done -eq $volLen) {
                $now = ($done - $beatDone) / [Math]::Max(0.001, $beat.Elapsed.TotalSeconds)
                $avg = $done / [Math]::Max(1.0, $copyWatch.Elapsed.TotalSeconds)
                $eta = [TimeSpan]::FromSeconds(($volLen - $done) / [Math]::Max(1.0, $avg))
                $free = [long](Get-Volume -DriveLetter $p.Letter).SizeRemaining
                Log ('Copy {0}: {1:N1} / {2:N1} GB  {3:P1}  now {4:N0} MB/s  avg {5:N0} MB/s  ETA {6:hh\:mm\:ss}  free {7:N1} GB' -f $p.Letter, ($done / 1GB), ($volLen / 1GB), ($done / $volLen), ($now / 1MB), ($avg / 1MB), $eta, ($free / 1GB))
                if ($free -lt 2GB) { throw "$($p.Letter): free space fell under 2 GB during the copy (the shadow copy would be dropped). Free space and run again." }
                if ($done -ge 10GB -and $avg -lt 60MB) { throw ('Too slow ({0:N0} MB/s): move the USB case to a rear USB 3 port (no hub) and run again.' -f ($avg / 1MB)) }
                $beat.Restart(); $beatDone = $done
            }
        }
        $tail = $p.Size - $volLen
        if ($tail -gt 0) { [DiskRaw]::Copy($srcH, $p.Offset + $volLen, $tgtH, $tOff + $volLen, $tail, 4096, $null, 0) }
        [DiskRaw]::Flush($tgtH)
        if (-not (Get-WmiObject Win32_ShadowCopy -Filter "ID='$shadowId'")) { throw 'The shadow copy disappeared during the copy (VSS dropped it): the copy is not consistent. Free space and run again.' }
        $shadowH.Dispose(); $shadowH = $null
        Delete-Shadow $shadowId; $shadowId = $null
        Log ('{0}: copied in {1:hh\:mm\:ss}. Verifying every block on the new disk...' -f $p.Letter, $copyWatch.Elapsed)
        $verifyWatch = [Diagnostics.Stopwatch]::StartNew()
        $beat.Restart()
        $done = [long]0
        while ($done -lt $volLen) {
            Check-Abort
            $n = [Math]::Min($segment, $volLen - $done)
            $bad = [DiskRaw]::Verify($tgtH, $tOff + $done, $n, $chunk, $hashes, [int]($done / $chunk))
            if ($bad -ge 0) { throw ('Verify FAILED on {0}: at offset {1}: the new disk returned different data. Run again; if it repeats, the USB case or drive is faulty.' -f $p.Letter, ($done + $bad)) }
            $done += $n
            if ($beat.Elapsed.TotalSeconds -ge 20 -or $done -eq $volLen) {
                $avg = $done / [Math]::Max(1.0, $verifyWatch.Elapsed.TotalSeconds)
                $eta = [TimeSpan]::FromSeconds(($volLen - $done) / [Math]::Max(1.0, $avg))
                Log ('Verify {0}: {1:N1} / {2:N1} GB  {3:P1}  avg {4:N0} MB/s  ETA {5:hh\:mm\:ss}' -f $p.Letter, ($done / 1GB), ($volLen / 1GB), ($done / $volLen), ($avg / 1MB), $eta)
                $beat.Restart()
            }
        }
        if ($tail -gt 0 -and -not [DiskRaw]::Same($srcH, $p.Offset + $volLen, $tgtH, $tOff + $volLen, $tail, 4096)) { throw "Verify failed: $($p.Letter): tail" }
        Log "$($p.Letter): verified block for block."
    }
    [DiskRaw]::Flush($tgtH)
    Log 'Verifying the raw partitions in full...'
    foreach ($p in $parts) {
        if ($p.Letter) { continue }
        $tOff = [long]$layout.Map[$p.Number].First * 512
        if (-not [DiskRaw]::Same($srcH, $p.Offset, $tgtH, $tOff, $p.Size, $chunk)) { throw "Verify failed: partition $($p.Number) (Windows may have updated it during the run; run again)" }
    }
    Check-Abort

    # ---- 6. Partition table, written last, write-through ----------------------------------------------------------------
    Log 'Writing the partition table (protective MBR, primary + backup GPT, same GUIDs)...'
    $table = Build-Gpt $hdr $hdrSize $entries $slot $layout.Map $N
    $newEntries = $table.Entries; $primary = $table.Primary; $backup = $table.Backup; $mbr = $table.Mbr; $entriesCrc = $table.EntriesCrc
    $tgtH.Dispose(); $tgtH = $null
    try { $tgtH = [DiskRaw]::Open($tgt.Path, $true, $true, $true) } catch { $tgtH = [DiskRaw]::Open($tgt.Path, $true, $false, $true) }
    if ([DiskRaw]::DeviceNumber($tgtH) -ne $tgt.Number -or [DiskRaw]::Length($tgtH) -ne $TargetSize) { throw 'Target handle changed before the table write' }
    $tableStarted = $true
    [DiskRaw]::WriteBytes($tgtH, ($N - 33) * 512, $newEntries)   # backup entries first
    [DiskRaw]::WriteBytes($tgtH, ($N - 1) * 512, $backup)
    [DiskRaw]::WriteBytes($tgtH, 2 * 512, $newEntries)
    [DiskRaw]::WriteBytes($tgtH, 512, $primary)
    [DiskRaw]::WriteBytes($tgtH, 0, $mbr)
    [DiskRaw]::Flush($tgtH)
    $readPrimary = [DiskRaw]::ReadBytes($tgtH, 512, 512)
    $readBackup = [DiskRaw]::ReadBytes($tgtH, ($N - 1) * 512, 512)
    $readEntries = [DiskRaw]::ReadBytes($tgtH, 1024, 16384)
    $readBackupEntries = [DiskRaw]::ReadBytes($tgtH, ($N - 33) * 512, 16384)
    for ($i = 0; $i -lt 512; $i++) { if ($readPrimary[$i] -ne $primary[$i] -or $readBackup[$i] -ne $backup[$i]) { throw 'GPT header read-back mismatch' } }
    if ([DiskRaw]::Crc32($readEntries, 0, 16384) -ne $entriesCrc -or [DiskRaw]::Crc32($readBackupEntries, 0, 16384) -ne $entriesCrc) { throw 'GPT entries read-back mismatch' }
    $completed = $true
    Log ('DONE in {0:hh\:mm\:ss}. The new disk is a verified, bootable copy (snapshot taken {1:HH:mm:ss}).' -f $watch.Elapsed, $snapshotTime)
    Log 'Windows may now show the new disk as Offline (same disk ID as the running one): leave it offline, NEVER click Online.'
    Log 'Next: Safely Remove the USB disk in the tray, then hold Shift and click Start > Power > Shut down (full shutdown). Do NOT Restart. Then swap the drives.'
    if ($layout.Grow) { Log 'After the first boot from the new disk (elevated): diskpart > select volume C > extend filesystem > exit.' }
}
catch {
    Log "FAILED: $($_.Exception.Message)"
    if ($tableStarted -and $tgtH -and -not $tgtH.IsInvalid -and $N -gt 0) {
        try {
            [DiskRaw]::WriteBytes($tgtH, 0, (New-Object byte[] (34 * 512)))
            [DiskRaw]::WriteBytes($tgtH, ($N - 33) * 512, (New-Object byte[] (33 * 512)))
            [DiskRaw]::Flush($tgtH)
            Log 'Partition table on the new disk was cleared again (blank disk), so the clone can be re-run.'
        }
        catch { Log "Could not clear the new disk's partition table ($($_.Exception.Message)): ask before doing anything with the disks." }
    }
    Log 'No data on the source disk was written (only read, plus a temporary shadow copy). The new disk is not usable yet.'
}
finally {
    if ($shadowH) { $shadowH.Dispose() }
    if ($shadowId) { Delete-Shadow $shadowId }
    if ($tgtH) { $tgtH.Dispose() }
    if ($srcH) { $srcH.Dispose() }
    if ($awake) { [DiskRaw]::KeepAwake($false) }
    if ($completed) { Log 'RESULT: OK' } else { Log 'RESULT: NOT COMPLETED' }
    try { $logWriter.Dispose() } catch {}
}
if (-not $completed) { exit 1 }
