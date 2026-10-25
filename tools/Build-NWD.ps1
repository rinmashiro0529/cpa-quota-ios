param(
    [ValidateSet('All', 'Test', 'Device', 'Simulator')]
    [string]$Mode = 'All',
    [string]$HostAlias = 'NWD'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$artifactRoot = Join-Path $projectRoot 'artifacts'
if (-not (Test-Path -LiteralPath $projectRoot -PathType Container)) { throw 'Project directory is missing.' }
foreach ($tool in @('tar', 'scp', 'ssh')) { Get-Command $tool -ErrorAction Stop | Out-Null }
New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null
$archive = Join-Path $artifactRoot "source-$stamp.tar"
$remoteRoot = '/opt/ios-builder/work/cpa-quota-ios'
$containerRoot = '/work/cpa-quota-ios'

& tar --exclude='./.build' --exclude='./artifacts' --exclude='./.git' --exclude='./signing' --exclude='*.p12' --exclude='*.mobileprovision' --exclude='key.txt' --exclude='.env*' -cf $archive -C $projectRoot .
if ($LASTEXITCODE -ne 0) { throw 'Source archive creation failed.' }
$hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()

$prepare = @'
if test -e /opt/ios-builder/work/cpa-quota-ios && ! test -f /opt/ios-builder/work/cpa-quota-ios/.cpa-quota-owned; then
    printf '%s\n' 'Refusing to overwrite an unowned build directory.' >&2
    exit 2
fi
mkdir -p /opt/ios-builder/work/cpa-quota-ios/.incoming /opt/ios-builder/work/cpa-quota-ios/artifacts
printf '%s\n' 'CPAQuotaKit-20261025-backend' > /opt/ios-builder/work/cpa-quota-ios/.cpa-quota-owned
'@
& ssh -o BatchMode=yes -o ConnectTimeout=15 $HostAlias $prepare
if ($LASTEXITCODE -ne 0) { throw 'Remote project preparation failed.' }
$remoteArchive = "$remoteRoot/.incoming/source-$stamp.tar"
& scp -q $archive "${HostAlias}:$remoteArchive"
if ($LASTEXITCODE -ne 0) { throw 'Source upload failed.' }

$unpack = "printf '%s  %s\n' '$hash' '$remoteArchive' | sha256sum -c -; tar --no-same-owner -m -xf '$remoteArchive' -C '$remoteRoot'"
& ssh -o BatchMode=yes -o ConnectTimeout=15 $HostAlias "set -e; $unpack"
if ($LASTEXITCODE -ne 0) { throw 'Remote archive verification or extraction failed.' }

$commands = @()
if ($Mode -in @('All', 'Test')) {
    $commands += @{
        Name = 'native-tests'
        Command = 'swift test -j 2 --scratch-path .build/linux -Xswiftc -warnings-as-errors'
    }
    $commands += @{
        Name = 'probe-build'
        Command = 'swift build -j 2 --scratch-path .build/linux --product cpa-quota-probe -Xswiftc -warnings-as-errors'
    }
}
if ($Mode -in @('All', 'Device')) {
    $commands += @{
        Name = 'ios-device-build'
        Command = 'swift build --build-system native -j 2 --swift-sdk darwin --triple arm64-apple-ios --scratch-path .build/ios-device -c release --target CPAQuotaKit -Xswiftc -warnings-as-errors'
    }
}
if ($Mode -in @('All', 'Simulator')) {
    $commands += @{
        Name = 'ios-simulator-build'
        Command = 'swift build --build-system native -j 2 --swift-sdk darwin --triple arm64-apple-ios-simulator --scratch-path .build/ios-simulator -c release --target CPAQuotaKit -Xswiftc -warnings-as-errors'
    }
}

foreach ($item in $commands) {
    $name = $item.Name
    $command = $item.Command
    $remote = "docker exec -w '$containerRoot' ios-builder bash -lc 'set -o pipefail; $command 2>&1 | tee artifacts/$name.log'"
    & ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 $HostAlias $remote
    $result = $LASTEXITCODE
    & scp -q "${HostAlias}:$remoteRoot/artifacts/$name.log" (Join-Path $artifactRoot "$name.log")
    if ($result -ne 0) { throw "NWD step failed: $name (exit $result). See artifacts/$name.log." }
    if ($LASTEXITCODE -ne 0) { throw "Could not retrieve NWD log: $name" }
}

[pscustomobject]@{
    Mode = $Mode
    SourceArchiveSHA256 = $hash
    LocalProject = $projectRoot
    RemoteProject = $remoteRoot
    BuildContainer = 'ios-builder'
    SigningUsed = $false
}
