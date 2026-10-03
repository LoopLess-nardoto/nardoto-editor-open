import QtQuick
import QtQuick.Controls.Basic
import QtMultimedia
import Drift

// Janela "Trocar a mídia da cena": mostra a fala da cena e opções buscadas pelo Nardoto Studio
// (servidor local: midia_consultas, midia_buscar, midia_baixar, midia_youtube_buscar,
// midia_youtube_previa, midia_youtube_trecho). A escolhida vai para a pasta do projeto e entra no lugar da antiga, com a
// mesma duração (EditorState.replaceClipMedia; Ctrl+Z desfaz).
// Sem o Studio aberto, a aba "Bancos" busca no Pexels e no Pixabay pela loja de mídia própria do
// Editor (Market) e baixa por ela. "Sem Studio" vem do retorno do próprio pedido (data.semStudio).
// Mockup: NardotoStudio/docs/mockup-editor-trocar-midia.html
Popup {
    id: root

    signal trocada()

    property var cena: ({})
    property int numero: 0
    property string aba: "bancos"     // bancos | youtube | ia | computador
    property string tipo: "video"     // video | imagem
    property var consultas: []        // sugestões de busca (IA ou vocabulário)
    property bool sugerindo: false
    property var opcoes: []
    property var escolhida: null
    property var ytOpcoes: []
    property var ytEscolhido: null
    property var ytTrecho: null       // {arquivo, quadros, ini, dur}
    property bool ytPreviaCarregando: false
    property bool ytPreviaErro: false
    property bool ytPreviaIniciando: false
    property real ytDuracao: 0
    property string estado: ""        // "" | buscando | baixando
    property string aviso: ""
    property var pedidos: ({})        // reqId -> ação, para ignorar respostas antigas
    property string studio: "?"       // ? (ainda não sei) | sim | nao: decidido pelo retorno do pedido
    property string consultaAtual: ""
    // Bancos pelo Market (sem Studio): a busca anda provedor por provedor (marketFila).
    property var marketOpcoes: []
    property var marketListas: []
    property var marketFila: []
    property string marketFase: ""    // "" | catalogo | buscando
    property bool marketAguardando: false
    property bool marketTentouCatalogo: false
    property string marketErro: ""
    property string marketBaixando: ""

    readonly property bool semStudio: studio === "nao"
    readonly property real duracaoCena: Math.max(0, (cena.end || 0) - (cena.start || 0))
    readonly property int ytInicioMs: Math.round(inicioYt.value * 1000)
    readonly property int ytFimMs: Math.round(Math.min(ytDuracao, inicioYt.value + durYt.value) * 1000)

    parent: Overlay.overlay
    anchors.centerIn: parent
    width: Math.min(1040, (parent ? parent.width : 1040) - 60)
    height: Math.min(760, (parent ? parent.height : 760) - 50)
    modal: true
    padding: 18
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    background: Rectangle { color: "#121212"; radius: 12 }
    Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.6) }

    onYtEscolhidoChanged: {
        pararPreviaYoutube()
        ytDuracao = ytEscolhido ? Number(ytEscolhido.duracao) : 0
        if (!ytEscolhido)
            return
        inicioYt.value = Math.min(30, Math.max(0, ytDuracao - 10))
        ytPreviaCarregando = true
        pedir("midia_youtube_previa", { id: ytEscolhido.id }, 65000)
    }
    onAboutToHide: pararPreviaYoutube()
    onAbaChanged: {
        if (aba !== "youtube")
            playerYt.pause()
        else if (visible && playerYt.source.toString().length && !ytPreviaCarregando && !ytPreviaErro)
            playerYt.play()
    }

    function pararPreviaYoutube() {
        root.pedidos = Object.assign({}, root.pedidos, { midia_youtube_previa: "" })
        root.ytPreviaCarregando = false
        root.ytPreviaIniciando = false
        root.ytPreviaErro = false
        playerYt.stop()
        playerYt.source = ""
    }

    function falharPreviaYoutube() {
        pararPreviaYoutube()
        root.ytPreviaErro = true
    }

    function iniciarPreviaYoutube() {
        if (!root.ytPreviaIniciando || !playerYt.seekable
                || (playerYt.mediaStatus !== MediaPlayer.LoadedMedia
                    && playerYt.mediaStatus !== MediaPlayer.BufferedMedia))
            return
        root.ytPreviaIniciando = false
        root.ytPreviaCarregando = false
        playerYt.position = root.ytInicioMs
        if (root.visible && root.aba === "youtube")
            playerYt.play()
    }

    MediaPlayer {
        id: playerYt
        videoOutput: videoYt
        audioOutput: AudioOutput { id: audioYt }
        onSeekableChanged: root.iniciarPreviaYoutube()
        onMediaStatusChanged: {
            if (mediaStatus === MediaPlayer.InvalidMedia) {
                root.falharPreviaYoutube()
            } else if (mediaStatus === MediaPlayer.EndOfMedia && root.visible
                       && root.aba === "youtube" && !root.ytPreviaErro) {
                position = root.ytInicioMs
                play()
            } else {
                root.iniciarPreviaYoutube()
            }
        }
        onPositionChanged: function() {
            if (playbackState === MediaPlayer.PlayingState && seekable && !root.ytPreviaIniciando
                    && playerYt.position >= root.ytFimMs && root.ytFimMs > root.ytInicioMs)
                playerYt.position = root.ytInicioMs
        }
        onErrorOccurred: {
            if (source.toString().length)
                root.falharPreviaYoutube()
        }
    }

    Timer {
        interval: 30000
        running: root.ytPreviaCarregando && playerYt.source.toString().length > 0
        onTriggered: root.falharPreviaYoutube()
    }

    function abrir(c, n) {
        root.cena = c
        root.numero = n
        root.aba = "bancos"
        root.opcoes = []
        root.escolhida = null
        root.ytOpcoes = []
        root.ytEscolhido = null
        root.ytTrecho = null
        root.aviso = ""
        root.consultas = []
        root.estado = ""
        root.studio = "?"
        root.consultaAtual = ""
        root.marketOpcoes = []
        root.marketListas = []
        root.marketFase = ""
        root.marketAguardando = false
        root.marketBaixando = ""
        campoBusca.text = ""
        campoYt.text = ""
        open()
        if (c.fala && c.fala.length) {
            root.sugerindo = true
            pedir("midia_consultas", { fala: c.fala, contexto: EditorState.projectName }, 60000)
        }
    }

    function orientacao() {
        const w = EditorState.projectWidth(), h = EditorState.projectHeight()
        return w > h * 1.1 ? "horizontal" : (h > w * 1.1 ? "vertical" : "quadrada")
    }

    function pastaTrocas() {
        const base = EditorState.projectFolder()
        return (base.length ? base : (root.cena.path || "").replace(/[\\/][^\\/]*$/, "")) + "/midias/trocas"
    }

    function pedir(acao, params, prazo) {
        const id = acao + ":" + Date.now()
        const p = root.pedidos
        p[acao] = id
        root.pedidos = p
        EditorState.studioRequest(id, acao, params, prazo)
    }

    function buscar(termo) {
        if (termo !== undefined)
            campoBusca.text = termo
        const q = campoBusca.text.trim()
        if (!q.length)
            return
        root.consultaAtual = q
        root.aviso = ""
        root.escolhida = null
        if (root.semStudio) {
            root.buscarMarket(q)
            return
        }
        root.estado = "buscando"
        root.opcoes = []
        pedir("midia_buscar", { consulta: q, tipo: root.tipo, orientacao: root.orientacao(),
                                duracaoMinima: Math.floor(root.duracaoCena) }, 90000)
    }

    // ---- Bancos sem Studio: Pexels e Pixabay pela loja do Editor (Market) ----

    // Id do tipo do Market que corresponde ao botão Vídeos/Imagens (fora o chroma key).
    function marketTipoId() {
        const alvo = root.tipo === "imagem" ? "image" : "video"
        const tipos = Market.types
        let achado = ""
        for (let i = 0; i < tipos.length; ++i) {
            const t = tipos[i]
            if ((t.media_kind || t.id) !== alvo || t.id === "greenscreen")
                continue
            if (!achado || t.id === "video" || t.id === "photo")
                achado = t.id
        }
        return achado
    }

    function marketIntercalar(listas) {
        const saida = []
        const n = Math.max(0, ...listas.map(l => l.length))
        for (let i = 0; i < n; ++i)
            for (const l of listas)
                if (i < l.length)
                    saida.push(l[i])
        return saida
    }

    function marketFalhar(msg) {
        root.marketFase = ""
        root.marketAguardando = false
        root.estado = ""
        root.aviso = msg
    }

    function buscarMarket(q) {
        root.marketOpcoes = []
        root.marketListas = []
        root.marketFila = []
        root.marketErro = ""
        root.marketFase = ""
        root.marketAguardando = false
        root.estado = ""
        if (!Market.configured) {
            root.aviso = qsTr("A loja de mídia não está disponível nesta versão do editor.")
            return
        }
        // Os termos da loja precisam ser aceitos uma vez: o painel logo abaixo pede isso.
        if (!Market.consented)
            return
        root.estado = "buscando"
        root.marketTentouCatalogo = false
        root.marketFase = "catalogo"
        root.marketPasso()
    }

    function marketPasso() {
        if (root.marketFase === "catalogo") {
            const tipoId = root.marketTipoId()
            if (!tipoId) {
                if (Market.catalogLoading)
                    return
                if (Market.types.length > 0 || root.marketTentouCatalogo) {
                    root.marketFalhar(Market.catalogError.length ? Market.catalogError
                                      : qsTr("A loja não tem este tipo de mídia agora."))
                    return
                }
                root.marketTentouCatalogo = true
                Market.refreshCatalog()
                return
            }
            if (Market.activeTypeId !== tipoId)
                Market.activeTypeId = tipoId
            const ids = []
            for (const p of Market.providers)
                if (/pexels|pixabay/i.test(String(p.id) + " " + String(p.label)))
                    ids.push(p.id)
            if (!ids.length) {
                root.marketFalhar(qsTr("O Pexels e o Pixabay não estão disponíveis na loja agora."))
                return
            }
            root.marketFila = ids
            root.marketFase = "buscando"
        }
        if (root.marketFase !== "buscando" || Market.searching)
            return
        if (!root.marketFila.length) {
            root.marketFase = ""
            root.estado = ""
            if (!root.marketOpcoes.length)
                root.aviso = root.marketErro.length ? root.marketErro : qsTr("Nada encontrado. Tente outra sugestão.")
            return
        }
        Market.activeProviderId = root.marketFila[0]
        root.marketFila = root.marketFila.slice(1)
        root.marketAguardando = true
        Market.search(root.consultaAtual, {})
        if (!Market.searching)
            Qt.callLater(root.marketColher)
    }

    function marketColher() {
        if (!root.marketAguardando || Market.searching)
            return
        root.marketAguardando = false
        if (root.marketFase !== "buscando")
            return
        if (Market.searchError.length) {
            root.marketErro = Market.searchError
        } else {
            let rotulo = Market.activeProviderId
            for (const p of Market.providers)
                if (p.id === Market.activeProviderId)
                    rotulo = p.label
            const lista = []
            for (const it of Market.items) {
                const imagem = (it.media_kind || it.type) === "image"
                lista.push({
                    id: it.id,
                    miniatura: it.thumb_url || "",
                    fonte: rotulo,
                    duracao: Number(it.duration_ms || 0) / 1000,
                    tipo: imagem ? "imagem" : "video",
                    licenca: it.license ? (it.license.name || it.license.attribution || "") : "",
                    titulo: it.title || "",
                    baixavel: it.downloadable !== false,
                    market: true
                })
            }
            root.marketListas = root.marketListas.concat([lista])
            root.marketOpcoes = root.marketIntercalar(root.marketListas)
        }
        root.marketPasso()
    }

    function baixarMarket() {
        const item = root.escolhida
        if (!item.baixavel) {
            root.aviso = qsTr("O limite diário de downloads desta fonte acabou. Tente outra mídia ou volte amanhã.")
            return
        }
        root.estado = "baixando"
        root.marketBaixando = item.id
        Market.download(item.id, "", EditorState.fileUrl(root.pastaTrocas()), item.titulo,
                        root.tipo === "imagem" ? "image" : "video")
    }

    function buscarYoutube(termo) {
        if (termo !== undefined)
            campoYt.text = termo
        const q = campoYt.text.trim()
        if (!q.length)
            return
        root.estado = "buscando"
        root.aviso = ""
        root.ytOpcoes = []
        root.ytEscolhido = null
        root.ytTrecho = null
        pedir("midia_youtube_buscar", { consulta: q }, 60000)
    }

    function verPedaco() {
        if (!root.ytEscolhido)
            return
        root.estado = "baixando"
        root.aviso = ""
        root.ytTrecho = null
        pedir("midia_youtube_trecho", { id: root.ytEscolhido.id, ini: inicioYt.value, dur: durYt.value,
                                        pasta: root.pastaTrocas() }, 180000)
    }

    function usar() {
        if (root.aba === "youtube") {
            if (root.ytTrecho)
                root.aplicar(root.ytTrecho.arquivo)
            return
        }
        if (!root.escolhida)
            return
        root.aviso = ""
        if (root.escolhida.market) {
            root.baixarMarket()
            return
        }
        root.estado = "baixando"
        pedir("midia_baixar", {
            item: root.escolhida,
            pasta: root.pastaTrocas(),
            nome: "cena-" + (root.numero < 10 ? "0" : "") + root.numero + "-" + root.escolhida.fonte
        }, 180000)
    }

    function aplicar(arquivo) {
        const erro = EditorState.replaceClipMedia(root.cena.clipId, arquivo)
        root.estado = ""
        if (erro.length) {
            root.aviso = erro
            return
        }
        Toasts.success(qsTr("Mídia da cena %1 trocada. Ctrl+Z desfaz.").arg(root.numero))
        root.trocada()
        root.close()
    }

    function caminhoDe(url) {
        let s = url.toString()
        s = s.replace(/^file:\/\/\//, "").replace(/^file:\/\//, "")
        return decodeURIComponent(s)
    }

    function relogio(s) {
        const t = Math.max(0, Math.floor(s))
        return Math.floor(t / 60) + ":" + (t % 60 < 10 ? "0" : "") + (t % 60)
    }

    Connections {
        target: EditorState
        function onStudioReply(reqId, ok, data, erro) {
            const acao = reqId.split(":")[0]
            if (root.pedidos[acao] !== reqId)
                return
            if (acao === "midia_youtube_previa") {
                if (!root.visible || !root.ytEscolhido)
                    return
                if (!ok || !data.url) {
                    root.falharPreviaYoutube()
                    return
                }
                root.ytDuracao = Number(data.duracao) || root.ytDuracao
                root.ytPreviaIniciando = true
                playerYt.source = data.url
                return
            }
            if (acao === "midia_consultas") {
                root.sugerindo = false
                if (!ok) {
                    if (data.semStudio)
                        root.studio = "nao"
                    return
                }
                root.studio = "sim"
                root.consultas = (data.consultas || []).map(c => c.termo)
                if (root.consultas.length && campoBusca.text.length === 0)
                    root.buscar(root.consultas[0])
                if (root.consultas.length && campoYt.text.length === 0)
                    campoYt.text = root.consultas[0]
                return
            }
            if (acao === "midia_buscar") {
                if (!ok && data.semStudio) {
                    root.studio = "nao"
                    root.buscarMarket(root.consultaAtual)
                    return
                }
                if (ok)
                    root.studio = "sim"
            }
            root.estado = ""
            if (!ok) {
                root.aviso = erro
                return
            }
            if (acao === "midia_buscar") {
                root.opcoes = data.opcoes || []
                if (!root.opcoes.length)
                    root.aviso = qsTr("Nada encontrado. Tente outra sugestão.")
            } else if (acao === "midia_baixar") {
                root.aplicar(data.arquivo)
            } else if (acao === "midia_youtube_buscar") {
                root.ytOpcoes = data.opcoes || []
                if (!root.ytOpcoes.length)
                    root.aviso = qsTr("Nada encontrado no YouTube. Tente outra busca.")
            } else if (acao === "midia_youtube_trecho") {
                root.ytTrecho = data
            }
        }
    }

    Connections {
        target: Market
        function onSearchingChanged() {
            if (!Market.searching && root.marketAguardando)
                Qt.callLater(root.marketColher)
        }
        // Depois que o Market termina de aplicar o catálogo (ele escolhe o tipo ativo por conta própria).
        function onCatalogLoadingChanged() {
            if (!Market.catalogLoading && root.marketFase === "catalogo")
                Qt.callLater(root.marketPasso)
        }
        function onDownloadImported(itemId, name) {
            if (itemId !== root.marketBaixando)
                return
            root.marketBaixando = ""
            for (const d of Market.downloads)
                if (d.itemId === itemId && d.filePath.length) {
                    root.aplicar(d.filePath)
                    return
                }
            root.estado = ""
            root.aviso = qsTr("O arquivo baixado não foi encontrado.")
        }
        function onDownloadFailed(itemId, code, message) {
            if (itemId !== root.marketBaixando)
                return
            root.marketBaixando = ""
            root.estado = ""
            root.aviso = message
        }
    }

    component Aba: Rectangle {
        id: abaItem
        property string id_: ""
        property string texto: ""
        width: rot.implicitWidth + 28
        height: 30
        radius: 7
        color: root.aba === id_ ? "#2a1a12" : (abaHover.hovered ? Theme.accent : "transparent")
        Text {
            id: rot
            anchors.centerIn: parent
            text: abaItem.texto
            color: root.aba === abaItem.id_ ? Theme.primary : Theme.mutedForeground
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSizeSm
        }
        HoverHandler { id: abaHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: { root.aba = abaItem.id_; root.aviso = "" } }
    }

    // Sugestões de busca clicáveis (feitas pela IA a partir da fala).
    component Sugestoes: Flow {
        id: sug
        property var acao
        width: parent ? parent.width : 0
        spacing: 6
        Text {
            height: 26
            verticalAlignment: Text.AlignVCenter
            text: root.sugerindo ? qsTr("A IA está lendo a fala e sugerindo buscas...") : qsTr("Sugestões para esta fala:")
            color: Theme.mutedForeground
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSizeXs
        }
        Repeater {
            model: root.consultas
            delegate: Rectangle {
                required property string modelData
                width: chipTxt.implicitWidth + 18
                height: 26
                radius: 13
                color: chipHover.hovered ? "#2a1a12" : Theme.panelBackground
                Text {
                    id: chipTxt
                    anchors.centerIn: parent
                    text: parent.modelData
                    color: chipHover.hovered ? Theme.primary : Theme.foreground
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSizeXs
                }
                HoverHandler { id: chipHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: sug.acao(parent.modelData) }
            }
        }
    }

    contentItem: Item {
    Column {
        width: parent.width
        spacing: 12

        // Cabeçalho: mídia atual e fala da cena
        Row {
            width: parent.width
            spacing: 14
            Rectangle {
                width: 190; height: 107; radius: 7; color: "#000"; clip: true
                Image {
                    anchors.fill: parent
                    source: root.cena.thumbnail || ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                }
                Rectangle {
                    x: 6; y: 6; width: atualTxt.implicitWidth + 10; height: 18; radius: 4
                    color: Qt.rgba(0, 0, 0, 0.75)
                    Text { id: atualTxt; anchors.centerIn: parent; text: qsTr("MÍDIA ATUAL"); color: "white"
                           font.family: Theme.fontFamily; font.pixelSize: 10; font.weight: Font.Bold }
                }
            }
            Column {
                width: parent.width - 190 - parent.spacing
                spacing: 4
                Text {
                    text: qsTr("Trocar a mídia da cena %1").arg(root.numero)
                    color: Theme.foreground
                    font.family: Theme.fontFamily
                    font.pixelSize: 17
                    font.weight: Font.Bold
                }
                Text {
                    text: qsTr("A mídia nova entra no mesmo lugar e com a mesma duração (%1 s). Ctrl+Z desfaz.")
                          .arg(root.duracaoCena.toFixed(1).replace(".", ","))
                    color: Theme.mutedForeground
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSizeXs
                }
                Rectangle {
                    width: parent.width
                    height: falaTxt.implicitHeight + 16
                    radius: 8
                    color: Theme.panelBackground
                    Text {
                        id: falaTxt
                        x: 10; y: 8
                        width: parent.width - 20
                        text: root.cena.fala ? "\"" + root.cena.fala + "\"" : qsTr("(sem fala neste trecho)")
                        color: Theme.foreground
                        wrapMode: Text.WordWrap
                        maximumLineCount: 3
                        elide: Text.ElideRight
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSizeSm
                    }
                }
            }
        }

        Rectangle {
            width: abas.implicitWidth + 6
            height: 36
            radius: 9
            color: Theme.panelBackground
            Row {
                id: abas
                anchors.centerIn: parent
                spacing: 2
                Aba { id_: "bancos"; texto: qsTr("Bancos de vídeo e imagem") }
                Aba { id_: "youtube"; texto: qsTr("YouTube") }
                Aba { id_: "ia"; texto: qsTr("Gerar com IA") }
                Aba { id_: "computador"; texto: qsTr("Do computador") }
            }
        }

        // ---------------- Bancos ----------------
        Column {
            id: painelBancos
            visible: root.aba === "bancos"
            width: parent.width
            spacing: 8

            Row {
                width: parent.width
                spacing: 8
                ThemedTextField {
                    id: campoBusca
                    width: parent.width - buscarBtn.width - videosBtn.width - imagensBtn.width - 3 * parent.spacing
                    placeholderText: qsTr("O que buscar (em inglês acha mais coisa)")
                    onAccepted: root.buscar()
                }
                ThemedButton {
                    id: videosBtn
                    text: qsTr("Vídeos"); variant: root.tipo === "video" ? "primary" : "secondary"
                    onClicked: { root.tipo = "video"; root.buscar() }
                }
                ThemedButton {
                    id: imagensBtn
                    text: qsTr("Imagens"); variant: root.tipo === "imagem" ? "primary" : "secondary"
                    onClicked: { root.tipo = "imagem"; root.buscar() }
                }
                ThemedButton {
                    id: buscarBtn
                    variant: "primary"
                    glyph: Theme.icons.search
                    text: qsTr("Buscar")
                    enabled: root.estado === ""
                    onClicked: root.buscar()
                }
            }

            Sugestoes { acao: (t) => root.buscar(t) }

            Text {
                visible: root.studio !== "?"
                width: parent.width
                elide: Text.ElideRight
                text: root.semStudio
                      ? qsTr("Sem o Nardoto Studio: Pexels e Pixabay. Abra o Studio para buscar em mais de 30 acervos.")
                      : qsTr("Buscando em todos os acervos do Nardoto Studio")
                color: Theme.mutedForeground
                font.family: Theme.fontFamily
                font.pixelSize: Math.round(Theme.fontSizeXs)
            }

            // Termos da loja de mídia do Editor, aceitos uma única vez.
            Rectangle {
                visible: root.semStudio && Market.configured && !Market.consented
                width: parent.width
                height: termosLinha.implicitHeight + 16
                radius: 8
                color: Theme.panelBackground
                Row {
                    id: termosLinha
                    x: 10
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 20
                    spacing: 12
                    Text {
                        width: parent.width - aceitarBtn.width - parent.spacing
                        anchors.verticalCenter: parent.verticalCenter
                        wrapMode: Text.WordWrap
                        text: qsTr("Os bancos grátis vêm de terceiros, com limite diário de downloads e sem garantia de disponibilidade. Você é responsável por ter o direito de usar o que baixar.")
                        color: Theme.foreground
                        font.family: Theme.fontFamily
                        font.pixelSize: Math.round(Theme.fontSizeXs)
                    }
                    ThemedButton {
                        id: aceitarBtn
                        anchors.verticalCenter: parent.verticalCenter
                        variant: "primary"
                        text: qsTr("Entendi, buscar")
                        onClicked: {
                            Market.acceptTerms()
                            root.buscar()
                        }
                    }
                }
            }

            GridView {
                id: grade
                width: parent.width
                height: root.availableHeight - painelBancos.y - y - 50
                clip: true
                cellWidth: Math.floor(width / 4)
                cellHeight: 156
                model: root.semStudio ? root.marketOpcoes : root.opcoes
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                delegate: Item {
                    id: op
                    required property var modelData
                    width: grade.cellWidth
                    height: grade.cellHeight
                    readonly property bool sel: root.escolhida && root.escolhida.id === modelData.id
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 5
                        radius: 8
                        color: Theme.panelBackground
                        border.width: op.sel ? 2 : 0
                        border.color: Theme.primary
                        clip: true
                        Rectangle {
                            width: parent.width; height: parent.height - 26
                            color: "#000"
                            radius: 8
                            clip: true
                            Image {
                                anchors.fill: parent
                                anchors.margins: op.sel ? 2 : 0
                                source: op.modelData.miniatura || ""
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                            }
                            Rectangle {
                                x: 6; y: 6; width: fonteTxt.implicitWidth + 10; height: 17; radius: 4
                                color: Qt.rgba(0, 0, 0, 0.75)
                                Text { id: fonteTxt; anchors.centerIn: parent; text: op.modelData.fonte; color: "white"
                                       font.family: Theme.fontFamily; font.pixelSize: 10; font.weight: Font.Bold }
                            }
                            Rectangle {
                                anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: 6
                                width: durTxt.implicitWidth + 10; height: 17; radius: 4
                                color: Qt.rgba(0, 0, 0, 0.75)
                                Text {
                                    id: durTxt; anchors.centerIn: parent; color: "white"
                                    font.family: Theme.fontFamily; font.pixelSize: 10
                                    text: op.modelData.tipo === "imagem" ? qsTr("imagem") : root.relogio(op.modelData.duracao)
                                }
                            }
                        }
                        Text {
                            anchors.bottom: parent.bottom; anchors.bottomMargin: 6
                            x: 8; width: parent.width - 16
                            elide: Text.ElideRight
                            text: (op.modelData.licenca || qsTr("licença não informada"))
                            color: Theme.mutedForeground
                            font.family: Theme.fontFamily
                            font.pixelSize: 11
                        }
                        TapHandler { onTapped: root.escolhida = op.modelData }
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                    }
                }
            }
        }

        // ---------------- YouTube ----------------
        Column {
            id: painelYt
            visible: root.aba === "youtube"
            width: parent.width
            spacing: 8

            Row {
                width: parent.width
                spacing: 8
                ThemedTextField {
                    id: campoYt
                    width: parent.width - buscarYtBtn.width - parent.spacing
                    placeholderText: qsTr("O que buscar no YouTube (português ou inglês)")
                    onAccepted: root.buscarYoutube()
                }
                ThemedButton {
                    id: buscarYtBtn
                    variant: "primary"
                    glyph: Theme.icons.search
                    text: qsTr("Buscar no YouTube")
                    enabled: root.estado === ""
                    onClicked: root.buscarYoutube()
                }
            }

            Sugestoes { acao: (t) => root.buscarYoutube(t) }

            Row {
                width: parent.width
                height: root.availableHeight - painelYt.y - y - 50
                spacing: 12

                ListView {
                    id: listaYt
                    width: parent.width * 0.55
                    height: parent.height
                    clip: true
                    spacing: 6
                    model: root.ytOpcoes
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                    delegate: Rectangle {
                        id: yt
                        required property var modelData
                        readonly property bool sel: root.ytEscolhido && root.ytEscolhido.id === modelData.id
                        width: listaYt.width - 8
                        height: 74
                        radius: 8
                        color: sel ? "#2a1a12" : Theme.panelBackground
                        border.width: sel ? 1 : 0
                        border.color: Theme.primary
                        Row {
                            x: 6; y: 6
                            spacing: 10
                            Image {
                                width: 110; height: 62
                                source: yt.modelData.miniatura
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                            }
                            Column {
                                width: yt.width - 110 - 30
                                spacing: 3
                                Text {
                                    width: parent.width
                                    text: yt.modelData.titulo
                                    elide: Text.ElideRight
                                    color: Theme.foreground
                                    font.family: Theme.fontFamily
                                    font.pixelSize: 12
                                    font.weight: Font.Bold
                                }
                                Text {
                                    width: parent.width
                                    text: yt.modelData.canal + "  ·  " + root.relogio(yt.modelData.duracao)
                                    elide: Text.ElideRight
                                    color: Theme.mutedForeground
                                    font.family: Theme.fontFamily
                                    font.pixelSize: 11
                                }
                                Rectangle {
                                    width: licTxt.implicitWidth + 12; height: 18; radius: 4
                                    color: yt.modelData.cc ? "#1f3b26" : "#3b1f1f"
                                    Text {
                                        id: licTxt
                                        anchors.centerIn: parent
                                        text: yt.modelData.licenca
                                        color: yt.modelData.cc ? "#7be495" : "#ff8a80"
                                        font.family: Theme.fontFamily
                                        font.pixelSize: 10
                                        font.weight: Font.Bold
                                    }
                                }
                            }
                        }
                        TapHandler {
                            onTapped: {
                                root.ytEscolhido = yt.modelData
                                root.ytTrecho = null
                            }
                        }
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                    }
                }

                // Escolha do pedaço (até 8 s)
                Flickable {
                    id: escolhaYt
                    width: parent.width - listaYt.width - parent.spacing
                    height: parent.height
                    contentHeight: controlesYt.height
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    visible: root.ytEscolhido !== null
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                    Column {
                        id: controlesYt
                        width: escolhaYt.width - 8
                        spacing: 6

                        Rectangle {
                            width: parent.width
                            height: width * 9 / 16
                            color: Theme.panelBackground
                            clip: true
                            Image {
                                anchors.fill: parent
                                visible: root.ytPreviaCarregando || root.ytPreviaErro
                                source: root.ytEscolhido ? root.ytEscolhido.miniatura : ""
                                fillMode: Image.PreserveAspectFit
                                asynchronous: true
                            }
                            VideoOutput {
                                id: videoYt
                                anchors.fill: parent
                                visible: !root.ytPreviaCarregando && !root.ytPreviaErro
                                fillMode: VideoOutput.PreserveAspectFit
                            }
                            Rectangle {
                                anchors.fill: parent
                                visible: root.ytPreviaCarregando || root.ytPreviaErro
                                color: Theme.scrimStrong
                                Text {
                                    anchors.centerIn: parent
                                    width: parent.width - 24
                                    horizontalAlignment: Text.AlignHCenter
                                    wrapMode: Text.WordWrap
                                    text: root.ytPreviaErro ? qsTr("Prévia indisponível para este vídeo")
                                                           : qsTr("Carregando prévia...")
                                    color: Theme.onMedia
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Math.round(Theme.fontSizeSm)
                                }
                            }
                        }
                        Row {
                            width: parent.width
                            spacing: 6
                            ThemedButton {
                                variant: "primary"
                                flat: true
                                text: playerYt.playbackState === MediaPlayer.PlayingState ? qsTr("Pausar") : qsTr("Tocar")
                                glyph: playerYt.playbackState === MediaPlayer.PlayingState ? Theme.icons.pause : Theme.icons.play
                                topPadding: 5
                                bottomPadding: 5
                                font.pixelSize: Math.round(Theme.fontSizeXs)
                                enabled: !root.ytPreviaCarregando && !root.ytPreviaErro && playerYt.seekable
                                onClicked: {
                                    if (playerYt.playbackState === MediaPlayer.PlayingState) {
                                        playerYt.pause()
                                    } else {
                                        if (playerYt.position < root.ytInicioMs || playerYt.position >= root.ytFimMs)
                                            playerYt.position = root.ytInicioMs
                                        playerYt.play()
                                    }
                                }
                            }
                            ThemedButton {
                                variant: "ghost"
                                flat: true
                                text: audioYt.muted ? qsTr("Sem som") : qsTr("Com som")
                                tooltip: audioYt.muted ? qsTr("Ativar som") : qsTr("Silenciar")
                                topPadding: 5
                                bottomPadding: 5
                                leftPadding: 8
                                rightPadding: 8
                                font.pixelSize: Math.round(Theme.fontSizeXs)
                                onClicked: audioYt.muted = !audioYt.muted
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.relogio(playerYt.position / 1000) + " / " + root.relogio(root.ytDuracao)
                                color: Theme.mutedForeground
                                font.family: Theme.fontFamily
                                font.pixelSize: Math.round(Theme.fontSizeXs)
                            }
                        }
                        Text {
                            width: parent.width
                            wrapMode: Text.WordWrap
                            text: qsTr("Escolha o pedaço (máximo 8 s)")
                            color: Theme.foreground
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSizeSm
                            font.weight: Font.Bold
                        }
                        Text {
                            text: qsTr("Começa em %1 do vídeo").arg(root.relogio(inicioYt.value))
                            color: Theme.mutedForeground
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSizeXs
                        }
                        Slider {
                            id: inicioYt
                            width: parent.width
                            from: 0
                            to: Math.max(1, root.ytDuracao - 1)
                            stepSize: 1
                            onMoved: {
                                if (playerYt.seekable)
                                    playerYt.position = root.ytInicioMs
                            }
                        }
                        Text {
                            text: qsTr("Duração do pedaço: %1 s").arg(durYt.value)
                            color: Theme.mutedForeground
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSizeXs
                        }
                        Slider {
                            id: durYt
                            width: parent.width
                            from: 1
                            to: 8
                            stepSize: 1
                            value: Math.max(1, Math.min(8, Math.round(root.duracaoCena)))
                            onMoved: {
                                if (playerYt.seekable && playerYt.position >= root.ytFimMs)
                                    playerYt.position = root.ytInicioMs
                            }
                        }
                        ThemedButton {
                            text: root.estado === "baixando" ? qsTr("Baixando o pedaço...") : qsTr("Ver o pedaço")
                            glyph: Theme.icons.image
                            enabled: root.estado === ""
                            onClicked: root.verPedaco()
                        }
                        Image {
                            visible: root.ytTrecho !== null && (root.ytTrecho.quadros || "").length > 0
                            width: parent.width
                            height: width / 4 * 9 / 16
                            source: root.ytTrecho && root.ytTrecho.quadros ? EditorState.fileUrl(root.ytTrecho.quadros) : ""
                            fillMode: Image.PreserveAspectFit
                            cache: false
                        }
                        Text {
                            visible: root.ytTrecho !== null
                            width: parent.width
                            wrapMode: Text.WordWrap
                            text: qsTr("Pedaço baixado. Se gostou, clique em \"Usar este pedaço\".")
                            color: "#9be37d"
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSizeXs
                        }
                    }
                }
            }
        }

        // ---------------- Gerar com IA: próxima etapa ----------------
        Text {
            visible: root.aba === "ia"
            width: parent.width
            wrapMode: Text.WordWrap
            text: qsTr("Gerar com IA (pedido pronto para o VEO3 ou imagem): chega na próxima etapa.")
            color: Theme.mutedForeground
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSizeSm
        }

        // ---------------- Do computador ----------------
        Column {
            visible: root.aba === "computador"
            width: parent.width
            spacing: 8
            Text {
                text: qsTr("Escolha um vídeo ou uma imagem do seu computador para entrar no lugar desta cena.")
                color: Theme.mutedForeground
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSizeSm
            }
            ThemedButton {
                variant: "primary"
                glyph: Theme.icons.folder
                text: qsTr("Escolher arquivo...")
                onClicked: {
                    const url = FileDialogs.openFile(qsTr("Escolher mídia"), [AssetLibrary.mediaNameFilter()])
                    if (url && url.toString() !== "")
                        root.aplicar(root.caminhoDe(url))
                }
            }
        }
    }

    // Rodapé fixo (dentro do conteúdo: Popup não tem footer)
    Item {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 36
        Text {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - botoes.width - 16
            elide: Text.ElideRight
            text: root.aviso.length ? root.aviso
                  : root.estado === "buscando" ? qsTr("Buscando opções...")
                  : root.estado === "baixando" ? qsTr("Baixando para a pasta do projeto...")
                  : root.aba === "youtube" ? qsTr("Escolha um vídeo, o início e a duração, e veja o pedaço antes de usar.")
                  : qsTr("Clique numa opção para escolher. O arquivo vai para a pasta do projeto, em midias/trocas.")
            color: root.aviso.length ? "#ff8a8a" : Theme.mutedForeground
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSizeXs
        }
        Row {
            id: botoes
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8
            ThemedButton { text: qsTr("Cancelar"); onClicked: root.close() }
            ThemedButton {
                variant: "primary"
                text: root.aba === "youtube" ? qsTr("Usar este pedaço") : qsTr("Usar esta mídia")
                enabled: root.estado === "" && (root.aba === "youtube" ? root.ytTrecho !== null
                                                                       : root.aba === "bancos" && root.escolhida !== null)
                onClicked: root.usar()
            }
        }
    }
}
}
