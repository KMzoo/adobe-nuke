# adobe-nuke

Removes Adobe software from Windows **completely**: the programs, their services and background processes, the Explorer shell extensions that keep folders locked, thousands of leftover registry entries, cached installer packages and temp files.

Built for when Adobe's own uninstallers fail, or leave folders behind that refuse to be deleted ("file is in use", "access denied"), even with tools like SUPERDelete or Adobe's Creative Cloud Cleaner Tool.

> [!WARNING]
> This removes **all** Adobe software, including **Acrobat Reader**. Your `Creative Cloud Files` sync folder is never touched. Every registry change is backed up first.
>
> Adobe folders are deleted whole. **Third-party plug-ins installed inside them** (for example into `Adobe\Common\Plug-ins` or an application's `Plug-ins` folder) are deleted with them and are not backed up. Registry records of registered non-Adobe products are left alone. Run `-DryRun` first to see which folders would be deleted.

## Quick start

Open **PowerShell** (Start menu → type `powershell` → Enter) and paste:

```powershell
irm https://raw.githubusercontent.com/KMzoo/adobe-nuke/main/adobe-nuke.ps1 | iex
```

It asks for administrator rights, shows everything it found, and waits for your `y` before changing anything.

**See first, change nothing:**

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/KMzoo/adobe-nuke/main/adobe-nuke.ps1))) -DryRun
```

**Adobe programs still installed?** Let the official uninstallers run first, then clean up what they leave:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/KMzoo/adobe-nuke/main/adobe-nuke.ps1))) -UninstallFirst
```

> Running a script straight from the internet means trusting it. Read [`adobe-nuke.ps1`](adobe-nuke.ps1) first, or use the download option below.

### Or download and double-click

1. **Code → Download ZIP**, extract it.
2. Double-click **`adobe-nuke.cmd`** and allow administrator rights.

| File | What it is |
|---|---|
| `adobe-nuke.ps1` | **The actual script.** All the logic is here. |
| `adobe-nuke.cmd` | **A one-line launcher** for double-clicking. Windows opens `.ps1` files in Notepad and blocks downloaded scripts, so this starts PowerShell with that check bypassed for this one run. Keep both files in the same folder. |

## Why Adobe folders won't delete

Three things keep them alive at the same time:

1. **Services and scheduled tasks** (Adobe Genuine, AdobeUpdateService, AdobeGCInvoker, CCXProcess...) restart Adobe processes as soon as you kill them.
2. **Explorer shell extensions** (`CoreSync_x64.dll`, `AdobeExplorerShellExtension.dll`) are loaded inside `explorer.exe`, so Windows Explorer itself holds the files open. Killing Explorer doesn't help: Windows restarts it instantly and it loads them again.
3. **Restricted permissions.** Some folders are owned by SYSTEM on purpose.

adobe-nuke takes these apart in the right order, so in most cases everything is gone without a reboot.

## What it removes

| Step | What |
|---|---|
| 0 | *(optional, `-UninstallFirst`)* Official uninstallers. MSI products (Acrobat, Reader) uninstall silently. |
| 1 | Adobe services: stopped and deleted |
| 2 | Adobe scheduled tasks |
| 3 | Every process running from an Adobe folder |
| 4 | Explorer shell extensions: unregistered, then Explorer is restarted to release them |
| 5 | Adobe PDF printer: printer, port, driver and port monitor |
| 6 | Program and data folders (ownership taken, robocopy fallback for long `node_modules` paths) |
| 7 | Start menu and desktop shortcuts pointing to Adobe |
| 8 | **Caches:** Adobe packages and patches in `C:\Windows\Installer`, temp files, prefetch |
| 9 | **Firewall rules** for Adobe programs |
| 10 | **Registry** (see below) |

Files that are *still* in use after all that are moved to a quarantine folder on the same drive (Windows allows renaming a loaded DLL), so the Adobe folders disappear right away. The quarantine is deleted automatically at the next restart.

### Folders

- `C:\Program Files\Adobe` and `C:\Program Files (x86)\Adobe`
- `C:\Program Files\Common Files\Adobe` and `C:\Program Files (x86)\Common Files\Adobe`
- `C:\ProgramData\Adobe`
- `AppData\Roaming\Adobe`, `AppData\Local\Adobe`, `AppData\LocalLow\Adobe` for every user profile

`AppData\Roaming\Adobe` holds app settings and presets. Copy anything you want to keep before running.

### Registry

Entries are found by **what they point to**, not just by name, so leftovers of programs whose files are already gone are found too.

