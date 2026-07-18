; Inno Setup script for Gravity Music — builds a single-file Windows installer
; (gravity-music-<version>-setup.exe) from the Flutter Windows release runner.
;
; Compiled in CI (windows-latest) by ISCC after `flutter build windows --release`:
;   iscc /DAppVersion=1.3.3 windows\packaging\gravity-music.iss
; The version is injected from CI; a local/manual compile falls back to 0.0.0.
;
; Per-user install (no admin/UAC): the app is unsigned/sideloaded, and
; installing under %LOCALAPPDATA%\Programs avoids the elevation prompt. The
; produced setup.exe is itself unsigned, so SmartScreen shows a one-time
; "unknown publisher" warning (More info -> Run anyway) — same trust tradeoff
; as the self-signed MSIX.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

#define AppName "Gravity Music"
#define AppPublisher "Gravity Music"
; The Flutter build produces "saraharmony.exe" (BINARY_NAME in
; windows/CMakeLists.txt); the installer ships it renamed to this. Safe —
; a Flutter Windows app locates its data\ folder by the executable's
; DIRECTORY, not its filename.
#define AppSrcExe "saraharmony.exe"
#define AppExe "Gravity Music.exe"

[Setup]
; Stable, app-unique GUID — do NOT change once released (upgrades key off it).
AppId={{A7E6C9D2-3B14-4F8A-9C2E-6D5B1A0F4E33}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={localappdata}\Programs\{#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\..\dist
OutputBaseFilename=gravity-music-{#AppVersion}-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; The runner exe, renamed to "Gravity Music.exe".
Source: "..\..\build\windows\x64\runner\Release\{#AppSrcExe}"; DestDir: "{app}"; DestName: "{#AppExe}"; Flags: ignoreversion
; Everything else (*.dll + data\ assets/icudtl.dat), excluding the exe handled
; above. recursesubdirs pulls in the data\ folder tree.
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Excludes: "{#AppSrcExe}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
