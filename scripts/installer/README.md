# Windows installer

Compile using Inno Setup 6.7.3 or a compatible newer version:

```powershell
pwsh -File scripts/build_windows_installer.ps1 -IsccPath 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe'
```

The complete Flutter Windows release bundle must already exist. This packaging
step does not rebuild application code. It requires the GPL license, usage guide,
and third-party licenses alongside the release binaries, then writes an EXE and
SHA-256 file into `dist/`. Installation is per-user, has no automatic startup,
and its uninstall log only covers installed application files and shortcuts.
User books and settings remain outside the installation directory.

`ChineseSimplified.isl` is the unmodified translation by Zhenghan Yang (Kira),
retrieved from the official Inno Setup source repository:
<https://github.com/jrsoftware/issrc/blob/main/Files/Languages/ChineseSimplified.isl>.
Its attribution is retained in the file; the Inno Setup license is included as
`LICENSE.InnoSetup.txt`.
