[CmdletBinding()]
param()
$ErrorActionPreference = "Stop"

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$PowerShellExe = (Get-Process -Id $PID).Path
$StorageScript = Join-Path $Root "scripts\local-storage.ps1"
$ShellScript = Join-Path $Root "scripts\local-storage.sh"
$SchemaPath = Join-Path $Root "config\solver-artifact-manifest-v1.schema.json"
$DocsPath = Join-Path $Root "docs\local-development-storage.md"
$Work = Join-Path ([IO.Path]::GetTempPath()) ("fca-local-storage-contract." + [Guid]::NewGuid().ToString("N"))

function Fail([string]$Message) { throw "LOCAL_STORAGE_CONTRACT_FAIL: $Message" }
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { Fail $Message } }
function Assert-Bytes([string]$Path, [byte[]]$Expected, [string]$Message) {
  $actual = [IO.File]::ReadAllBytes($Path)
  Assert-True (($actual.Length -eq $Expected.Length) -and -not (Compare-Object $actual $Expected)) $Message
}
function New-Fixture([string]$Name) {
  $path = Join-Path $Work $Name
  [void](New-Item -ItemType Directory -Path (Join-Path $path "config") -Force)
  Copy-Item -LiteralPath (Join-Path $Root ".gitignore") -Destination (Join-Path $path ".gitignore")
  Copy-Item -LiteralPath $SchemaPath -Destination (Join-Path $path "config\solver-artifact-manifest-v1.schema.json")
  return $path
}
function Invoke-Storage([string]$RepositoryRoot, [string]$Action, [string]$ReplayPath = "", [bool]$ShouldPass = $true) {
  $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $StorageScript, "-Action", $Action, "-RepositoryRoot", $RepositoryRoot)
  if ($ReplayPath) { $arguments += @("-ReplayStorePath", $ReplayPath) }
  $oldPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $output = & $PowerShellExe @arguments 2>&1
  $code = $LASTEXITCODE
  $ErrorActionPreference = $oldPreference
  if ($ShouldPass -and $code -ne 0) { Fail "$Action unexpectedly failed: $($output -join ' | ')" }
  if (-not $ShouldPass -and $code -eq 0) { Fail "$Action unexpectedly accepted unsafe state" }
}
function Assert-Ignored([string]$RelativePath) {
  & git -C $Root check-ignore --quiet -- $RelativePath
  if ($LASTEXITCODE -ne 0) { Fail "$RelativePath is not ignored" }
}

