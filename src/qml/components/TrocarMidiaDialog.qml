import QtQuick
import QtQuick.Controls.Basic
import Drift

// Janela "Trocar a mídia da cena": mostra a fala da cena e opções buscadas pelo Nardoto Studio
// (servidor local: midia_consultas, midia_buscar, midia_baixar, midia_youtube_buscar,
// midia_youtube_trecho). A escolhida vai para a pasta do projeto e entra no lugar da antiga, com a
// mesma duração (EditorState.replaceClipMedia; Ctrl+Z desfaz).
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
    property string estado: ""        // "" | buscando | baixando
    property string aviso: ""
    property var pedidos: ({})        // reqId -> ação, para ignorar respostas antigas

    readonly property real duracaoCena: Math.max(0, (cena.end || 0) - (cena.start || 0))

    parent: Overlay.overlay
    anchors.centerIn: parent
    width: Math.min(1040, (parent ? parent.width : 1040) - 60)
    height: Math.min(760, (parent ? parent.height : 760) - 50)
    modal: true
    padding: 18
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    background: Rectangle { color: "#121212"; radius: 12 }
    Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.6) }

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
        root.estado = "buscando"
        root.aviso = ""
        root.opcoes = []
        root.escolhida = null
        pedir("midia_buscar", { consulta: q, tipo: root.tipo, orientacao: root.orientacao(),
                                duracaoMinima: Math.floor(root.duracaoCena) }, 90000)
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
        root.estado = "baixando"
        root.aviso = ""
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
            if (acao === "midia_consultas") {
                root.sugerindo = false
                if (!ok)
                    return
                root.consultas = (data.consultas || []).map(c => c.termo)
                if (root.consultas.length && campoBusca.text.length === 0)
                    root.buscar(root.consultas[0])
                if (root.consultas.length && campoYt.text.length === 0)
                    campoYt.text = root.consultas[0]
                return
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

            GridView {
                id: grade
                width: parent.width
                height: root.availableHeight - painelBancos.y - y - 50
                clip: true
                cellWidth: Math.floor(width / 4)
                cellHeight: 156
                model: root.opcoes
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
                                inicioYt.value = Math.min(30, Math.max(0, yt.modelData.duracao - 10))
                            }
                        }
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                    }
                }

                // Escolha do pedaço (até 8 s)
                Column {
                    width: parent.width - listaYt.width - parent.spacing
                    spacing: 8
                    visible: root.ytEscolhido !== null
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
                        to: root.ytEscolhido ? Math.max(1, root.ytEscolhido.duracao - 1) : 1
                        stepSize: 1
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
