# Monta o ambiente de compilacao do Nardoto Editor no Windows dentro de .tools\
# (ignorado pelo git), com as mesmas versoes do CI (.github/workflows/package.yml):
# Qt 6.10.3 msvc2022_64 + qtmultimedia/qtimageformats, FFmpeg n7.1 e vcpkg com
# zstd, openssl e soundtouch. Depois disso `npm run build:dev` acha tudo sozinho.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$tools = Join-Path $repo '.tools'
New-Item -ItemType Directory -Force -Path $tools | Out-Null

# Qt
$qt = Join-Path $tools 'qt'
if (-not (Get-ChildItem -Path $qt -Recurse -Filter Qt6Core.dll -ErrorAction SilentlyContinue | Select-Object -First 1)) {
    Write-Host '== Qt 6.10.3'
    python -m pip install --quiet --upgrade aqtinstall
    python -m aqt install-qt windows desktop 6.10.3 win64_msvc2022_64 -m qtmultimedia qtimageformats -O $qt
}

# FFmpeg
$ff = Join-Path $tools 'deps\ffmpeg'
if (-not (Test-Path (Join-Path $ff 'include\libavcodec'))) {
    Write-Host '== FFmpeg n7.1'
    $zip = Join-Path $tools 'ffmpeg.zip'
    $tmp = Join-Path $tools 'ffmpeg_extraido'
    Invoke-WebRequest -Uri 'https://github.com/CutWire-Studios/FFmpeg-Builds/releases/download/n7.1/ffmpeg-n7.1-win64-gpl-shared.zip' -OutFile $zip
    Remove-Item -Recurse -Force $tmp, $ff -ErrorAction SilentlyContinue
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    New-Item -ItemType Directory -Force -Path $ff | Out-Null
    Copy-Item -Path "$((Get-ChildItem $tmp)[0].FullName)\*" -Destination $ff -Recurse -Force
    Remove-Item -Recurse -Force $tmp, $zip
}

# vcpkg
$vcpkg = Join-Path $tools 'vcpkg'
if (-not (Test-Path (Join-Path $vcpkg 'vcpkg.exe'))) {
    Write-Host '== vcpkg'
    git clone --depth 1 https://github.com/microsoft/vcpkg.git $vcpkg
    & (Join-Path $vcpkg 'bootstrap-vcpkg.bat') -disableMetrics
}
Write-Host '== vcpkg: zstd openssl soundtouch'
# Download do vcpkg (Perl do openssl, por exemplo) falha as vezes por rede: tenta de novo.
for ($i = 1; $i -le 3; $i++) {
    & (Join-Path $vcpkg 'vcpkg.exe') install zstd openssl soundtouch --triplet x64-windows
    if ($LASTEXITCODE -eq 0) { break }
    if ($i -eq 3) { throw 'vcpkg não conseguiu instalar zstd/openssl/soundtouch' }
    Write-Host "== vcpkg falhou, tentando de novo ($i/3)"
}

Write-Host '== ambiente pronto'