$required = @($StorageScript, $ShellScript, $SchemaPath, $DocsPath)
$missing = @($required | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
if ($missing.Count -ne 0) { Fail ("implementation missing: " + (($missing | ForEach-Object { Split-Path $_ -Leaf }) -join ", ")) }

[void](New-Item -ItemType Directory -Path $Work -Force)
try {
  $envText = [IO.File]::ReadAllText((Join-Path $Root ".env.example"))
  $configText = [IO.File]::ReadAllText((Join-Path $Root "config\runtime_config.ml"))
  Assert-True ($envText.Contains("REPLAY_STORE_PATH=./data/replays/replay.duckdb")) ".env.example durable replay path missing"
  Assert-True ($configText.Contains('~default:"./data/replays/replay.duckdb"')) "runtime default durable replay path missing"

  foreach ($path in @(
    "data/replays/replay.duckdb",
    "data/replays/replay.duckdb.wal",
    "data/replays/datasets/incoming/operator.csv",
    "data/replays/datasets/frozen/00000000-0000-4000-8000-000000000001/manifest.json",
    "data/replays/datasets/work/00000000-0000-4000-8000-000000000002/result.parquet",
    "data/solver-artifacts/FORMAT_VERSION",
    "data/solver-artifacts/v1/00000000-0000-4000-8000-000000000001/00000000-0000-4000-8000-000000000002/manifest.json"
  )) { Assert-Ignored $path }
  $trackedData = @(& git -C $Root ls-files -- data)
  Assert-True ($trackedData.Count -eq 0) "runtime data is tracked"
  $untrackedData = @(& git -C $Root status --porcelain --untracked-files=all -- data)
  Assert-True ($untrackedData.Count -eq 0) "contract test must not create canonical runtime data"

  $schema = Get-Content -LiteralPath $SchemaPath -Raw | ConvertFrom-Json
  Assert-True ($schema.'$schema' -eq "https://json-schema.org/draft/2020-12/schema") "schema draft is not pinned"
  Assert-True ($schema.additionalProperties -eq $false) "manifest must reject undeclared top-level fields"
  Assert-True ($schema.properties.format_version.const -eq 1) "manifest format version is not exact"
  Assert-True ($schema.properties.files.maxItems -le 32) "manifest inventory is not bounded"
  Assert-True ($schema.properties.files.items.additionalProperties -eq $false) "file entries must reject undeclared fields"
  $pathPattern = [regex]::new($schema.properties.files.items.properties.path.pattern)
  foreach ($safe in @("input.json", "model.mzn", "stdout.bin")) { Assert-True ($pathPattern.IsMatch($safe)) "safe manifest path rejected: $safe" }
  foreach ($unsafe in @("../input.json", "/tmp/input.json", "C:\input.json", "nested/input.json", "nested\input.json")) { Assert-True (-not $pathPattern.IsMatch($unsafe)) "unsafe manifest path accepted: $unsafe" }

  $fixture = New-Fixture "primary repository"
  Invoke-Storage $fixture "verify" "" $false
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture "data"))) "verify created missing storage"
  Invoke-Storage $fixture "init"
  $expectedDirectories = @(
    "data", "data\replays", "data\replays\datasets", "data\replays\datasets\incoming",
    "data\replays\datasets\frozen", "data\replays\datasets\work",
    "data\solver-artifacts", "data\solver-artifacts\v1"
  )
  foreach ($relative in $expectedDirectories) { Assert-True (Test-Path -LiteralPath (Join-Path $fixture $relative) -PathType Container) "missing directory $relative" }
  $version = Join-Path $fixture "data\solver-artifacts\FORMAT_VERSION"
  Assert-Bytes $version ([byte[]](0x31, 0x0A)) "FORMAT_VERSION must contain exact LF-terminated version 1"

  $sentinel = Join-Path $fixture "data\replays\datasets\incoming\operator-sentinel.bin"
  [IO.File]::WriteAllBytes($sentinel, [byte[]](0, 1, 2, 3, 254, 255))
  $sentinelHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sentinel).Hash
  Invoke-Storage $fixture "init"
  Assert-True ((Get-FileHash -Algorithm SHA256 -LiteralPath $sentinel).Hash -eq $sentinelHash) "idempotent init changed operator data"
  Invoke-Storage $fixture "verify"

  [IO.File]::WriteAllBytes($version, [byte[]](0x32, 0x0A))
  Invoke-Storage $fixture "verify" "" $false
  Invoke-Storage $fixture "init" "" $false
  Assert-Bytes $version ([byte[]](0x32, 0x0A)) "init overwrote an incompatible format version"

  foreach ($unsafePath in @("../outside.duckdb", "./data/replays/../escape.duckdb", "./data/other.duckdb", (Join-Path $Work "absolute.duckdb"))) {
    $unsafeFixture = New-Fixture ("unsafe-" + [Guid]::NewGuid().ToString("N"))
    Invoke-Storage $unsafeFixture "init" $unsafePath $false
  }
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $Work "absolute.duckdb"))) "unsafe absolute replay target was created"

  $linkFixture = New-Fixture "reparse repository"
  [void](New-Item -ItemType Directory -Path (Join-Path $linkFixture "data") -Force)
  $outside = Join-Path $Work "outside reparse target"
  [void](New-Item -ItemType Directory -Path $outside -Force)
  [void](New-Item -ItemType Junction -Path (Join-Path $linkFixture "data\replays") -Target $outside)
  Invoke-Storage $linkFixture "init" "" $false
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $outside "datasets"))) "reparse traversal wrote outside repository storage"

  $aclFixture = New-Fixture "acl repository"
  Invoke-Storage $aclFixture "init"
  & icacls (Join-Path $aclFixture "data") /grant '*S-1-1-0:(OI)(CI)M' /Q | Out-Null
  if ($LASTEXITCODE -ne 0) { Fail "could not create broad-write ACL adversarial fixture" }
  Invoke-Storage $aclFixture "verify" "" $false

  Write-Output "LOCAL_STORAGE_CONTRACT_PASS directories=8 unsafe_paths=4 reparse=reject broad_write=reject version=1"
}
finally {
  if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue }
}
