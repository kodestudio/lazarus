{
 ***************************************************************************
 *                                                                         *
 *   This source is free software; you can redistribute it and/or modify   *
 *   it under the terms of the GNU General Public License as published by  *
 *   the Free Software Foundation; either version 2 of the License, or     *
 *   (at your option) any later version.                                   *
 *                                                                         *
 *   This code is distributed in the hope that it will be useful, but      *
 *   WITHOUT ANY WARRANTY; without even the implied warranty of            *
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU     *
 *   General Public License for more details.                              *
 *                                                                         *
 *   A copy of the GNU General Public License is available on the World    *
 *   Wide Web at <http://www.gnu.org/copyleft/gpl.html>. You can also      *
 *   obtain it by writing to the Free Software Foundation,                 *
 *   Inc., 51 Franklin Street - Fifth Floor, Boston, MA 02110-1335, USA.   *
 *                                                                         *
 ***************************************************************************

 Author: Balázs Székely
 Abstract:
   This unit allows OPM to interact with the Lazarus package system}

unit opkman_intf;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Contnrs, fpjson, dateutils,
  // LCL
  Forms, Dialogs, Controls, ExtCtrls,
  // LazUtils
  LazMethodList,
  // BuildIntf
  PackageIntf, PackageLinkIntf, PackageDependencyIntf,
  // IdeIntf
  LazIDEIntf, IDECommands,
  // OPM
  opkman_downloader, opkman_serializablepackages, opkman_installer, opkman_mainfrm;

type

  { TOPMInterfaceEx }

  TOPMInterfaceEx = class(TOPMInterface)
  private
    FPackagesToDownload: TObjectList;
    FPackagesToInstall: TObjectList;
    FPackageDependecies: TObjectList;
    FPackageLinks: TObjectList;
    FPackageListNotifications: TMethodList;
    FTimer: TTimer;
    FNeedToInit: Boolean;
    procedure DoOnTimer(Sender: TObject);
    procedure DoUpdatePackageLinks(Sender: TObject);
    procedure DoOnIDEClose(Sender: TObject);
    procedure InitOPM;
    procedure SynchronizePackages;
    procedure AddToDownloadList(const AName: String);
    procedure AddToInstallList(const AName: String);
    procedure DoHandleException(Sender: TObject; E: Exception);
    function Download(const ADstDir: String): TModalResult;
    function Extract(const ASrcDir, ADstDir: String; const AIsUpdate: Boolean = False): TModalResult;
    function Install(var AInstallStatus: TInstallStatus; var ANeedToRebuild: Boolean): TModalResult;
    function ResolveDependencies: TModalResult;
    function CanInstallPackages: TModalResult;
  public
    constructor Create;
    destructor Destroy; override;
  public
    function DownloadPackages(APkgLinks: TList): TModalResult; override;
    function InstallPackages(APkgLinks: TList): TModalResult; override;
    function IsPackageAvailable(APkgLink: TPackageLink; AType: Integer): Boolean; override;
    function FindOnlineLink(const AName: String): TPackageLink; override;
    procedure AddPackageListNotification(ANotification: TNotifyEvent); override;
    procedure RemovePackageListNotification(ANotification: TNotifyEvent); override;
    function IsPackageListLoaded: Boolean; override;
    procedure GetPackageList; override;
  end;

implementation

uses opkman_common, opkman_options, opkman_const, opkman_progressfrm, opkman_zipper,
     opkman_intf_PackageListFrm;

{ TOPMInterfaceEx }

constructor TOPMInterfaceEx.Create;
begin
  InitCriticalSection(CriticalSection);
  Application.AddOnExceptionHandler(@DoHandleException);
  FPackageLinks := TObjectList.Create(False);
  FPackagesToDownload := TObjectList.Create(False);
  FPackagesToInstall := TObjectList.Create(False);
  FPackageDependecies := TObjectList.Create(False);
  FPackageListNotifications := TMethodList.Create;
  FNeedToInit := True;
  FTimer := TTimer.Create(nil);
  FTimer.Interval := 50;
  FTimer.OnTimer := @DoOnTimer;
  FTimer.Enabled := True;
end;

