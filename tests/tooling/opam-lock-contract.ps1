# Deterministic PowerShell adversarial contracts plus optional actual-client integration.
[CmdletBinding()]
param()
$ErrorActionPreference = "Stop"

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$Verify = Join-Path $Root "scripts\verify-opam-lock.ps1"
$WorkRaw = Join-Path ([IO.Path]::GetTempPath()) ("fca-opam-contract." + [Guid]::NewGuid().ToString("N"))
$Work = Join-Path $WorkRaw "contract workspace"
$PowerShellExe = (Get-Process -Id $PID).Path
[void](New-Item -ItemType Directory -Path $Work -Force)

function Fail([string]$Message) {
    [Console]::Error.WriteLine("CONTRACT_FAIL $Message")
    exit 1
}

try {
    $FakeDir = Join-Path $Work "fake bin"
    [void](New-Item -ItemType Directory -Path $FakeDir -Force)
    $Fake = Join-Path $FakeDir "fake opam.ps1"
    @'
if ($env:FAKE_ARG_LOG) {
    Add-Content -LiteralPath $env:FAKE_ARG_LOG -Value "BEGIN"
    foreach ($argument in $args) { Add-Content -LiteralPath $env:FAKE_ARG_LOG -Value ("<" + $argument + ">") }
}
$joined = " " + ($args -join " ") + " "
if ($joined.Contains(" --version ")) { Write-Output "2.5.2"; exit 0 }
if ($joined.Contains(" exec ")) {
    if ($env:FAKE_MODE -eq "compiler-mismatch") { Write-Output "5.1.1" } else { Write-Output "5.2.0" }
    exit 0
}
if ($joined.Contains(" switch invariant ")) {
    if ($env:FAKE_MODE -eq "invariant-mismatch") { Write-Output '["ocaml-base-compiler" {= "5.1.1"}]' }
    else { Write-Output '["ocaml-base-compiler" {= "5.2.0"}]' }
    exit 0
}
if ($joined.Contains(" lint ")) { exit 0 }
if ($joined.Contains(" install ")) {
    if ($env:FAKE_MODE -eq "lock-check-fail") { exit 1 }
    exit 0
}
if ($joined.Contains(" list ")) {
    if ($env:FAKE_MODE -ne "installed-alcotest-missing") { Write-Output "alcotest                1.9.1" }
    if ($env:FAKE_MODE -ne "installed-ounit2-missing") { Write-Output "ounit2                  2.2.7" }
    exit 0
}
if ($joined.Contains(" lock ")) {
    $source = $args[$args.Count - 1]
    if ($source.StartsWith("./")) { $source = $source.Substring(2) }
    $output = $source + ".locked"
    Copy-Item -LiteralPath $env:FAKE_TRACKED_LOCK -Destination $output
    if ($env:FAKE_MODE -eq "drift") { Add-Content -LiteralPath $output -Value "`n# deterministic drift" }
    exit 0
}
exit 99
'@ | Set-Content -LiteralPath $Fake -Encoding UTF8

    function Expect-Code([string]$Label, [int]$Expected, [string]$Mode, [string]$Source, [string]$Lock) {
        $tmpBase = Join-Path $Work ("temp base " + $Label)
        [void](New-Item -ItemType Directory -Path $tmpBase -Force)
        $env:OPAM_BIN = $Fake
        $env:OPAM_PROJECT_DIR = $Root
        $env:OPAM_LOCK_SOURCE = $Source
        $env:OPAM_LOCK_FILE = $Lock
        $env:OPAM_SWITCH = "fake switch with spaces"
        $env:OPAM_LOCK_TMPDIR_BASE = $tmpBase
        $env:FAKE_MODE = $Mode
        $env:FAKE_TRACKED_LOCK = $Lock
        $env:FAKE_ARG_LOG = Join-Path $Work "args.log"
        $oldPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $output = & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $Verify 2>&1
        $code = $LASTEXITCODE
        $ErrorActionPreference = $oldPreference
        if ($code -ne $Expected) { Fail "$Label expected=$Expected actual=$code output=$($output -join ' | ')" }
        $leaks = @(Get-ChildItem -LiteralPath $tmpBase -Filter "fca-opam-lock.*" -ErrorAction SilentlyContinue)
        if ($leaks.Count -ne 0) { Fail "$Label temporary directory leaked" }
        $first = if ($output) { @($output)[0].ToString() } else { "" }
        Write-Output ("PASS {0,-28} code={1} {2}" -f $Label, $code, $first)
    }

    $Base = Join-Path $Work "base path with spaces"
    [void](New-Item -ItemType Directory -Path $Base)
    $BaseSource = Join-Path $Base "source manifest.opam"
    $BaseLock = $BaseSource + ".locked"
    Copy-Item (Join-Path $Root "freight_capacity_auction_clearing_engine.opam") $BaseSource
    Copy-Item (Join-Path $Root "freight_capacity_auction_clearing_engine.opam.locked") $BaseLock

    function Protected-Hashes {
        @(
            (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Root "freight_capacity_auction_clearing_engine.opam")).Hash,
            (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Root "freight_capacity_auction_clearing_engine.opam.locked")).Hash,
            (Get-FileHash -Algorithm SHA256 -LiteralPath $Verify).Hash
        ) -join "`n"
    }
    $Before = Protected-Hashes

    Expect-Code "compiler-mismatch" 21 "compiler-mismatch" $BaseSource $BaseLock
    Expect-Code "invariant-mismatch" 22 "invariant-mismatch" $BaseSource $BaseLock
    Expect-Code "lock-check-fail" 24 "lock-check-fail" $BaseSource $BaseLock
    Expect-Code "lock-drift" 26 "drift" $BaseSource $BaseLock
    Expect-Code "installed-alcotest-missing" 25 "installed-alcotest-missing" $BaseSource $BaseLock
    Expect-Code "installed-ounit2-missing" 25 "installed-ounit2-missing" $BaseSource $BaseLock

    function Invoke-Unsafe-Case([string]$Label, [string]$Content) {
        $dir = Join-Path $Work $Label
        [void](New-Item -ItemType Directory -Path $dir)
        $source = Join-Path $dir "source.opam"
        $lock = $source + ".locked"
        Copy-Item $BaseSource $source
        Copy-Item $BaseLock $lock
        Add-Content -LiteralPath $lock -Value $Content
        Expect-Code $Label 27 "ok" $source $lock
    }
    Invoke-Unsafe-Case "unsafe-local-pin" 'pin-depends: [ ["bad.dev" "git+https://example.invalid/bad.git"] ]'
    Invoke-Unsafe-Case "unsafe-file-url" 'url { src: "file:///tmp/private.tgz" }'
    Invoke-Unsafe-Case "unsafe-posix-absolute" 'url { src: "/srv/private/package.tgz" }'
    Invoke-Unsafe-Case "unsafe-windows-absolute" 'url { src: "C:\private\package.tgz" }'
    Invoke-Unsafe-Case "unsafe-credential-url" 'url { src: "https://token@example.invalid/package.tgz" }'
    Invoke-Unsafe-Case "unsafe-credential-query" 'url { src: "https://example.invalid/package.tgz?api_key=redacted" }'

    foreach ($dependency in @("alcotest", "ounit2")) {
        $Missing = Join-Path $Work ("missing lock test dependency " + $dependency)
        [void](New-Item -ItemType Directory -Path $Missing)
        $MissingSource = Join-Path $Missing "source.opam"
        $MissingLock = $MissingSource + ".locked"
        Copy-Item $BaseSource $MissingSource
        @([IO.File]::ReadAllLines($BaseLock) | Where-Object { $_ -notmatch ('"' + [Regex]::Escape($dependency) + '"') }) |
            Set-Content -LiteralPath $MissingLock -Encoding UTF8
        Expect-Code ("lock-" + $dependency + "-missing") 25 "ok" $MissingSource $MissingLock
    }

    Expect-Code "quoted-args-success" 0 "ok" $BaseSource $BaseLock
    $argumentLog = [IO.File]::ReadAllLines((Join-Path $Work "args.log"))
    foreach ($expectedArgument in @(
        "<$BaseSource>",
        "<$BaseLock>",
        "<--switch=fake switch with spaces>",
        "<--deps-only>",
        "<--locked>",
        "<--check>",
        "<./source manifest.opam>"
    )) {
        if ($argumentLog -cnotcontains $expectedArgument) { Fail "quoted argument not preserved: $expectedArgument" }
    }
    Write-Output "PASS args-and-quoting-preserved"

    if ((Protected-Hashes) -cne $Before) { Fail "verifier mutated protected repository files" }
    Write-Output "PASS no-protected-repository-mutation"

    if ($env:OPAM_LOCK_CONTRACT_SKIP_INTEGRATION -ne "1") {
        Remove-Item Env:OPAM_BIN,Env:OPAM_PROJECT_DIR,Env:OPAM_LOCK_SOURCE,Env:OPAM_LOCK_FILE,Env:OPAM_SWITCH,Env:OPAM_LOCK_TMPDIR_BASE,Env:FAKE_MODE,Env:FAKE_TRACKED_LOCK,Env:FAKE_ARG_LOG -ErrorAction SilentlyContinue
        $oldPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $actual = & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $Verify 2>&1
        $actualCode = $LASTEXITCODE
        $ErrorActionPreference = $oldPreference
        if ($actualCode -ne 0) { Fail "actual-client integration: $($actual -join ' | ')" }
        Write-Output "PASS actual-client-integration"
    } else {
        Write-Output "SKIP actual-client-integration OPAM_LOCK_CONTRACT_SKIP_INTEGRATION=1"
    }
    Write-Output "OPAM_LOCK_CONTRACT_OK"
    exit 0
}
finally {
    Remove-Item -LiteralPath $WorkRaw -Recurse -Force -ErrorAction SilentlyContinue
}
