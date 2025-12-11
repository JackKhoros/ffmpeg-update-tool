# FFmpeg Auto-Updater for Windows (PowerShell)

This repository contains a fully automatic FFmpeg updater for Windows.  
It downloads the latest official FFmpeg build from the BtbN GitHub releases,
verifies changes using ETag, and updates only when needed.
The script works with both Windows PowerShell 5.1 (`powershell`) and PowerShell 7+ (`pwsh`).  
If you have PowerShell 7 installed, using `pwsh` is recommended (no legacy security prompts, better future compatibility).

### PowerShell Compatibility

The script works with both:

* **Windows PowerShell 5.1** — use `powershell`
* **PowerShell 7+ (pwsh)** — recommended for best compatibility and no security prompts introduced in recent Windows updates

If you have PowerShell 7 installed, running the updater using `pwsh` is strongly recommended.

## Usage

Place `update_ffmpeg.ps1` in the same folder as your FFmpeg binaries
(`ffmpeg.exe`, `ffprobe.exe`, `ffplay.exe`) and run the script:

```powershell
# Windows PowerShell 5.1
powershell -ExecutionPolicy Bypass -File "path\to\update_ffmpeg.ps1"
```

```powershell
# PowerShell 7+ (recommended)
pwsh -ExecutionPolicy Bypass -File "path\to\update_ffmpeg.ps1"
```

Replace `"path\to\update_ffmpeg.ps1"` with the actual path to your script, e.g.:

```
pwsh -ExecutionPolicy Bypass -File "D:\Tools\ffmpeg\update_ffmpeg.ps1"
```

The script will:
- Check for the latest FFmpeg build (via ETag)
- Avoid redundant downloads
- Detect rate-limited throttled speeds and retry intelligently
- Download the ZIP via curl.exe (fast mode) to `ffmpeg-update.zip` in the current directory
- Remove the downloaded archive after extracting only the required binaries
- Show detailed colorized progress bars and logs

## Features
- ⚡ **Fast download via curl (RAM/Direct ZIP modes)**
- 🧠 **Intelligent retry when GitHub throttles bandwidth**
- 🟣 **Beautiful colored progress bar**
- 🔍 **Version comparison via `ffmpeg -version`**
- 📦 **ZIP extraction without writing temp folders**
- 🔄 **Only updates when a new build is available**
- 🛡️ **Safe — never overwrites unrelated files**

## Requirements
- Windows 10/11
- PowerShell 5+ (default)
- curl.exe (bundled in Windows)

---

Enjoy the tool!