destructor TOPMInterfaceEx.Destroy;
begin
  FTimer.Free;
  FPackageListNotifications.Free;
  FPackageLinks.Clear;
  FPackageLinks.Free;
  FPackagesToDownload.Clear;
  FPackagesToDownload.Free;
  FPackagesToInstall.Clear;
  FPackagesToInstall.Free;
  FPackageDependecies.Clear;
  FPackageDependecies.Free;
  PackageDownloader.Free;
  SerializablePackages.Free;
  Options.Free;
  InstallPackageList.Free;
  DoneCriticalsection(CriticalSection);
  inherited Destroy;
end;

procedure TOPMInterfaceEx.DoOnIDEClose(Sender: TObject);
begin
  if Assigned(PackageDownloader) then
    if PackageDownloader.DownloadingJSON then
      PackageDownloader.Cancel;
end;

procedure TOPMInterfaceEx.DoOnTimer(Sender: TObject);
begin
  if Assigned(LazarusIDE) and Assigned(PackageEditingInterface) and (not LazarusIDE.IDEIsClosing) then
  begin
    if FNeedToInit then
    begin
      InitOPM;
      FNeedToInit := False;
      FTimer.Enabled := False;
      FTimer.Interval := 5000;
      FTimer.Enabled := True;
    end
    else
    begin
      FTimer.Enabled := False;
      if (not LazarusIDE.IDEIsClosing) then
      begin
        if (Options.CheckForUpdates <> 5) and (not Assigned(MainFrm)) then
          GetPackageList;
      end;
    end;
  end;
end;

procedure TOPMInterfaceEx.InitOPM;
begin
  InitLocalRepository;
  Options := TOptions.Create(LocalRepositoryConfigFile);
  SerializablePackages := TSerializablePackages.Create;
  SerializablePackages.OnUpdatePackageLinks := @DoUpdatePackageLinks;
  PackageDownloader := TPackageDownloader.Create(Options.RemoteRepository[Options.ActiveRepositoryIndex]);
  InstallPackageList := TObjectList.Create(True);
end;

procedure TOPMInterfaceEx.DoUpdatePackageLinks(Sender: TObject);
begin
  SynchronizePackages;
end;

function TOPMInterfaceEx.FindOnlineLink(const AName: String): TPackageLink;
var
  I: Integer;
  PackageLink: TPackageLink;
begin
  Result := nil;
  for I := 0 to FPackageLinks.Count - 1 do
  begin
    PackageLink := TPackageLink(FPackageLinks.Items[I]);
    if UpperCase(PackageLink.Name) = UpperCase(AName) then
    begin
      Result := PackageLink;
      Break;
    end;
  end;
end;

procedure TOPMInterfaceEx.AddPackageListNotification(ANotification: TNotifyEvent);
begin
  FPackageListNotifications.Add(TMethod(ANotification));
end;

procedure TOPMInterfaceEx.RemovePackageListNotification(ANotification: TNotifyEvent);
begin
  FPackageListNotifications.Remove(TMethod(ANotification));
end;

function TOPMInterfaceEx.IsPackageListLoaded: Boolean;
begin
  Result := Assigned(SerializablePackages) and (SerializablePackages.Count > 0);
end;

procedure TOPMInterfaceEx.GetPackageList;
begin
  PackageDownloader.DownloadJSON(Options.ConTimeOut*1000, True);
  LazarusIDE.AddHandlerOnIDEClose(@DoOnIDEClose);
end;

procedure TOPMInterfaceEx.SynchronizePackages;
var
  I, J: Integer;
  MetaPackage: TMetaPackage;
  LazPackage: TLazarusPackage;
  PackageLink: TPackageLink;
  FileName, Name, URL: String;
begin
  PkgLinks.ClearOnlineLinks;
  FPackageLinks.Clear;
  for I := 0 to SerializablePackages.Count - 1 do
  begin
    MetaPackage := SerializablePackages.Items[I];
    for J := 0 to MetaPackage.LazarusPackages.Count - 1 do
    begin
      LazPackage := TLazarusPackage(MetaPackage.LazarusPackages.Items[J]);
      FileName := Options.LocalRepositoryPackagesExpanded + MetaPackage.PackageBaseDir + LazPackage.PackageRelativePath + LazPackage.Name;
      Name := StringReplace(LazPackage.Name, '.lpk', '', [rfReplaceAll, rfIgnoreCase]);
      URL := Options.RemoteRepository[Options.ActiveRepositoryIndex] + MetaPackage.RepositoryFileName;
      PackageLink := FindOnlineLink(Name);
      if PackageLink = nil then
      begin
        PackageLink := PkgLinks.AddOnlineLink(FileName, Name, URL);
        if PackageLink <> nil then
        begin
          PackageLink.Version.Assign(LazPackage.Version);
          PackageLink.PackageType := LazPackage.PackageType;
          PackageLink.OPMFileDate := MetaPackage.RepositoryDate;
          PackageLink.Author := LazPackage.Author;
          PackageLink.Description := LazPackage.Description;
          PackageLink.License := LazPackage.License;
          FPackageLinks.Add(PackageLink);
        end;
      end;
    end;
  end;
  FPackageListNotifications.CallNotifyEvents(Self);
