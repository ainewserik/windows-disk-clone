# Clone her Windows drive onto the 1 TB NVMe (for the Claude session on her PC)

**Goal.** Her PC boots Windows from a 500 GB NVMe in its only M.2 slot. We want a bootable copy of that drive on a
blank 1 TB WD_BLACK SN7100 NVMe, then we swap the two drives.
- The 1 TB sits in a Realtek RTL9210B-CG USB enclosure and was wiped with `diskpart clean all`.
- Hasleo Disk Clone Free refuses USB destinations, so we use `clone-system-disk.ps1` (in this gist).
- The same tool, in a version locked to the owner's own drives, cloned his PC tonight (1 TB to 4 TB). It booted first
  time.

**What the tool does.**
- It only ever reads her 500 GB drive.
- It copies each lettered volume through a Volume Shadow Copy, fingerprints every block and re-reads the whole copy to
  verify it.
- It copies the small partitions (EFI, MSR, Recovery, OEM) raw.
- It writes the partition table last, with the same disk and partition IDs. C: grows to fill the 1 TB if nothing with
  a drive letter comes after it.

## Steps

1. **Save it.** Download `clone-system-disk.ps1` from this gist into a new folder, e.g. `C:\clone\`.
   Read it fully before running it.
2. **Read-only checks first.** Look at:
   - `Get-Disk`: the 1 TB must show as `Realtek RTL9210B-CG`, USB, 1000204886016 bytes, RAW.
   - `Get-Partition` for her boot disk.
   - BitLocker / Device Encryption on C:. It must be fully OFF and decrypted. If it is on, she turns it off in
     Settings and waits until decryption finishes.
   - C: needs at least 6 GB free.
3. **Plan.** In an elevated PowerShell (the user clicks Yes on the Windows prompt), run:

   ```
   powershell -ExecutionPolicy Bypass -File C:\clone\clone-system-disk.ps1 -Mode plan
   ```

   It writes nothing and logs to `C:\clone\clone.log`. Show the plan lines to the user and get a clear yes.
4. **Run.** Elevated:

   ```
   powershell -ExecutionPolicy Bypass -File C:\clone\clone-system-disk.ps1 -Mode run -Go
   ```

   - Expect roughly 15 to 40 minutes for a 500 GB drive over USB: copy plus a full verify.
   - The PC must stay on and idle. Anything saved after the snapshot line is not on the copy.
   - Abort safely by creating `C:\clone\ABORT`, or with Ctrl+C. Never close the window.
   - Watch `clone.log`. A heartbeat line appears about every 20 s.
5. **When it says `DONE` / `RESULT: OK`:**
   - The 1 TB may show as Offline (same ID as her drive). Leave it offline and NEVER click Online.
   - Safely Remove the USB disk.
   - Hold **Shift** and click Start > Power > **Shut down**. Do not Restart.
   - Swap the drives: the 1 TB goes into the M.2 slot, her 500 GB comes out and is kept as a backup.
6. **First boot from the 1 TB.**
   - If it doesn't boot, press F12 (or the boot menu key) and pick Windows Boot Manager.
   - Then, elevated: `diskpart`, `select volume C`, `extend filesystem`, `exit`. Do this only if the plan said C: grows.
   - Then `reagentc /info`: Windows Recovery should show Enabled.
   - Keep the old 500 GB untouched for a week or two before anyone wipes it. Wiping is the owner's own action, not
     Claude's.

## Hard rules

- Never write to her 500 GB drive.
- Never run diskpart clean / format / initialize on anything.
- The tool is the only thing that writes, and only to the blank 1 TB USB disk, after the user's yes.
- If the tool refuses (wrong disk, encrypted, GPT/MBR mismatch, too little space), report the exact message. Don't
  work around it.
