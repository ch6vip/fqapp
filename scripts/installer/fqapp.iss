; Community Windows port of ch6vip/fqapp. All application licenses ship in {app}.
#ifndef BundleDir
  #error BundleDir must point to the complete Windows release bundle.
#endif
#ifndef RepoRoot
  #error RepoRoot must point to the source checkout.
#endif
#ifndef OutputDir
  #error OutputDir must point to the installer output directory.
#endif
#ifndef AppVersion
  #define AppVersion "1.1.1"
#endif

[Setup]
AppId={{3BE7E59C-6708-48D1-A16A-6AB902242439}
AppName=番茄小铺 · 电脑版
AppVersion={#AppVersion}
AppVerName=番茄小铺 · 电脑版 {#AppVersion}
AppPublisher=ch6vip / fqapp desktop contributors
AppPublisherURL=https://github.com/ch6vip/fqapp
AppSupportURL=https://github.com/ch6vip/fqapp
AppCopyright=Copyright (C) 2026 ch6vip and fqapp desktop contributors. GPL-3.0.
DefaultDirName={localappdata}\Programs\fqapp Desktop
DefaultGroupName=番茄小铺电脑版
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
WizardStyle=modern
SetupIconFile={#RepoRoot}\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\fqapp.exe
UninstallDisplayName=番茄小铺 · 电脑版
LicenseFile={#RepoRoot}\LICENSE
InfoAfterFile={#RepoRoot}\scripts\installer\安装说明.txt
OutputDir={#OutputDir}
OutputBaseFilename=fqapp-desktop-{#AppVersion}-windows-x64-setup
Compression=lzma2
SolidCompression=yes
CloseApplications=yes
RestartApplications=no
SetupLogging=yes

[Languages]
Name: "chinesesimp"; MessagesFile: "ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "快捷方式："; Flags: unchecked

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Excludes: "*.pdb"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\番茄小铺电脑版"; Filename: "{app}\fqapp.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\番茄小铺电脑版"; Filename: "{app}\fqapp.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\fqapp.exe"; Description: "运行番茄小铺电脑版"; Flags: nowait postinstall skipifsilent