end;

procedure TOPMInterfaceEx.AddToDownloadList(const AName: String);
var
  I, J: Integer;
  MetaPackage: TMetaPackage;
  LazPackage: TLazarusPackage;
begin
  for I := 0 to SerializablePackages.Count - 1 do
  begin
    MetaPackage := SerializablePackages.Items[I];
    for J := 0 to MetaPackage.LazarusPackages.Count - 1 do
    begin
      LazPackage := TLazarusPackage(MetaPackage.LazarusPackages.Items[J]);
      if UpperCase(LazPackage.Name) = UpperCase(AName) then
      begin
        LazPackage.Checked := True;
        MetaPackage.Checked := True;
        FPackagesToInstall.Add(LazPackage);
        Break;
      end;
    end;
  end;
end;

procedure TOPMInterfaceEx.AddToInstallList(const AName: String);
var
  I, J: Integer;
  MetaPackage: TMetaPackage;
  LazPackage: TLazarusPackage;
begin
  for I := 0 to SerializablePackages.Count - 1 do
  begin
    MetaPackage := SerializablePackages.Items[I];
    for J := 0 to MetaPackage.LazarusPackages.Count - 1 do
    begin
      LazPackage := TLazarusPackage(MetaPackage.LazarusPackages.Items[J]);
      if UpperCase(LazPackage.Name) = UpperCase(AName) then
      begin
        FPackagesToInstall.Add(LazPackage);
        Break;
      end;
    end;
  end;
end;

function TOPMInterfaceEx.ResolveDependencies: TModalResult;
var
  I, J: Integer;
  PackageList: TObjectList;
  PkgFileName: String;
  DependencyPkg: TLazarusPackage;
  MetaPkg: TMetaPackage;
  Msg: String;
begin
  Result := mrNone;
  FPackageDependecies.Clear;
  for I := 0 to FPackagesToInstall.Count - 1 do
  begin
    PackageList := TObjectList.Create(True);
    try
      SerializablePackages.GetPackageDependencies(TLazarusPackage(FPackagesToInstall.Items[I]).Name, PackageList, True, True);
      for J := 0 to PackageList.Count - 1 do
      begin
        PkgFileName := TPackageDependency(PackageList.Items[J]).PkgFileName + '.lpk';
        DependencyPkg := SerializablePackages.FindLazarusPackage(PkgFileName);
        if DependencyPkg <> nil then
        begin
          if (not DependencyPkg.Checked) and
              (UpperCase(TLazarusPackage(FPackagesToInstall.Items[I]).Name) <> UpperCase(PkgFileName)) and
               ((SerializablePackages.IsDependencyOk(TPackageDependency(PackageList.Items[J]), DependencyPkg)) and
                ((not (DependencyPkg.PackageState = psInstalled)) or ((DependencyPkg.PackageState = psInstalled) and (not (SerializablePackages.IsInstalledVersionOk(TPackageDependency(PackageList.Items[J]), DependencyPkg.InstalledFileVersion)))))) then
          begin
            if (Result = mrNone) or (Result = mrYes) then
              begin
                Msg := Format(rsMainFrm_rsPackageDependency0, [TLazarusPackage(FPackagesToInstall.Items[I]).Name, DependencyPkg.Name]);
                Result := MessageDlgEx(Msg, mtConfirmation, [mbYes, mbYesToAll, mbNo, mbNoToAll, mbCancel], nil);
                if Result in [mrNo, mrNoToAll] then
                  if MessageDlgEx(rsMainFrm_rsPackageDependency1, mtInformation, [mbYes, mbNo], nil) <> mrYes then
                    Exit(mrCancel);
                if (Result = mrNoToAll) or (Result = mrCancel) then
                  Exit(mrCancel);
              end;
              if Result in [mrYes, mrYesToAll] then
              begin
                DependencyPkg.Checked := True;
                MetaPkg := SerializablePackages.FindMetaPackageByLazarusPackage(DependencyPkg);
                if MetaPkg <> nil then
                  MetaPkg.Checked := True;
                FPackageDependecies.Add(DependencyPkg);
              end;
          end;
        end;
      end;
    finally
      PackageList.Free;
    end;
  end;
  Result := mrOk;
