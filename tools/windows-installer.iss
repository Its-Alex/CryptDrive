; Build after `flutter build windows --release` in app/: iscc /DAppVersion=0.1.1 tools\windows-installer.iss

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
; The AppId identifies the app across upgrades: never change it.
AppId={{A4077A35-9D1F-4FF2-9CD3-506B86A925DA}
AppName=CryptDrive
AppVersion={#AppVersion}
AppPublisher=CryptDrive
AppPublisherURL=https://github.com/Its-Alex/CryptDrive
AppSupportURL=https://github.com/Its-Alex/CryptDrive/issues
DefaultDirName={autopf}\CryptDrive
DefaultGroupName=CryptDrive
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\app\build
OutputBaseFilename=CryptDrive-windows-x64-setup
SetupIconFile=..\app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\cryptdrive.exe
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "french"; MessagesFile: "compiler:Languages\French.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\app\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\CryptDrive"; Filename: "{app}\cryptdrive.exe"
Name: "{autodesktop}\CryptDrive"; Filename: "{app}\cryptdrive.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\cryptdrive.exe"; Description: "{cm:LaunchProgram,CryptDrive}"; Flags: nowait postinstall skipifsilent
