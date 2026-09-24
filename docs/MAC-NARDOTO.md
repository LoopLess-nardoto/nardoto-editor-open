# Nardoto Editor no Mac (Apple Silicon)

Passo a passo para compilar, testar, empacotar e publicar o Nardoto Editor num Mac com chip
Apple (M1 em diante). É o mesmo caminho do job `macos` de `.github/workflows/package.yml`
(runner `macos-15`, arm64), só que feito à mão, na máquina. A referência geral continua em
`docs/BUILDING.md`, seção "macOS".

Nada aqui roda no GitHub: o DMG é gerado no Mac e enviado com `gh release upload`.

## 1. Pré-requisitos

1. Ferramentas de linha de comando do Xcode (compilador, `codesign`, `hdiutil`):

   ```bash
   xcode-select --install
   ```

   Se já estiverem instaladas, o comando avisa e não faz nada.

2. Homebrew (https://brew.sh):

   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```

   No fim, rode as duas linhas que o instalador mostra para pôr o `brew` no PATH
   (`eval "$(/opt/homebrew/bin/brew shellenv)"`).

3. Dependências do editor (as mesmas do CI, mais `cmake`, que o runner já traz):

   ```bash
   brew update
   brew install cmake ninja qt ffmpeg zstd openssl@3 sound-touch
   ```

   O Qt do Homebrew é ligado ao mesmo FFmpeg que o editor usa, então não há duas cópias da
   libavcodec no processo. O `openssl@3` é keg-only, por isso aparece explícito no
   `CMAKE_PREFIX_PATH` abaixo.

4. Git e GitHub CLI (para clonar e publicar):

   ```bash
   brew install git gh
   gh auth login
   ```

   Entre com a conta que tem permissão de escrita em `LoopLess-nardoto/nardoto-editor-open`.

## 2. Código

```bash
git clone https://github.com/LoopLess-nardoto/nardoto-editor-open.git NardotoEditor
cd NardotoEditor
git checkout <branch ou tag que vai virar a versão>
```

## 3. Compilar

```bash
cmake -B build-macos -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$(brew --prefix qt);$(brew --prefix openssl@3);$(brew --prefix)" \
  -DDRIFT_BUNDLE_ONNXRUNTIME=OFF

cmake --build build-macos --parallel
```

- `-DDRIFT_BUNDLE_ONNXRUNTIME=OFF` é o que o CI usa no Mac: o ONNX Runtime não vai dentro do
  pacote (legendas automáticas, segmentação e rastreio de rosto chegam pelo addon de
  Aceleração depois).
- A primeira configuração baixa o JUCE e outras dependências pelo FetchContent; demora alguns
  minutos.
- O resultado é um bundle: `build-macos/Nardoto Editor.app`.

Para abrir direto do build (vendo o log no terminal):

```bash
"./build-macos/Nardoto Editor.app/Contents/MacOS/Nardoto Editor"
```

## 4. Rodar os testes

```bash
ctest --test-dir build-macos --output-on-failure
```

Todas as suítes precisam passar (MediaProbe, Core, EditorState, Playback, LayoutStore,
AddonPackage, ProjectBundle, MotionLibrary, Engine, Mcp, Translations). Os testes que geram
vídeo usam o `ffmpeg` do PATH, que o Homebrew já instalou; sem ele, eles são pulados em vez
de falhar.

## 5. Corrigir os nomes "Drift" que sobraram em `resources/macos/`

O que o build usa hoje (`CMakeLists.txt`, bloco `if(APPLE)`, linhas ~648-667):

- `DRIFT_MACOS_EXECUTABLE "Nardoto Editor"`, `DRIFT_MACOS_BUNDLE_ID "com.nardoto.Editor"` e
  `DRIFT_MACOS_ICON_FILE "NardotoEditor.icns"`: já estão com o nome certo.
- `resources/macos/Info.plist.in`: já fala de Nardoto Editor (o "Drift" que aparece é só o
  crédito da licença, e deve ficar).
- `resources/macos/Drift.icns`: **não é referenciado por nada** (o CMake usa
  `NardotoEditor.icns`). Pode ser apagado:

  ```bash
  git rm resources/macos/Drift.icns
  ```

- `resources/macos/Drift.entitlements`: **é usado**, mas só por `scripts/package-macos.sh`
  (linha ~150, `--entitlements "$ROOT/resources/macos/Drift.entitlements"`). Para renomear:

  ```bash
  git mv resources/macos/Drift.entitlements resources/macos/NardotoEditor.entitlements
  sed -i '' 's|resources/macos/Drift.entitlements|resources/macos/NardotoEditor.entitlements|' \
    scripts/package-macos.sh docs/BUILDING.md
  grep -rn "Drift.entitlements" scripts docs CMakeLists.txt   # não deve sobrar nada
  ```

  O conteúdo do arquivo não muda (as duas chaves, `allow-jit` e
  `disable-library-validation`, são necessárias).

Faça isso num commit separado (`chore(mac): ...`) antes de gerar o DMG da versão.

## 6. Gerar o DMG (arm64, assinatura ad-hoc)

```bash
scripts/package-macos.sh --build-dir build-macos --skip-build
```

- Sem `--skip-build` o script compila de novo em Release; com ele, reaproveita o passo 3.
- O script roda o `macdeployqt` (copia Qt, FFmpeg, OpenSSL, zstd e SoundTouch para
  `Contents/Frameworks`), limpa os `LC_RPATH` da máquina de build, assina e cria
  `dist/NardotoEditor-<versão>-arm64.dmg` (a versão vem de `project(NardotoEditor VERSION ...)`
  no `CMakeLists.txt`).
- Sem `--identity`, a assinatura é **ad-hoc**. É o mesmo fallback do CI quando os segredos
  `MACOS_*` não existem: o app abre no Apple Silicon (que exige binário assinado), mas o
  Gatekeeper mostra o aviso de desenvolvedor não identificado.

Conferir o que saiu:

```bash
ls -lh dist/*.dmg
codesign -dv --verbose=2 "build-macos/Nardoto Editor.app" 2>&1 | head -5
```

## 7. Primeira abertura (Gatekeeper)

Com assinatura ad-hoc e sem notarização, o macOS bloqueia a primeira abertura. Depois de
arrastar o app do DMG para `/Applications`, use uma das duas saídas:

- Botão direito (ou Control + clique) em "Nardoto Editor" no Finder, **Abrir**, e confirme
  **Abrir** no aviso. Só é preciso na primeira vez.
- Ou pelo terminal:

  ```bash
  xattr -dr com.apple.quarantine "/Applications/Nardoto Editor.app"
  ```

Isso vale também para quem baixar o DMG publicado: explique esse passo nas notas da release.

## 8. Testar vídeo com transparência e a aba Motion

1. Gere um clipe ProRes 4444 com fundo transparente (texto no canto, resto transparente):

   ```bash
   mkdir -p ~/nardoto-editor/motion/meus/teste-alfa
   cd ~/nardoto-editor/motion/meus/teste-alfa
   ffmpeg -y -f lavfi -i "color=c=black@0.0:s=1920x1080:r=30:d=4,format=rgba" \
     -vf "drawtext=text='Nardoto':fontcolor=white:fontsize=120:x=80:y=80" \
     -c:v prores_ks -profile:v 4444 -pix_fmt yuva444p10le clipe.mov
   ffmpeg -y -i clipe.mov -vf "scale=-2:480" -an -c:v libx264 -pix_fmt yuv420p previa.mp4
   ffmpeg -y -ss 1 -i clipe.mov -frames:v 1 -vf "scale=-2:270" miniatura.jpg
   cat > meta.json <<'EOF'
   {"nome": "Teste alfa", "motor": "hyperframes", "duracaoSegundos": 4,
    "largura": 1920, "altura": 1080,
    "campos": [{"id": "titulo", "rotulo": "Título", "tipo": "texto", "valor": "Nardoto"},
               {"id": "cor", "rotulo": "Cor", "tipo": "cor", "valor": "#E85A2A"}]}
   EOF
   ```

2. Abra o editor, importe qualquer vídeo comum e ponha na timeline.
3. Aba **Motion** (ícone de brilho, logo abaixo de Formas): o card "Teste alfa" aparece em
   "Meus", com miniatura e duração; passar o mouse toca a prévia.
4. Clique **Usar**: o clipe entra numa trilha nova no topo, no playhead. Na prévia, o texto
   aparece sobre o vídeo e o resto do quadro mostra o vídeo de baixo (nada de fundo preto).
   No Mac isso é o que mais importa conferir: o VideoToolbox decodifica ProRes em hardware, e
   o editor precisa pular o hardware para fontes com alfa (senão o fundo vem preto).
5. Exporte alguns segundos e confira que a transparência também sai no vídeo final.
6. Clique **Modificar**, mude o título e confirme: deve aparecer `pedido.json` na pasta do
   item. Sem o Studio aberto, depois de ~5 s o card mostra "Abra o Nardoto Studio para gerar a
   nova versão".
7. Apague a pasta de teste no fim: `rm -rf ~/nardoto-editor/motion/meus/teste-alfa`.

## 9. Publicar

A release do editor fica em `LoopLess-nardoto/nardoto-editor-open`, com tag `nardoto-v<versão>`
(a mesma do instalador do Windows). Tags `nardoto-v*` **não** disparam o `release.yml`, então
nada é compilado no GitHub: o DMG sobe à mão.

```bash
gh release upload nardoto-v<versão> dist/NardotoEditor-<versão>-arm64.dmg \
  --repo LoopLess-nardoto/nardoto-editor-open
```

Se a release dessa versão ainda não existir (normalmente ela é criada junto com o instalador
do Windows), crie antes:

```bash
gh release create nardoto-v<versão> --repo LoopLess-nardoto/nardoto-editor-open \
  --title "Nardoto Editor <versão>" --notes "..."
```

Para o link fixo "última versão" funcionar, publique também uma cópia sem a versão no nome:

```bash
cp dist/NardotoEditor-<versão>-arm64.dmg dist/NardotoEditor-arm64.dmg
gh release upload nardoto-v<versão> dist/NardotoEditor-arm64.dmg \
  --repo LoopLess-nardoto/nardoto-editor-open --clobber
```

## 10. Conferir no Nardoto Studio (Mac)

1. No repositório do Studio, preencha a constante `DOWNLOAD_DO_EDITOR_MAC` em
   `src/ipc-handlers/nardoto-editor.js` com a URL do DMG, por exemplo
   `https://github.com/LoopLess-nardoto/nardoto-editor-open/releases/latest/download/NardotoEditor-arm64.dmg`.
   Enquanto estiver vazia, o botão de baixar avisa que ainda não há versão para Mac. Isso vai
   na próxima release do Studio.
2. Com o editor instalado em `/Applications/Nardoto Editor.app`, abra o Studio no Mac: ele
   procura o executável em `/Applications/Nardoto Editor.app/Contents/MacOS/Nardoto Editor`
   (e em `~/Applications/...`), veja `executaveisCandidatos` em `mcp/lib/editor-bridge.js`.
3. No painel Criar Vídeo, a opção "Criar com" **Nardoto Editor** passa a ficar habilitada.
4. Peça pelo chat para montar um vídeo curto no editor e confira que ele abre, recebe a
   timeline e que um motion graphic gerado pelo Studio aparece na aba Motion.