end;

function TOPMInterfaceEx.CanInstallPackages: TModalResult;
var
  I: Integer;
  LazarusPkg: TLazarusPackage;
  MetaPkg: TMetaPackage;
begin
  Result := mrCancel;
  IntfPackageListFrm := TIntfPackageListFrm.Create(nil);
  try
    IntfPackageListFrm.Position := poWorkAreaCenter;
    IntfPackageListFrm.PopulateTree(FPackagesToInstall);
    IntfPackageListFrm.ShowModal;
    if IntfPackageListFrm.ModalResult = mrOk then
    begin
      for I := FPackagesToInstall.Count - 1 downto 0 do
      begin
        LazarusPkg := TLazarusPackage(FPackagesToInstall.Items[I]);
        if IntfPackageListFrm.IsLazarusPackageChecked(LazarusPkg.Name) then
        begin
          LazarusPkg.Checked := True;
          MetaPkg := SerializablePackages.FindMetaPackageByLazarusPackage(LazarusPkg);
          if MetaPkg <> nil then
            MetaPkg.Checked := True;
        end
        else
          FPackagesToInstall.Delete(I);
      end;
      if FPackagesToInstall.Count > 0 then
        Result := mrOK;
    end;
  finally
    IntfPackageListFrm.Free;
  end;
end;

function TOPMInterfaceEx.Download(const ADstDir: String): TModalResult;
begin
  ProgressFrm := TProgressFrm.Create(nil);
  try
    ProgressFrm.Position := poWorkAreaCenter;
    ProgressFrm.SetupControls(0);
    PackageDownloader.OnPackageDownloadProgress := @ProgressFrm.DoOnPackageDownloadProgress;
    PackageDownloader.OnPackageDownloadError := @ProgressFrm.DoOnPackageDownloadError;
    PackageDownloader.OnPackageDownloadCompleted := @ProgressFrm.DoOnPackageDownloadCompleted;
    PackageDownloader.DownloadPackages(ADstDir);
    Result := ProgressFrm.ShowModal;
  finally
    ProgressFrm.Free;
  end;
end;


function TOPMInterfaceEx.Extract(const ASrcDir, ADstDir: String;
  const AIsUpdate: Boolean): TModalResult;
begin
  ProgressFrm := TProgressFrm.Create(nil);
  try
    ProgressFrm.Position := poWorkAreaCenter;
    ProgressFrm.SetupControls(1);
    PackageUnzipper := TPackageUnzipper.Create;
    try
      PackageUnzipper.OnZipProgress := @ProgressFrm.DoOnZipProgress;
      PackageUnzipper.OnZipError := @ProgressFrm.DoOnZipError;
      PackageUnzipper.OnZipCompleted := @ProgressFrm.DoOnZipCompleted;
      PackageUnzipper.StartUnZip(ASrcDir, ADstDir, AIsUpdate);
      Result := ProgressFrm.ShowModal;
    finally
      if Assigned(PackageUnzipper) then
        PackageUnzipper := nil;
    end;
  finally
    ProgressFrm.Free;
  end;
end;

function TOPMInterfaceEx.Install(var AInstallStatus: TInstallStatus;
  var ANeedToRebuild: Boolean): TModalResult;
begin
  ProgressFrm := TProgressFrm.Create(nil);
  try
    ProgressFrm.Position := poWorkAreaCenter;
    ProgressFrm.SetupControls(2);
    Result := ProgressFrm.ShowModal;
    if Result = mrOk then
    begin
      AInstallStatus := ProgressFrm.InstallStatus;
      ANeedToRebuild := ProgressFrm.NeedToRebuild;
    end;
  finally
    ProgressFrm.Free;
  end;
end;


function TOPMInterfaceEx.InstallPackages(APkgLinks: TList): TModalResult;
// Result can be mrOk, mrCancel, or mrRetry which means the IDE should be rebuilt.
var
  I: Integer;
  InstallStatus: TInstallStatus;
  ANeedToRebuild: Boolean;
