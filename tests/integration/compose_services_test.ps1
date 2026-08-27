param(
  [string]$ArtifactRoot = ""
)

$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$composeFile = Join-Path $repo "docker-compose.yml"
$stamp = [DateTime]::UtcNow.ToString("yyyyMMddHHmmss")
$project = "fca-compose-it-$stamp-$PID"
if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) {
  $ArtifactRoot = Join-Path ([System.IO.Path]::GetTempPath()) $project
}
New-Item -ItemType Directory -Force -Path $ArtifactRoot | Out-Null

function Save-Line([string]$Name, [string]$Value) {
  Set-Content -LiteralPath (Join-Path $ArtifactRoot $Name) -Value $Value -Encoding UTF8
}

function Compose([string[]]$Arguments) {
  & docker compose --project-name $project --file $composeFile @Arguments
  if ($LASTEXITCODE -ne 0) { throw "COMPOSE_COMMAND_FAILED" }
}

function Published-Endpoint([string]$Service, [int]$ContainerPort) {
  $mapping = @(Compose @("port", $Service, "$ContainerPort"))
  if ($mapping.Count -ne 1 -or $mapping[0] -notmatch '^127\.0\.0\.1:([0-9]+)$') {
    throw "COMPOSE_LOOPBACK_MAPPING_INVALID"
  }
  return @{ Host = "127.0.0.1"; Port = [int]$Matches[1]; Mapping = $mapping[0] }
}

function Redis-Host-Ping([string]$HostName, [int]$Port) {
  $client = [System.Net.Sockets.TcpClient]::new()
  try {
    $pending = $client.BeginConnect($HostName, $Port, $null, $null)
    if (-not $pending.AsyncWaitHandle.WaitOne(5000)) { throw "REDIS_HOST_CONNECT_TIMEOUT" }
    $client.EndConnect($pending)
    $stream = $client.GetStream()
    $stream.ReadTimeout = 5000
    $stream.WriteTimeout = 5000
    $request = [Text.Encoding]::ASCII.GetBytes("*1`r`n`$4`r`nPING`r`n")
    $stream.Write($request, 0, $request.Length)
    $response = New-Object byte[] 64
    $count = $stream.Read($response, 0, $response.Length)
    return [Text.Encoding]::ASCII.GetString($response, 0, $count).Trim()
  }
  finally { $client.Dispose() }
}

$managedEnvironment = @(
  "COMPOSE_PROJECT_NAME", "POSTGRES_DB", "POSTGRES_USER", "POSTGRES_PASSWORD",
  "POSTGRES_HOST_PORT", "REDIS_HOST_PORT", "PGPASSWORD"
)
$priorEnvironment = @{}
foreach ($name in $managedEnvironment) {
  $priorEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
}
$postgresUser = "freight_it_$PID"
$postgresDatabase = "freight_it_$PID"
$postgresPassword = "local-disposable-$stamp-$PID"
$env:COMPOSE_PROJECT_NAME = $project
$env:POSTGRES_USER = $postgresUser
$env:POSTGRES_DB = $postgresDatabase
$env:POSTGRES_PASSWORD = $postgresPassword
$env:POSTGRES_HOST_PORT = "0"
$env:REDIS_HOST_PORT = "0"
$completed = $false