- Uninstall entries (Settings → Apps list)
- Windows Installer registrations and component records of Adobe MSI products, including orphaned ones
- `HKLM\SOFTWARE\Adobe`, `HKLM\SOFTWARE\WOW6432Node\Adobe`, `HKCU\Software\Adobe`
- COM classes, type libraries and AppIDs whose files live in Adobe folders
- File types (ProgIDs) opened by Adobe programs, plus references to them in `.pdf`, `.psd` etc. The extension keys themselves are kept, so Windows simply asks which app to use next time.
- Explorer hooks: context menu handlers, icon overlays, approved shell extensions, browser helper objects
- App Paths and autostart (`Run`) values

A machine with several Creative Cloud versions installed can easily have **thousands** of these.

### Caches

- Cached `.msi` / `.msp` packages in `C:\Windows\Installer` that belong to Adobe products. Orphaned ones are detected by reading each package's author; nothing outside that folder is touched. Acrobat updates alone can leave several GB here.
- Adobe folders and files in `%TEMP%` and `C:\Windows\Temp`
- Adobe entries in `C:\Windows\Prefetch`

## Options

| Parameter | Effect |
|---|---|
| `-DryRun` | Lists everything that would be removed. Nothing is changed. The full registry list is saved to `%TEMP%\dryrun-adobe-nuke-registry.txt`. |
| `-UninstallFirst` | Runs Adobe's own uninstallers before the force cleanup. Creative Cloud apps may open their own uninstaller window. |
| `-Force` | No confirmation prompts. |
| `-SkipRegistry` | Leaves the registry and firewall rules untouched. |
| `-SkipCache` | Leaves the installer cache, temp files and prefetch untouched. |
| `-IncludeDocuments` | Also deletes the `Adobe` folder in each user's Documents folder. It is left alone by default because it can hold your own presets, libraries and auto-saved projects. |

With the downloaded files: `.\adobe-nuke.ps1 -DryRun` or `adobe-nuke.cmd -DryRun`.

## Log and backup

Every real run creates `adobe-nuke-<date>` in your Documents folder with:

- `log.txt`: full transcript of the run
- `registry-changes.txt`: every registry key and value that was removed
- `registry-backup\<category>.reg`: everything as it was before the change, one file per category. Double-click a file to restore it.

## Tips

- This is all or nothing. If you still use some Adobe apps, uninstall the others normally instead.
- **Sign out of Creative Cloud first** if your plan has an activation limit. Removing the apps does not free the activation on Adobe's side.
- If it says a restart is needed, restart once. The remaining files are deleted during boot.
- Only the default install locations are cleaned. If you installed Adobe apps on another drive, delete those folders afterwards.
- After the cleanup, PDFs and other Adobe file types have no default app until you pick one.
- Error popups about `acrodist.exe` or other missing Adobe programs after deleting Adobe by hand are a typical sign of leftover autostart entries and COM registrations. This cleans them up.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (built in) or PowerShell 7
- Administrator rights (requested automatically)

## Disclaimer

Use at your own risk. adobe-nuke force-removes software, files and registry entries. Run `-DryRun` first if you are unsure. Not affiliated with Adobe.

## License

[MIT](LICENSE)

---

## Suomeksi

adobe-nuke poistaa Windowsista kaiken Adoben: ohjelmat, palvelut, ajastetut tehtävät, taustaprosessit, Resurssienhallinnan lisäosat, kansiot, pikakuvakkeet, Adobe PDF ‑tulostimen, palomuurisäännöt, rekisterimerkinnät ja välimuistit. Myös Acrobat Reader poistuu. Adoben kansiot poistetaan kokonaisina, joten niiden sisään asennetut kolmannen osapuolen lisäosat (plug-init) poistuvat samalla. `Creative Cloud Files` ‑kansioon ei kosketa.

**Käyttö:** avaa PowerShell ja liitä:

```powershell
irm https://raw.githubusercontent.com/KMzoo/adobe-nuke/main/adobe-nuke.ps1 | iex
```

Skripti pyytää järjestelmänvalvojan oikeudet, näyttää löydetyt kohteet ja odottaa vahvistusta (`k` tai `y`) ennen kuin muuttaa mitään. Vaihtoehtoisesti lataa zip, pura se ja tuplaklikkaa `adobe-nuke.cmd`.

Loki, luettelo rekisterimuutoksista ja rekisterin varmuuskopio tallentuvat Tiedostot-kansioon (Documents) kansioon `adobe-nuke-<päiväys>`.
