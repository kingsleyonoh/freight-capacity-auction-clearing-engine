[CmdletBinding()]
param([string]$ArtifactRoot = "")
$ErrorActionPreference = "Stop"

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$ComposeFile = Join-Path $Root "docker-compose.yml"
$StorageScript = Join-Path $Root "scripts\local-storage.ps1"
$PowerShellExe = (Get-Process -Id $PID).Path
$stamp = [DateTime]::UtcNow.ToString("yyyyMMddHHmmss")
$project = "fca-storage-it-$stamp-$PID"
if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) { $ArtifactRoot = Join-Path ([IO.Path]::GetTempPath()) $project }
$HostFixture = Join-Path ([IO.Path]::GetTempPath()) ("$project-host")
[void](New-Item -ItemType Directory -Path $ArtifactRoot -Force)

function Fail([string]$Message) { throw "LOCAL_STORAGE_PERSISTENCE_FAIL: $Message" }
function Compose([string[]]$Arguments) {
  $oldPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $output = & docker compose --project-name $project --file $ComposeFile @Arguments 2>&1
  $code = $LASTEXITCODE
  $ErrorActionPreference = $oldPreference
  if ($code -ne 0) { Fail "compose command failed: $($Arguments -join ' ') :: $($output -join ' | ')" }
  return @($output)
}
function Assert-Equal([string]$Expected, [object]$Actual, [string]$Message) {
  $text = (@($Actual) -join "`n").Trim()
  if ($text -ne $Expected) { Fail "$Message expected=$Expected actual=$text" }
}
function Volume-Label([string]$Name) {
  $labelJson = & docker volume inspect $Name --format '{{json .Labels}}' 2>$null
  if ($LASTEXITCODE -ne 0) { return "" }
  try { return ((@($labelJson) -join "") | ConvertFrom-Json).'com.docker.compose.project' } catch { return "" }
}
function Remove-Owned-Volume([string]$Name) {
  $label = Volume-Label $Name
  if ($label -ne $project) { Fail "refusing to remove volume without exact test-project label: $Name" }
  & docker volume rm $Name | Out-Null
  if ($LASTEXITCODE -ne 0) { Fail "could not remove owned volume: $Name" }
}
function Project-Resources() {
  return @{
    containers = @(& docker ps -aq --filter "label=com.docker.compose.project=$project")
    networks = @(& docker network ls -q --filter "label=com.docker.compose.project=$project")
    volumes = @(& docker volume ls -q --filter "label=com.docker.compose.project=$project")
  }
}
function Assert-Host-Hashes([hashtable]$Expected) {
  foreach ($path in $Expected.Keys) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Fail "host-backed file disappeared: $path" }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
    if ($actual -ne $Expected[$path]) { Fail "host-backed file changed during Compose lifecycle: $path" }
  }
}
function Save-Safe-Json([hashtable]$Value) {
  $Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $ArtifactRoot "persistence-result.json") -Encoding UTF8
}

if (-not (Test-Path -LiteralPath $StorageScript -PathType Leaf)) { Fail "host initializer is missing" }
$managed = @("COMPOSE_PROJECT_NAME", "POSTGRES_DB", "POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_HOST_PORT", "REDIS_HOST_PORT")
$prior = @{}
foreach ($name in $managed) { $prior[$name] = [Environment]::GetEnvironmentVariable($name, "Process") }
$env:COMPOSE_PROJECT_NAME = $project
$env:POSTGRES_DB = "storage_it"
$env:POSTGRES_USER = "storage_it"
$env:POSTGRES_PASSWORD = "local-disposable-$stamp-$PID"
$env:POSTGRES_HOST_PORT = "0"
$env:REDIS_HOST_PORT = "0"
$postgresVolume = "${project}_postgres_data"
$redisVolume = "${project}_redis_data"
$completed = $false