begin
  FPackagesToInstall.Clear;
  for I := 0 to APkgLinks.Count - 1 do
    AddToInstallList(TPackageLink(APkgLinks.Items[I]).Name + '.lpk');

  Result := CanInstallPackages;
  if Result = mrCancel then
    Exit;

  Result := ResolveDependencies;
  if Result = mrCancel then
     Exit;
  for I := 0 to FPackageDependecies.Count - 1 do
    FPackagesToInstall.Insert(0, FPackageDependecies.Items[I]);

  PackageAction := paInstall;
  if SerializablePackages.DownloadCount > 0 then
  begin
    Result := Download(Options.LocalRepositoryArchiveExpanded);
    SerializablePackages.GetPackageStates;
  end;

  if Result = mrOk then
  begin
    if SerializablePackages.ExtractCount > 0 then
    begin
      Result := Extract(Options.LocalRepositoryArchiveExpanded, Options.LocalRepositoryPackagesExpanded);
      SerializablePackages.GetPackageStates;
    end;

    if Result = mrOk then
    begin
      if Options.DeleteZipAfterInstall then
        SerializablePackages.DeleteDownloadedZipFiles;
      if SerializablePackages.InstallCount > 0 then
      begin
        InstallStatus := isFailed;
        ANeedToRebuild := False;
        Result := Install(InstallStatus, ANeedToRebuild);
        if Result = mrOk then
        begin
          SerializablePackages.MarkRuntimePackages;
          SerializablePackages.GetPackageStates;
          if ANeedToRebuild
          and ((InstallStatus = isSuccess) or (InstallStatus = isPartiallyFailed))
          and (MessageDlgEx(rsOPMInterfaceRebuildConf,mtConfirmation,[mbYes,mbNo], nil) = mrYes)
          then
            Result := mrRetry;
        end;
      end;
    end;
  end;
  SerializablePackages.RemoveErrorState;
  SerializablePackages.RemoveCheck;
end;

function TOPMInterfaceEx.DownloadPackages(APkgLinks: TList): TModalResult;
var
  I: Integer;
  Name: String;
  PkgLink: TPackageLink;
begin
  Result := mrCancel;

  FPackagesToDownload.Clear;
  for I := 0 to APkgLinks.Count - 1 do
    AddToDownloadList(TPackageLink(APkgLinks.Items[I]).Name + '.lpk');

  Result := ResolveDependencies;
  if Result = mrCancel then
     Exit;
  for I := 0 to FPackageDependecies.Count - 1 do
    FPackagesToDownload.Insert(0, FPackageDependecies.Items[I]);

  PackageAction := paInstall;
  if SerializablePackages.DownloadCount > 0 then
  begin
    Result := Download(Options.LocalRepositoryArchiveExpanded);
    SerializablePackages.GetPackageStates;
  end;

  if Result = mrOk then
  begin
    if SerializablePackages.ExtractCount > 0 then
    begin
      Result := Extract(Options.LocalRepositoryArchiveExpanded, Options.LocalRepositoryPackagesExpanded);
      SerializablePackages.GetPackageStates;
    end;

    if Result = mrOk then
    begin
      if Options.DeleteZipAfterInstall then
        SerializablePackages.DeleteDownloadedZipFiles;
      for I := 0 to FPackageDependecies.Count - 1 do
      begin
        Name := StringReplace(TLazarusPackage(FPackageDependecies.Items[I]).Name, '.lpk', '', [rfReplaceAll, rfIgnoreCase]);
        PkgLink := FindOnlineLink(Name);
        if PkgLink <> nil then
        begin
          PkgLinks.AddUserLink(TLazarusPackage(FPackageDependecies.Items[I]).PackageAbsolutePath, Name);
          PkgLinks.SaveUserLinks(True);
        end;
      end;
    end;
  end;
  SerializablePackages.RemoveErrorState;
  SerializablePackages.RemoveCheck;
end;

function TOPMInterfaceEx.IsPackageAvailable(APkgLink: TPackageLink; AType: Integer): Boolean;
var
  LazPackage: TLazarusPackage;
begin
  Result := False;
  LazPackage := SerializablePackages.FindLazarusPackage(APkgLink.Name + '.lpk');
  if LazPackage <> nil then
  begin
    case AType of
      0: Result := psDownloaded in LazPackage.PackageStates;
      1: Result := psExtracted in LazPackage.PackageStates;
      2: Result := psInstalled in LazPackage.PackageStates;
    end;
  end;
end;

procedure TOPMInterfaceEx.DoHandleException(Sender: TObject; E: Exception);
begin
  //
end;


end.
