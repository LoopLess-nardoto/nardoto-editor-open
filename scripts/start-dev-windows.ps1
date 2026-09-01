[CmdletBinding()]
param(
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$buildDir = Join-Path $repoRoot 'build-dev'

$cmake = (Get-Command cmake -ErrorAction SilentlyContinue).Source
if (-not $cmake) {
    $cmake = 'C:\Program Files\CMake\bin\cmake.exe'
}
if (-not (Test-Path $cmake)) {
    throw 'CMake não foi encontrado. Instale o CMake e adicione-o ao PATH.'
}

$qtRoot = $env:QT_ROOT_DIR
if (-not $qtRoot) {
    $qtCandidates = Get-ChildItem -Path (Join-Path $repoRoot '.tools\qt') -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName 'bin\Qt6Core.dll') }
    $qtRoot = ($qtCandidates | Select-Object -First 1).FullName
}
if (-not $qtRoot -or -not (Test-Path (Join-Path $qtRoot 'bin\Qt6Core.dll'))) {
    throw 'Qt 6 não foi encontrado. Defina QT_ROOT_DIR ou instale-o em .tools\qt.'
}

$vcpkgRoot = if ($env:VCPKG_ROOT) { $env:VCPKG_ROOT } else { Join-Path $repoRoot '.tools\vcpkg' }
$toolchain = Join-Path $vcpkgRoot 'scripts\buildsystems\vcpkg.cmake'
if (-not (Test-Path $toolchain)) {
    throw 'vcpkg não foi encontrado. Defina VCPKG_ROOT ou inicialize .tools\vcpkg.'
}

$ffmpegRoot = $env:FFMPEG_ROOT
if (-not $ffmpegRoot) {
    $ffmpegRoot = (Get-ChildItem -Path (Join-Path $repoRoot '.tools\deps\ffmpeg') -Directory -ErrorAction SilentlyContinue |
        Select-Object -First 1).FullName
}
if (-not $ffmpegRoot -or -not (Test-Path (Join-Path $ffmpegRoot 'lib\avformat.lib'))) {
    throw 'FFmpeg compatível não foi encontrado. Defina FFMPEG_ROOT ou instale-o em .tools\deps\ffmpeg.'
}

if (-not (Test-Path (Join-Path $buildDir 'CMakeCache.txt'))) {
    & $cmake -S $repoRoot -B $buildDir -A x64 `
        "-DCMAKE_TOOLCHAIN_FILE=$toolchain" `
        "-DCMAKE_PREFIX_PATH=$qtRoot;$ffmpegRoot" `
        "-DFFMPEG_ROOT=$ffmpegRoot" `
        "-DFETCHCONTENT_BASE_DIR=$(Join-Path $repoRoot '.tools\fetchcontent')" `
        '-DDRIFT_AUTO_UPDATE_TRANSLATIONS=OFF'
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

& $cmake --build $buildDir --config Release --target drift --parallel
if ($LASTEXITCODE -ne 0 -or $NoLaunch) {
    exit $LASTEXITCODE
}

$releaseDir = Join-Path $buildDir 'Release'
$editorExe = Join-Path $releaseDir 'nardoto-editor.exe'
if (-not (Test-Path $editorExe)) {
    throw 'A build terminou sem gerar o executável do Nardoto Editor.'
}

$qtBin = Join-Path $qtRoot 'bin'
$vcpkgBin = Join-Path $vcpkgRoot 'installed\x64-windows\bin'
$env:PATH = "$releaseDir;$qtBin;$vcpkgBin;$env:PATH"
$env:QML2_IMPORT_PATH = Join-Path $qtRoot 'qml'
Start-Process -FilePath $editorExe -WorkingDirectory $releaseDir
