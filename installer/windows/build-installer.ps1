# Monta o instalador do Nardoto Editor para Windows x64.
#
#   pwsh installer/windows/build-installer.ps1
#   pwsh installer/windows/build-installer.ps1 -Versao 0.2.0
#
# Faz três coisas: separa o que vai para o cliente (o Release tem testes e
# bibliotecas de compilação junto), chama o windeployqt para o Qt viajar ao lado
# do executável e compila o NSIS com a arte do tema escuro.

param(
  [string]$Versao,
  [string]$Release,
  [switch]$PularDeploy
)

$ErrorActionPreference = 'Stop'

$raiz = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $Release) { $Release = Join-Path $raiz 'build-dev\Release' }
$palco = Join-Path $raiz 'dist\bin'
$saida = Join-Path $PSScriptRoot 'output'
$exe = Join-Path $Release 'nardoto-editor.exe'

if (-not $Versao) {
  $Versao = (Get-Content (Join-Path $raiz 'package.json') -Raw | ConvertFrom-Json).version
}
if (-not (Test-Path $exe)) {
  throw "nardoto-editor.exe não está em $Release. Compile o editor antes (cmake --build build-dev --config Release)."
}

Write-Host "Nardoto Editor $Versao" -ForegroundColor Cyan
Write-Host "  origem: $Release"

if (-not $PularDeploy) {
  # 1. Palco limpo: só o que o cliente precisa.
  if (Test-Path $palco) { Remove-Item -Recurse -Force $palco }
  New-Item -ItemType Directory -Force $palco | Out-Null

  Copy-Item $exe $palco
  Get-ChildItem $Release -Filter *.dll -File | Copy-Item -Destination $palco
  foreach ($pasta in 'effects', 'transitions', 'effect-templates', 'audio-effects', 'onnxruntime') {
    $origem = Join-Path $Release $pasta
    if (Test-Path $origem) { Copy-Item -Recurse -Force $origem $palco }
  }

  # 2. Qt ao lado do executável: sem isso o editor só abre nesta máquina, que
  #    tem o Qt das ferramentas no PATH.
  $windeployqt = Get-ChildItem (Join-Path $raiz '.tools\qt') -Recurse -Filter 'windeployqt.exe' -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
  if (-not $windeployqt) { throw "windeployqt.exe não encontrado em .tools\qt." }
  Write-Host "  windeployqt: $windeployqt"
  & $windeployqt --release --qmldir (Join-Path $raiz 'src\qml') --no-opengl-sw (Join-Path $palco 'nardoto-editor.exe') | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "windeployqt falhou ($LASTEXITCODE)." }

  # 3. Runtime do Visual C++ junto: máquina sem o redistribuível não abre o app.
  if (-not (Test-Path (Join-Path $palco 'msvcp140.dll'))) {
    $crt = Get-ChildItem 'C:\Program Files\Microsoft Visual Studio', 'C:\Program Files (x86)\Microsoft Visual Studio' `
      -Recurse -Directory -Filter 'Microsoft.VC*.CRT' -ErrorAction SilentlyContinue |
      Where-Object FullName -match '\\x64\\' | Sort-Object FullName | Select-Object -Last 1
    if (-not $crt) { throw "Runtime do Visual C++ (Microsoft.VC*.CRT x64) não encontrado." }
    Get-ChildItem $crt.FullName -Filter *.dll | Copy-Item -Destination $palco
    Write-Host "  runtime C++: $($crt.FullName)"
  }
}

$arquivos = Get-ChildItem $palco -Recurse -File
Write-Host ("  empacotando: {0} arquivos, {1:N0} MB" -f $arquivos.Count, (($arquivos | Measure-Object Length -Sum).Sum / 1MB))

# 4. NSIS do electron-builder: é o mesmo compilador que gera o instalador do Studio.
$makensis = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'electron-builder\Cache\nsis') -Recurse -Filter 'makensis.exe' -ErrorAction SilentlyContinue |
  Where-Object FullName -match '\\Bin\\' | Select-Object -First 1 -ExpandProperty FullName
if (-not $makensis) { throw "makensis.exe não encontrado no cache do electron-builder." }

New-Item -ItemType Directory -Force $saida | Out-Null
& $makensis "/DVERSION=$Versao" "/DSOURCE_DIR=$palco" (Join-Path $PSScriptRoot 'nardoto-editor.nsi')
if ($LASTEXITCODE -ne 0) { throw "makensis falhou ($LASTEXITCODE)." }

$instalador = Join-Path $saida 'NardotoEditor-Setup-x64.exe'
$item = Get-Item $instalador
Write-Host ("pronto: {0} ({1:N0} MB)" -f $instalador, ($item.Length / 1MB)) -ForegroundColor Green