try {
  & docker version --format '{{.Server.Version}}' | Out-Null
  if ($LASTEXITCODE -ne 0) { Fail "Docker engine unavailable" }
  & docker image inspect postgres:16-alpine --format '{{.Id}}' | Out-Null
  if ($LASTEXITCODE -ne 0) { Fail "cached postgres:16-alpine image unavailable" }
  & docker image inspect redis:7-alpine --format '{{.Id}}' | Out-Null
  if ($LASTEXITCODE -ne 0) { Fail "cached redis:7-alpine image unavailable" }

  [void](New-Item -ItemType Directory -Path (Join-Path $HostFixture "config") -Force)
  Copy-Item -LiteralPath (Join-Path $Root ".gitignore") -Destination (Join-Path $HostFixture ".gitignore")
  Copy-Item -LiteralPath (Join-Path $Root "config\solver-artifact-manifest-v1.schema.json") -Destination (Join-Path $HostFixture "config\solver-artifact-manifest-v1.schema.json")
  & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $StorageScript -Action init -RepositoryRoot $HostFixture | Out-Null
  if ($LASTEXITCODE -ne 0) { Fail "host initializer failed" }

  $tenant = "00000000-0000-4000-8000-000000000001"
  $job = "00000000-0000-4000-8000-000000000002"
  $solverJob = Join-Path $HostFixture "data\solver-artifacts\v1\$tenant\$job"
  [void](New-Item -ItemType Directory -Path $solverJob -Force)
  $hostFiles = @(
    (Join-Path $HostFixture "data\replays\replay.duckdb"),
    (Join-Path $HostFixture "data\replays\datasets\frozen\dataset-sentinel.bin"),
    (Join-Path $solverJob "manifest.json"),
    (Join-Path $solverJob "output.json")
  )
  [void](New-Item -ItemType Directory -Path (Split-Path $hostFiles[1] -Parent) -Force)
  [IO.File]::WriteAllBytes($hostFiles[0], [byte[]](0x44,0x55,0x43,0x4B,0x44,0x42))
  [IO.File]::WriteAllBytes($hostFiles[1], [byte[]](0,1,2,3,254,255))
  [IO.File]::WriteAllText($hostFiles[2], '{"format_version":1,"persistence_probe":true}', [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($hostFiles[3], '{"status":"probe"}', [Text.UTF8Encoding]::new($false))
  $hostHashes = @{}
  foreach ($path in $hostFiles) { $hostHashes[$path] = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash }

  $services = Compose @("config", "--services") | Sort-Object
  $volumes = Compose @("config", "--volumes") | Sort-Object
  Assert-Equal "postgres`nredis" $services "development services changed"
  Assert-Equal "postgres_data`nredis_data" $volumes "development volumes changed or unused host volumes were added"
  Compose @("config", "--quiet") | Out-Null

  Compose @("up", "-d", "--pull", "never", "--wait", "--wait-timeout", "90", "postgres", "redis") | Out-Null
  Compose @("exec", "-T", "postgres", "psql", "-U", "storage_it", "-d", "storage_it", "-v", "ON_ERROR_STOP=1", "-c", "CREATE TABLE persistence_probe (id integer PRIMARY KEY, value text NOT NULL); INSERT INTO persistence_probe VALUES (1, 'postgres-persistence-proof');") | Out-Null
  Compose @("exec", "-T", "redis", "redis-cli", "SET", "fca:persistence:probe", "redis-persistence-proof") | Out-Null

  $pgMode = Compose @("exec", "-T", "postgres", "sh", "-ec", "stat -c '%U:%G %a' /var/lib/postgresql/data")
  $redisMode = Compose @("exec", "-T", "redis", "sh", "-ec", "stat -c '%U:%G %a' /data")
  Assert-Equal "postgres:postgres 700" $pgMode "PostgreSQL data ownership/mode changed"
  Assert-Equal "redis:redis 755" $redisMode "Redis data ownership/mode changed"
  $redisConfig = Compose @("exec", "-T", "redis", "redis-cli", "--raw", "CONFIG", "GET", "appendonly", "appendfsync", "save")
  $redisConfigText = (@($redisConfig) -join "`n")
  foreach ($required in @("appendonly", "yes", "appendfsync", "everysec", "save", "60 1")) {
    if (-not $redisConfigText.Contains($required)) { Fail "Redis persistence setting missing: $required" }
  }

  Compose @("restart", "postgres", "redis") | Out-Null
  $pgAfterRestart = Compose @("exec", "-T", "postgres", "psql", "-U", "storage_it", "-d", "storage_it", "-Atc", "SELECT value FROM persistence_probe WHERE id = 1;")
  $redisAfterRestart = Compose @("exec", "-T", "redis", "redis-cli", "--raw", "GET", "fca:persistence:probe")
  Assert-Equal "postgres-persistence-proof" $pgAfterRestart "PostgreSQL value did not survive restart"
  Assert-Equal "redis-persistence-proof" $redisAfterRestart "Redis value did not survive restart"
  Assert-Host-Hashes $hostHashes

  Compose @("down", "--remove-orphans") | Out-Null
  if ((Volume-Label $postgresVolume) -ne $project -or (Volume-Label $redisVolume) -ne $project) { Fail "down without -v did not preserve exact owned volumes" }
  Assert-Host-Hashes $hostHashes

  Compose @("up", "-d", "--pull", "never", "--wait", "--wait-timeout", "90", "postgres", "redis") | Out-Null
  $pgAfterDown = Compose @("exec", "-T", "postgres", "psql", "-U", "storage_it", "-d", "storage_it", "-Atc", "SELECT value FROM persistence_probe WHERE id = 1;")
  $redisAfterDown = Compose @("exec", "-T", "redis", "redis-cli", "--raw", "GET", "fca:persistence:probe")
  Assert-Equal "postgres-persistence-proof" $pgAfterDown "PostgreSQL value did not survive down without -v"
  Assert-Equal "redis-persistence-proof" $redisAfterDown "Redis value did not survive down without -v"
  Assert-Host-Hashes $hostHashes

  Compose @("down", "--remove-orphans") | Out-Null
  Remove-Owned-Volume $postgresVolume
  Remove-Owned-Volume $redisVolume
  $remaining = Project-Resources
  if ($remaining.containers.Count -or $remaining.networks.Count -or $remaining.volumes.Count) { Fail "test-owned Docker resources leaked" }

  Save-Safe-Json @{
    status = "pass"
    project = $project
    cachedImagesOnly = $true
    composeVolumes = @("postgres_data", "redis_data")
    hostStorage = @{ duckdb = "pass-byte-identical"; solverArtifacts = "pass-byte-identical"; initializer = "pass" }
    postgres = @{ restart = "pass"; downWithoutVolumes = "pass"; ownerMode = "postgres:postgres 700" }
    redis = @{ restart = "pass"; downWithoutVolumes = "pass"; ownerMode = "redis:redis 755"; appendOnly = "yes"; appendFsync = "everysec"; save = "60 1" }
    cleanup = "pass-exact-label-verified-owned-resources"
  }
  $completed = $true
  Write-Output "LOCAL_STORAGE_PERSISTENCE_PASS artifact=$(Join-Path $ArtifactRoot 'persistence-result.json')"
}
finally {
  $cleanupPreference = $ErrorActionPreference
  $ErrorActionPreference = "SilentlyContinue"
  if (Test-Path -LiteralPath $ComposeFile -PathType Leaf) { & docker compose --project-name $project --file $ComposeFile down --remove-orphans *> $null }
  if (-not $completed) {
    foreach ($name in @($postgresVolume, $redisVolume)) {
      if ((Volume-Label $name) -eq $project) { & docker volume rm $name *> $null }
    }
  }
  if (Test-Path -LiteralPath $HostFixture) { Remove-Item -LiteralPath $HostFixture -Recurse -Force -ErrorAction SilentlyContinue }
  foreach ($name in $managed) { [Environment]::SetEnvironmentVariable($name, $prior[$name], "Process") }
  $ErrorActionPreference = $cleanupPreference
}
