# Verify the exact OCaml switch and tracked, test-inclusive opam lock.
# Stable exit codes are documented in docs/dependency-lock.md.
[CmdletBinding()]
param()

$E_INPUT = 10
$E_OPAM = 20
$E_COMPILER = 21
$E_INVARIANT = 22
$E_LINT = 23
$E_LOCK_CHECK = 24
$E_TEST_DEPS = 25
$E_DRIFT = 26
$E_UNSAFE = 27

function Fail([int]$Code, [string]$Label, [string]$Detail) {
    [Console]::Error.WriteLine("${Label}: ${Detail}")
    exit $Code
}

function Invoke-Opam([string[]]$Arguments) {
    $output = & $script:Opam @Arguments 2>&1
    $script:OpamExit = $LASTEXITCODE
    return @($output | ForEach-Object { $_.ToString() })
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$ProjectDir = if ($env:OPAM_PROJECT_DIR) { $env:OPAM_PROJECT_DIR } else { $RepoRoot }
$Source = if ($env:OPAM_LOCK_SOURCE) { $env:OPAM_LOCK_SOURCE } else { Join-Path $ProjectDir "freight_capacity_auction_clearing_engine.opam" }
$Lock = if ($env:OPAM_LOCK_FILE) { $env:OPAM_LOCK_FILE } else { Join-Path $ProjectDir "freight_capacity_auction_clearing_engine.opam.locked" }
$script:Opam = if ($env:OPAM_BIN) { $env:OPAM_BIN } else { "opam" }
$Switch = if ($env:OPAM_SWITCH) { $env:OPAM_SWITCH } else { "." }
$ExpectedOcaml = if ($env:OPAM_EXPECTED_OCAML) { $env:OPAM_EXPECTED_OCAML } else { "5.2.0" }
$TempDir = $null

try {
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { Fail $E_INPUT "INPUT_MISSING" $Source }
    if (-not (Test-Path -LiteralPath $Lock -PathType Leaf)) { Fail $E_INPUT "INPUT_MISSING" $Lock }
    if (-not (Get-Command $script:Opam -ErrorAction SilentlyContinue)) { Fail $E_OPAM "OPAM_UNAVAILABLE" $script:Opam }

    $sourceText = [IO.File]::ReadAllText($Source)
    $lockText = [IO.File]::ReadAllText($Lock)
    $unsafePattern = 'file://|pin-depends|"/[A-Za-z0-9._-]|(?m)(^|["''\s])[A-Za-z]:[\\/]|://[^/@\s]+@|://[^/@\s]+:[^/@\s]+@|(token|password|secret|api[_-]?key)=|\.opam-switch|download-cache|(^|[\\/])_opam([\\/]|$)'
    if ($lockText -match $unsafePattern) {
        Fail $E_UNSAFE "LOCK_UNSAFE" "local/file/absolute path, credential-shaped URL, pin, or cache artifact"
    }

    foreach ($dep in @("alcotest", "ounit2")) {
        $depPattern = '(?m)"' + [Regex]::Escape($dep) + '"[^\r\n]*with-test'
        if ($sourceText -notmatch $depPattern) { Fail $E_TEST_DEPS "TEST_DEP_MISSING" "$dep missing with-test in source manifest" }
        if ($lockText -notmatch $depPattern) { Fail $E_TEST_DEPS "TEST_DEP_MISSING" "$dep missing with-test in lock" }
    }

    $actualLines = Invoke-Opam @("--cli=2.2", "exec", "--switch=$Switch", "--", "ocamlc", "-version")
    if ($script:OpamExit -ne 0) { Fail $E_OPAM "OPAM_EXEC_FAILED" "could not execute ocamlc through switch $Switch" }
    $actual = ($actualLines -join "`n").Trim()
    if ($actual -ne $ExpectedOcaml) { Fail $E_COMPILER "OCAML_VERSION_MISMATCH" "expected $ExpectedOcaml, got $actual" }

    $invariantLines = Invoke-Opam @("--cli=2.2", "switch", "invariant", "--switch=$Switch")
    if ($script:OpamExit -ne 0) { Fail $E_OPAM "OPAM_INVARIANT_FAILED" "switch $Switch" }
    $invariant = ($invariantLines -join "`n").Trim()
    if ($invariant -notmatch 'ocaml-base-compiler.*5\.2\.0') { Fail $E_INVARIANT "SWITCH_INVARIANT_MISMATCH" $invariant }

    [void](Invoke-Opam @("--cli=2.2", "lint", $Source, $Lock))
    if ($script:OpamExit -ne 0) { Fail $E_LINT "OPAM_LINT_FAILED" "source or lock" }

    Push-Location $ProjectDir
    try {
        # A full transitive lock makes every pinned package direct. Combining
        # --with-test with --deps-only would request every locked package's own
        # tests. Check the locked closure here and the project's exact installed
        # conditional test dependencies immediately below.
        [void](Invoke-Opam @("--cli=2.2", "install", ".", "--switch=$Switch", "--deps-only", "--locked", "--check"))
    } finally {
        Pop-Location
    }
    if ($script:OpamExit -ne 0) { Fail $E_LOCK_CHECK "LOCK_CHECK_FAILED" "locked dependency reconciliation" }

    $installedLines = Invoke-Opam @("--cli=2.2", "list", "--switch=$Switch", "--installed", "--columns=name,version", "--short")
    if ($script:OpamExit -ne 0) { Fail $E_OPAM "OPAM_LIST_FAILED" "switch $Switch" }
    $installed = $installedLines -join "`n"
    if ($installed -notmatch '(?m)^alcotest\s+1\.9\.1\s*$') { Fail $E_TEST_DEPS "TEST_DEP_MISSING" "alcotest 1.9.1 not installed" }
    if ($installed -notmatch '(?m)^ounit2\s+2\.2\.7\s*$') { Fail $E_TEST_DEPS "TEST_DEP_MISSING" "ounit2 2.2.7 not installed" }

    $base = if ($env:OPAM_LOCK_TMPDIR_BASE) { $env:OPAM_LOCK_TMPDIR_BASE } else { [IO.Path]::GetTempPath() }
    $TempDir = Join-Path $base ("fca-opam-lock." + [Guid]::NewGuid().ToString("N"))
    [void](New-Item -ItemType Directory -Path $TempDir -Force)
    $tempSource = Join-Path $TempDir ([IO.Path]::GetFileName($Source))
    $tempLock = $tempSource + ".locked"
    Copy-Item -LiteralPath $Source -Destination $tempSource

    Push-Location $TempDir
    try {
        [void](Invoke-Opam @("--cli=2.2", "lock", "--switch=$Switch", ("./" + [IO.Path]::GetFileName($tempSource))))
    } finally {
        Pop-Location
    }
    if ($script:OpamExit -ne 0 -or -not (Test-Path -LiteralPath $tempLock -PathType Leaf)) {
        Fail $E_DRIFT "LOCK_GENERATION_FAILED" "temporary lock"
    }

    $trackedNormalized = [IO.File]::ReadAllText($Lock).Replace("`r`n", "`n").Replace("`r", "`n")
    $generatedNormalized = [IO.File]::ReadAllText($tempLock).Replace("`r`n", "`n").Replace("`r", "`n")
    if ($trackedNormalized -cne $generatedNormalized) {
        Fail $E_DRIFT "LOCK_DRIFT" "regenerate and review freight_capacity_auction_clearing_engine.opam.locked"
    }

    $versionLines = Invoke-Opam @("--version")
    if ($script:OpamExit -ne 0) { Fail $E_OPAM "OPAM_VERSION_FAILED" $script:Opam }
    $version = ($versionLines -join "`n").Trim()
    Write-Output "OPAM_LOCK_OK opam=$version compiler=$actual switch=$invariant"
    exit 0
}
finally {
    if ($TempDir -and (Test-Path -LiteralPath $TempDir)) {
        Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
