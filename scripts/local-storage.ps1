[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("init", "verify")]
  [string]$Action,
  [string]$RepositoryRoot = "",
  [string]$ReplayStorePath = "./data/replays/replay.duckdb"
)
$ErrorActionPreference = "Stop"

function Fail([string]$Code, [int]$ExitCode = 1) {
  [Console]::Error.WriteLine("LOCAL_STORAGE_ERROR $Code")
  exit $ExitCode
}
function Assert-NoReparsePoint([string]$Path) {
  if (Test-Path -LiteralPath $Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Fail "REPARSE_COMPONENT_REJECTED" 3 }
  }
}
function Assert-PrivateAcl([string]$Path) {
  $acl = Get-Acl -LiteralPath $Path
  if (-not $acl.AreAccessRulesProtected) { Fail "ACL_INHERITANCE_UNSAFE" 5 }
  $broadSids = @("S-1-1-0", "S-1-5-11", "S-1-5-32-545")
  $writeMask = [Security.AccessControl.FileSystemRights]::Write -bor
    [Security.AccessControl.FileSystemRights]::Modify -bor
    [Security.AccessControl.FileSystemRights]::FullControl -bor
    [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
    [Security.AccessControl.FileSystemRights]::TakeOwnership
  foreach ($rule in $acl.Access) {
    try { $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { $sid = "" }
    if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
        $broadSids -contains $sid -and (($rule.FileSystemRights -band $writeMask) -ne 0)) {
      Fail "ACL_BROAD_WRITE_REJECTED" 5
    }
  }
}
function Set-PrivateAcl([string]$Path, [bool]$Directory) {
  $current = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $inheritance = if ($Directory) { "(OI)(CI)F" } else { "F" }
  & icacls $Path /inheritance:r /grant:r "*${current}:${inheritance}" "*S-1-5-18:${inheritance}" "*S-1-5-32-544:${inheritance}" /Q | Out-Null
  if ($LASTEXITCODE -ne 0) { Fail "ACL_APPLY_FAILED" 5 }
  Assert-PrivateAcl $Path
}
function Ensure-Directory([string]$Path) {
  if (Test-Path -LiteralPath $Path) {
    Assert-NoReparsePoint $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Fail "DIRECTORY_PATH_OCCUPIED" 3 }
  } else {
    [void](New-Item -ItemType Directory -Path $Path)
  }
  Assert-NoReparsePoint $Path
  Set-PrivateAcl $Path $true
}
function Assert-Directory([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Fail "DIRECTORY_MISSING" 4 }
  Assert-NoReparsePoint $Path
  Assert-PrivateAcl $Path
}
function Assert-PrivateFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Fail "FILE_MISSING" 4 }
  Assert-NoReparsePoint $Path
  Assert-PrivateAcl $Path
}

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { $RepositoryRoot = Join-Path $PSScriptRoot ".." }
if (-not (Test-Path -LiteralPath $RepositoryRoot -PathType Container)) { Fail "REPOSITORY_ROOT_INVALID" 3 }
Assert-NoReparsePoint $RepositoryRoot
$Root = (Resolve-Path -LiteralPath $RepositoryRoot).Path
if (-not (Test-Path -LiteralPath (Join-Path $Root ".gitignore") -PathType Leaf)) { Fail "REPOSITORY_MARKER_MISSING" 3 }
$schema = Join-Path $Root "config\solver-artifact-manifest-v1.schema.json"
if (-not (Test-Path -LiteralPath $schema -PathType Leaf)) { Fail "MANIFEST_SCHEMA_MISSING" 4 }
Assert-NoReparsePoint $schema
$ignoreText = [IO.File]::ReadAllText((Join-Path $Root ".gitignore"))
if ($ignoreText -notmatch '(?m)^\s*data/\s*$') { Fail "DATA_IGNORE_RULE_MISSING" 3 }
if ($ReplayStorePath -notmatch '^\./data/replays/[A-Za-z0-9][A-Za-z0-9._-]*\.duckdb$') { Fail "REPLAY_STORE_PATH_UNSAFE" 3 }

$data = Join-Path $Root "data"
$replays = Join-Path $data "replays"
$datasets = Join-Path $replays "datasets"
$solver = Join-Path $data "solver-artifacts"
$version = Join-Path $solver "FORMAT_VERSION"
$directories = @(
  $data,
  $replays,
  $datasets,
  (Join-Path $datasets "incoming"),
  (Join-Path $datasets "frozen"),
  (Join-Path $datasets "work"),
  $solver,
  (Join-Path $solver "v1")
)

if ($Action -eq "init") {
  foreach ($directory in $directories) { Ensure-Directory $directory }
  if (Test-Path -LiteralPath $version) {
    Assert-NoReparsePoint $version
    if (-not (Test-Path -LiteralPath $version -PathType Leaf)) { Fail "FORMAT_VERSION_NOT_REGULAR" 3 }
  } else {
    $temporary = Join-Path $solver (".FORMAT_VERSION.tmp." + [Guid]::NewGuid().ToString("N"))
    try {
      [IO.File]::WriteAllBytes($temporary, [byte[]](0x31, 0x0A))
      Set-PrivateAcl $temporary $false
      [IO.File]::Move($temporary, $version)
    } catch {
      if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
      if (-not (Test-Path -LiteralPath $version -PathType Leaf)) { Fail "FORMAT_VERSION_CREATE_FAILED" 5 }
    }
  }
  Set-PrivateAcl $version $false
}

foreach ($directory in $directories) { Assert-Directory $directory }
Assert-PrivateFile $version
$bytes = [IO.File]::ReadAllBytes($version)
if ($bytes.Length -ne 2 -or $bytes[0] -ne 0x31 -or $bytes[1] -ne 0x0A) { Fail "FORMAT_VERSION_INCOMPATIBLE" 5 }
Write-Output "LOCAL_STORAGE_OK action=$Action replay_store_path=$ReplayStorePath format_version=1"
