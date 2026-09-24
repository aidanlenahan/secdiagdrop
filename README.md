# segdiagdrop - Workstation Maintenance and Diagnostics Tool

A PowerShell tool for doing low-level maintenance and safety checks on Windows
computers used in a supervised program. Scans a machine, offers to fix and
clean things, and uploads a single diagnostic report to your private Google
Drive after you approve it from your phone with a free and secure Google Apps Script backend. Nothing sensitive is stored on the
computer it runs on. Perfect for any kind of nonprofit needing free, open-source, and easy software to manage many computers at once periodically, and easily.

---

## The short version of how it works

1. You run one launcher file from a USB stick.
2. The launcher pulls the current script from your GitHub repo (or whereever you want it stored online) and runs it *in
   memory* - nothing is written to the machine's disk.
3. The script asks for a password only you know, then a few intake questions.
4. It scans the machine (disk, drive health, files, software, startup, browser,
   security) - all read-only, changing nothing.
5. It offers to fix/clean/remove things - you confirm each one.
6. It asks what you fixed, builds one report, and sends it to your endpoint.
7. Your phone gets an email with the machine's details and an **Approve / Deny**
   button. Only when you Approve does the report save to your Drive.
8. On exit, every temporary file is securely wiped. Nothing is left behind.

---

## The three moving parts

| Part | What it is | Where it lives |
|---|---|---|
| **`Invoke-PCMaintenance.ps1`** | The main script that does everything | Public GitHub repo |
| **`sqlite3.exe`** | A small tool, fetched only if you approve a deletion | Same GitHub repo |
| **`DiagnosticDrop.gs`** | Google Apps Script: checks your predefined, script-specific password, emails you the approval, saves the file to Drive | script.google.com |
| **`RUN-MAINTENANCE.cmd`** | Tiny launcher that starts the whole thing | Your USB stick |

The GitHub repo is **public and contains no secrets**. The only secret is your
password, which you type at runtime and which is double-checked by the Google side, or an email that you must manually approve for the diagnostic file to be saved to your Drive.

---

## Why nothing sensitive is exposed

- **The script and its URLs are not secret.** The endpoint URL is useless
  without your password.
- **Your password is never stored.** You type it (hidden) each run. It lives in
  memory only and is wiped on exit. The Google side stores only a one-way hash
  of it and rate-limits guesses (5 wrong tries locks it out), so a memorable
  password is safe.
- **The diagnostic never touches the machine's disk.** It's built in memory and
  uploaded. (If upload fails, you're *offered* a local save to the Desktop.)
- **Saved passwords flagged by the script are never read.** The browser check only sees *which sites*
  have saved logins, by domain - never the passwords themselves.

---

## What the scan looks at

- **System summary** - OS, model, CPU, RAM, uptime, memory pressure
- **Disk usage** - flags any drive over 50% full
- **Drive health (SMART)** - SSD wear, temperature, failure prediction, disk errors
- **Files** - Desktop + Downloads, flagging large/stale/executable/suspicious files
- **Installed software** - full list + recent installs
- **Flagged software** - junkware, scareware, remote-access tools, miners, etc.
- **Games + unauthorized software** - game launchers, VPNs, torrent clients, etc.
- **Startup apps** - everything set to run at boot/login
- **Browser** - risky extensions, hijacked settings, dangerous domains in history,
  inappropriate content (for safeguarding), and saved-login domains
- **Security posture** - Defender, firewall, BitLocker, pending reboots
- **Temp/cache** - reclaimable space
- **Windows Update** - pending updates

**These flagged thresholds can be modified in the powershell script.**

## What it can fix/remove (only after you confirm each)

- Delete flagged files from Desktop/Downloads
- Uninstall games and unauthorized software (shown as a list first)
- Remove saved financial or inappropriate-site logins (by domain)
- Clear inappropriate browsing history (preserved in the report first)
- Install Windows updates
- Open Disk Cleanup
- **Recommended options** (multi-select): remove BitLocker, empty Recycle Bin,
  flush DNS, create a restore point, run SFC, disable hibernation, enable
  Storage Sense, restart

Everything destructive is opt-in, one prompt at a time, at the end of the run.

---

## Safeguarding

These machines may be used by minors, so the tool takes extra care:

- Inappropriate content (adult/gambling) found in history is recorded in a
  confidential section of the report **before** anything is deleted, so a record
  always reaches you even after cleanup.
- Report any illegal activity to law enforcement. Preserve any evidence of such activity.
- Make sure your program's overseers have approved this tool in writing before
  using it on real machines. It scans browsing and removes data on computers
  used by vulnerable people, which should be authorized, not improvised.

---

## One-time setup

### 1. Google Apps Script (Drive + approval)
1. Create a Drive folder; copy its ID from the URL.
2. Pick a password you'll remember. Compute its SHA-256 hash (this can be done on Windows, Linux, or MacOS; just Google it).
3. Paste `DiagnosticDrop.gs` into script.google.com, fill in `FOLDER_ID`,
   `PASS_HASH`, `YOUR_EMAIL` with your own, accurate secrets.
4. Deploy as a **Web app** in Google Apps Script: Execute as **Me**, Access **Anyone**.
5. Copy the `/exec` URL.

> After **any** edit to the Apps Script, redeploy a **New version** or the old
> code keeps running.

### 2. GitHub (host the script + sqlite tool)
1. Put `Invoke-PCMaintenance.ps1` in a public repo.
2. Download the official **sqlite-tools** zip (not the DLL one), take
   `sqlite3.exe`, upload just that.
3. In the script's `$Config`, set `UploadEndpoint` (your `/exec` URL) and
   `SqliteToolUrl` (the raw `sqlite3.exe` URL). Leave `Password` empty.

### 3. The launcher
Put `RUN-MAINTENANCE.cmd` on your USB stick and set its `SCRIPTURL` to your raw
script URL.

---

## Running it on a machine

1. Double-click `RUN-MAINTENANCE.cmd` (right-click -> **Run as administrator**
   for full results).
2. A window opens rooted in the temp folder - **you can remove the USB now.**
3. Type your password (hidden), answer the intake questions.
4. Let the scan run; confirm each fix/removal at the end.
5. Answer "what did you fix?"
6. Your phone buzzes - tap **Approve** on the email.
7. The report lands in a dated `MM-DD-YYYY` folder in your Drive.
8. Press Enter; the screen clears and temp files are wiped.

---

## Health check

Confirm the Google endpoint is alive (no password needed):

```
https://YOUR-EXEC-URL/exec?action=ping   ->   {"ok":true,"alive":true}
```

---

## Good to know / limitations

- **Run as administrator** or update installs, BitLocker changes, SFC, restore
  points, and some checks won't work.
- Public IP/geolocation needs the network to allow an outbound lookup; it may be
  blank on locked-down networks.
- If a browser is open during the scan, the newest history entries might be
  missing from the read (harmless). Deletions close the browser first.
- The tool needs outbound HTTPS to GitHub, your Google endpoint, and (for
  geo) an IP lookup service. Locked-down networks may need these allowlisted.

---

## Files in this project

| File | Purpose |
|---|---|
| `Invoke-PCMaintenance.ps1` | The main script (goes in your GitHub repo) |
| `DiagnosticDrop.gs` | Google Apps Script backend (goes in script.google.com) |
| `RUN-MAINTENANCE.cmd` | USB launcher |
| `sqlite3.exe` | Deletion helper (goes in your GitHub repo) |
| `README.md` | This file |