try {
  $engine = & docker version --format '{{.Server.Version}}'
  if ($LASTEXITCODE -ne 0) { throw "DOCKER_ENGINE_UNAVAILABLE" }
  $composeVersion = & docker compose version --short
  if ($LASTEXITCODE -ne 0) { throw "DOCKER_COMPOSE_UNAVAILABLE" }
  $postgresImage = & docker image inspect postgres:16-alpine --format '{{.Id}}'
  if ($LASTEXITCODE -ne 0) { throw "POSTGRES_CACHED_IMAGE_ABSENT" }
  $redisImage = & docker image inspect redis:7-alpine --format '{{.Id}}'
  if ($LASTEXITCODE -ne 0) { throw "REDIS_CACHED_IMAGE_ABSENT" }
  Save-Line "preflight.txt" "engine=$engine`ncompose=$composeVersion`npostgres=$postgresImage`nredis=$redisImage"

  if (-not (Test-Path -LiteralPath $composeFile -PathType Leaf)) {
    throw "COMPOSE_CONTRACT_ABSENT: docker-compose.yml"
  }

  Compose @("config", "--quiet") | Out-Null
  $services = Compose @("config", "--services")
  $volumes = Compose @("config", "--volumes")
  Save-Line "config-contract.txt" ("services=" + ($services -join ",") + "`nvolumes=" + ($volumes -join ","))
  if ((($services | Sort-Object) -join ",") -ne "postgres,redis") { throw "COMPOSE_SERVICE_CONTRACT_INVALID" }
  if (($volumes | Sort-Object) -join "," -ne "postgres_data,redis_data") { throw "COMPOSE_VOLUME_CONTRACT_INVALID" }
  if (Select-String -LiteralPath $composeFile -Pattern '^\s*container_name\s*:' -Quiet) {
    throw "COMPOSE_CONTAINER_NAME_FORBIDDEN"
  }

  Compose @("up", "-d", "--pull", "never", "--wait", "--wait-timeout", "60", "postgres", "redis") | Out-Null
  $postgresVersion = Compose @("exec", "-T", "postgres", "psql", "-U", $postgresUser, "-d", $postgresDatabase, "-Atc", "SHOW server_version;")
  $selectOne = Compose @("exec", "-T", "postgres", "psql", "-U", $postgresUser, "-d", $postgresDatabase, "-Atc", "SELECT 1;")
  $redisVersion = Compose @("exec", "-T", "redis", "redis-cli", "--raw", "INFO", "server") | Select-String '^redis_version:'
  $pong = Compose @("exec", "-T", "redis", "redis-cli", "--raw", "PING")
  if (-not ($postgresVersion -match '^16\.')) { throw "POSTGRES_VERSION_INVALID" }
  if ($selectOne -ne "1") { throw "POSTGRES_SELECT_FAILED" }
  if (-not ($redisVersion -match '^redis_version:7\.')) { throw "REDIS_VERSION_INVALID" }
  if ($pong -ne "PONG") { throw "REDIS_PING_FAILED" }

  $postgresEndpoint = Published-Endpoint "postgres" 5432
  $redisEndpoint = Published-Endpoint "redis" 6379
  $psql = Get-Command psql -ErrorAction SilentlyContinue
  if ($null -eq $psql) { throw "HOST_PSQL_CLIENT_UNAVAILABLE" }
  $env:PGPASSWORD = $postgresPassword
  $hostSelectOne = & $psql.Source -h $postgresEndpoint.Host -p $postgresEndpoint.Port -U $postgresUser -d $postgresDatabase -Atc "SELECT 1;"
  if ($LASTEXITCODE -ne 0 -or $hostSelectOne -ne "1") { throw "POSTGRES_HOST_SELECT_FAILED" }
  $hostPong = Redis-Host-Ping $redisEndpoint.Host $redisEndpoint.Port
  if ($hostPong -ne "+PONG") { throw "REDIS_HOST_PING_FAILED" }
  Save-Line "reachability.txt" "postgres_version=$postgresVersion`ninternal_select_one=$selectOne`n$redisVersion`ninternal_ping=$pong`npostgres_mapping=$($postgresEndpoint.Mapping)`nhost_select_one=$hostSelectOne`nredis_mapping=$($redisEndpoint.Mapping)`nhost_ping=$hostPong`npostgres_override_user=true`npostgres_override_database=true"
  Compose @("ps", "--format", "json") | Set-Content -LiteralPath (Join-Path $ArtifactRoot "compose-ps.json") -Encoding UTF8

  Compose @("down", "--remove-orphans") | Out-Null
  $postgresVolume = "${project}_postgres_data"
  $redisVolume = "${project}_redis_data"
  & docker volume inspect $postgresVolume $redisVolume | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "COMPOSE_VOLUMES_NOT_PRESERVED" }
  Save-Line "down-preserved-volumes.txt" "preserved=$postgresVolume,$redisVolume"
  & docker volume rm $postgresVolume $redisVolume | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "COMPOSE_VOLUME_CLEANUP_FAILED" }
  $network = "${project}-backend"
  $existingNetwork = & docker network ls --filter "name=^${network}$" --format '{{.Name}}'
  if ($existingNetwork -eq $network) { & docker network rm $network | Out-Null }

  $containers = & docker ps -aq --filter "label=com.docker.compose.project=$project"
  $networks = & docker network ls -q --filter "label=com.docker.compose.project=$project"
  $remainingVolumes = & docker volume ls -q --filter "label=com.docker.compose.project=$project"
  Save-Line "cleanup.txt" "containers=$containers`nnetworks=$networks`nvolumes=$remainingVolumes"
  if ($containers -or $networks -or $remainingVolumes) { throw "COMPOSE_PROJECT_RESOURCE_LEAK" }
  $completed = $true
  Write-Output "COMPOSE_SERVICES_PASS artifacts=$ArtifactRoot"
}
finally {
  if (Test-Path -LiteralPath $composeFile -PathType Leaf) {
    & docker compose --project-name $project --file $composeFile down --remove-orphans *> $null
  }
  if (-not $completed) {
    & docker ps -aq --filter "label=com.docker.compose.project=$project" | ForEach-Object { if ($_){ & docker rm -f $_ *> $null } }
    & docker volume ls -q --filter "label=com.docker.compose.project=$project" | ForEach-Object { if ($_){ & docker volume rm $_ *> $null } }
    & docker network ls -q --filter "label=com.docker.compose.project=$project" | ForEach-Object { if ($_){ & docker network rm $_ *> $null } }
  }
  foreach ($name in $managedEnvironment) {
    [Environment]::SetEnvironmentVariable($name, $priorEnvironment[$name], "Process")
  }
}
