; Antgrid Windows installer (Inno Setup 6).
;
; AppId is PERMANENT — never change it. Inno keys upgrade/uninstall detection off
; it; a new GUID would orphan every existing install (side-by-side instead of
; replace). Per-user install, no admin (matches the scope silent auto-update needs).
;
; AppVersion, SourceDir, and the output dir are supplied by CI:
;   ISCC /DAppVersion=1.2.3 /DSourceDir=<abs path to runner\Release> /O<abs out dir> antgrid.iss
; Relative Source/SetupIconFile/OutputDir are resolved from THIS script's folder,
; not the shell cwd — so CI passes absolute paths for the build output and the
; artifact destination.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif

[Setup]
AppId={{E3BA53C8-F767-4B06-9464-869061ADB321}
AppName=Antgrid
AppVersion={#AppVersion}
AppPublisher=Radha AI
AppPublisherURL=https://antgrid.ai
DefaultDirName={localappdata}\Programs\Antgrid
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\antgrid.exe
OutputDir=.
OutputBaseFilename=antgrid-windows-setup
CloseApplications=yes
ChangesAssociations=yes
Compression=lzma2
SolidCompression=yes

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Drops the runner folder verbatim (antgrid.exe, antgrid-bridge.exe,
; crashpad_handler.exe, runtime DLLs, native_assets.json, data\) minus the
; dev-only build artifacts the plain zip shipped by accident.
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion; Excludes: "*.pdb,*.lib,*.exp"

[Icons]
Name: "{autoprograms}\Antgrid"; Filename: "{app}\antgrid.exe"
Name: "{autodesktop}\Antgrid"; Filename: "{app}\antgrid.exe"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Classes\antgrid"; ValueType: string; ValueName: ""; ValueData: "URL:Antgrid Protocol"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\antgrid"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\antgrid\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\antgrid.exe"" ""%1"""

[Run]
Filename: "{app}\antgrid.exe"; Description: "{cm:LaunchProgram,Antgrid}"; Flags: nowait postinstall skipifsilent
