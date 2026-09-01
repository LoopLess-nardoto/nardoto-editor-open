<p align="center">
  <img src="resources/nardoto-editor.png" alt="Ícone do Nardoto Editor" width="128" height="128">
</p>

<h1 align="center">Nardoto Editor</h1>

<p align="center">
  Editor de vídeo gratuito, local e de código aberto.
</p>

<p align="center">
  <a href="https://github.com/LoopLess-nardoto/nardoto-editor-open">Código-fonte</a> ·
  <a href="https://github.com/LoopLess-nardoto/nardoto-editor-open/issues">Problemas</a> ·
  <a href="LICENSE">GPL-3.0-or-later</a>
</p>

Nardoto Editor é a base aberta de edição de vídeo do ecossistema Nardoto. Ele roda no computador do usuário, não exige conta e não coloca marca-d'água no resultado.

Este projeto é um fork do [Drift, da CutWire Studios](https://github.com/CutWire-Studios/Drift). Ele preserva o motor de edição e a licença GPL-3.0-or-later do projeto original, mas tem identidade visual, metadados de distribuição e evolução próprios. Veja [NOTICE](NOTICE) para os avisos de atribuição.

## O que já é possível fazer

- Importar vídeos, imagens e áudios.
- Montar uma linha do tempo com múltiplas faixas.
- Cortar, mover, animar, aplicar efeitos e transições.
- Criar títulos e legendas, inclusive a partir da fala.
- Mixar áudio, remover ruído e exportar localmente.
- Controlar a sessão aberta por MCP local, quando esse acesso é habilitado no app.

Os projetos continuam usando a extensão `.drift` neste primeiro ciclo para manter a compatibilidade com os arquivos já existentes. O aplicativo passa a se identificar como **Nardoto Editor** no sistema operacional e nos instaladores.

## Identidade visual

O tema padrão segue o Nardoto Studio: fundo quase preto, superfícies em camadas sem linhas divisórias, tipografia Inter e laranja `#E85A2A` para as ações principais. O ícone foi trazido do antigo Nardoto Editor sob licença MIT compatível; os detalhes estão em [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Desenvolvimento

Os requisitos e os comandos de compilação originais do motor continuam documentados em [docs/BUILDING.md](docs/BUILDING.md). Em resumo, instale Qt 6.5 ou superior, CMake e um compilador C++20 compatível, e configure o projeto com CMake.

```bash
cmake -S . -B build
cmake --build build --config Release
```

### Atalho de desenvolvimento no Windows

Depois da primeira build nativa, use o mesmo comando familiar do Studio:

```bash
npm start
```

Ele abre o motor nativo já compilado em modo visual de desenvolvimento. Alterações salvas em `src/qml/` recarregam a interface automaticamente, sem compilar ou recriar o executável. Para alterar C++, dependências nativas ou o MCP, faça uma nova build com `npm run rebuild:dev`. Para apenas compilar, sem abrir a janela, execute `npm run build:dev`.

O primeiro fork sai com o catálogo online de complementos e a verificação de atualizações desativados por padrão. Assim, o aplicativo não depende da infraestrutura da CutWire. Eles podem ser ligados futuramente por uma infraestrutura pública do próprio Nardoto.

## Licença e contribuição

Nardoto Editor é distribuído sob a [GNU GPL v3 ou posterior](LICENSE). Ao redistribuir uma versão modificada, disponibilize o código-fonte correspondente sob a mesma licença e preserve os avisos de autoria e licença.

Contribuições são bem-vindas por issues e pull requests neste repositório.
