import QtQuick
import QtQuick.Controls.Basic
import Drift

// Tela inicial do desktop (ao abrir o editor sem projeto e em "Fechar projeto"). Mesma linguagem
// da grade de projetos do Nardoto Studio, com o que um editor de video tem de proprio: o ultimo
// projeto em destaque com a timeline dele em escala, cada card com a timeline em miniatura,
// duracao e formato, e "Novo projeto" ja perguntando o formato. Os dados de cada card vem de
// EditorState.projectSummary(), que le so o manifesto do arquivo.
// Mockup aprovado: NardotoStudio/docs/mockup-editor-tela-inicial.html
Rectangle {
    id: root

    signal newProjectRequested()
    signal newProjectWithFormatRequested(string templateId)
    signal newProjectWithMediaRequested(var urls)
    signal openProjectRequested()
    signal openRecentRequested(string path)
    signal exportRecentRequested(string path)

    color: Theme.appBackground

    property string filtro: "recentes" // "recentes" | "studio"
    property string busca: ""

    readonly property var todos: EditorState.recentProjects
    // Resumo de cada projeto calculado uma vez por mudanca da lista (le o manifesto do arquivo).
    readonly property var resumos: {
        const out = {}
        for (let i = 0; i < todos.length; ++i)
            out[todos[i].path] = todos[i].exists === false ? {} : EditorState.projectSummary(todos[i].path)
        return out
    }
    readonly property var itens: {
        const termo = busca.trim().toLowerCase()
        return todos.filter(p => (filtro !== "studio" || (resumos[p.path] || {}).fromStudio)
                                 && (termo.length === 0 || p.name.toLowerCase().indexOf(termo) >= 0))
    }
    readonly property var destaque: {
        for (let i = 0; i < todos.length; ++i)
            if (todos[i].exists !== false)
                return todos[i]
        return null
    }

    readonly property color corVideo: Theme.primary
    readonly property color corAudio: "#8E5BB8"
    readonly property color corLegenda: "#4A9BD6"
    readonly property color corTexto: "#C9A227"

    function corDaTrilha(tipo) {
        switch (tipo) {
        case "audio": return root.corAudio
        case "subtitle": return root.corLegenda
        case "text": return root.corTexto
        case "video": return root.corVideo
        default: return Theme.mutedForeground
        }
    }

    function nomeSemExtensao(nome) {
        return nome.replace(/\.(drift|json)$/i, "")
    }

    function duracaoTexto(seg) {
        if (!(seg > 0))
            return ""
        const total = Math.round(seg)
        const m = Math.floor(total / 60), s = total % 60
        return (m < 10 ? "0" + m : m) + ":" + (s < 10 ? "0" + s : s)
    }

    function quando(data) {
        if (!data)
            return ""
        const d = new Date(data)
        if (isNaN(d.getTime()))
            return ""
        const hoje = new Date()
        const ontem = new Date(hoje.getFullYear(), hoje.getMonth(), hoje.getDate() - 1)
        if (d.toDateString() === hoje.toDateString())
            return qsTr("Hoje, %1").arg(Qt.formatTime(d, "hh:mm"))
        if (d.toDateString() === ontem.toDateString())
            return qsTr("Ontem")
        return Qt.formatDate(d, "dd/MM/yyyy")
    }

    // Timeline em escala: uma faixa por trilha, blocos onde ha clipes.
    component MiniTimeline: Column {
        id: mini
        property var trilhas: []
        property real alturaFaixa: 5
        spacing: alturaFaixa >= 8 ? 4 : 3

        Repeater {
            model: mini.trilhas
            delegate: Item {
                id: faixa
                required property var modelData
                width: mini.width
                height: mini.alturaFaixa
                Repeater {
                    model: faixa.modelData.clips
                    delegate: Rectangle {
                        required property var modelData
                        x: modelData.x * mini.width
                        width: Math.max(2, modelData.w * mini.width - 1)
                        height: faixa.height
                        radius: 2
                        color: root.corDaTrilha(faixa.modelData.type)
                    }
                }
            }
        }
    }

    component Selo: Rectangle {
        property alias texto: rotulo.text
        property bool laranja: false
        width: rotulo.implicitWidth + 12
        height: 18
        radius: 5
        color: laranja ? Theme.primary : Qt.rgba(0, 0, 0, 0.65)
        Text {
            id: rotulo
            anchors.centerIn: parent
            color: "white"
            font.family: Theme.fontFamily
            font.pixelSize: 10
            font.weight: Font.Bold
        }
    }

    // Capa: o print salvo junto com o projeto, ou um fundo com o icone de filme.
    component Capa: Rectangle {
        id: capa
        property string fonte: ""
        color: "#101010"
        clip: true
        Image {
            anchors.fill: parent
            source: capa.fonte
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: false
            visible: status === Image.Ready
        }
        IconGlyph {
            anchors.centerIn: parent
            visible: capa.fonte.length === 0
            glyph: Theme.icons.film
            iconSize: 28
            iconColor: Qt.rgba(232 / 255, 90 / 255, 42 / 255, 0.45)
        }
    }

    component Pilula: Rectangle {
        id: pilula
        property string texto: ""
        property bool ativo: false
        signal escolhido()
        width: rotuloPilula.implicitWidth + 24
        height: 28
        radius: 7
        color: ativo ? "#2a1a12" : (pilulaHover.hovered ? Theme.accent : "transparent")
        Text {
            id: rotuloPilula
            anchors.centerIn: parent
            text: pilula.texto
            color: pilula.ativo ? Theme.primary : Theme.mutedForeground
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSizeSm
        }
        HoverHandler { id: pilulaHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: pilula.escolhido() }
    }

    component FormatoBotao: Rectangle {
        id: fmt
        property string templateId: ""
        property string rotulo: ""
        property real ladoW: 30
        property real ladoH: 17
        width: 70
        height: 52
        radius: 7
        color: fmtHover.hovered ? "#2a1a12" : "#1d1d1d"
        Column {
            anchors.centerIn: parent
            spacing: 5
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: fmt.ladoW
                height: fmt.ladoH
                radius: 2
                color: fmtHover.hovered ? Theme.primary : "#3a3a3a"
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: fmt.rotulo
                color: fmtHover.hovered ? Theme.primary : Theme.mutedForeground
                font.family: Theme.fontFamily
                font.pixelSize: 11
            }
        }
        HoverHandler { id: fmtHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: root.newProjectWithFormatRequested(fmt.templateId) }
    }

    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: conteudo.implicitHeight + 48
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: conteudo
            x: 28
            y: 22
            width: flick.width - 56
            spacing: 18

            // Filtros e busca
            Item {
                width: parent.width
                height: 34
                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 3
                    Rectangle {
                        width: pilulas.implicitWidth + 6
                        height: 34
                        radius: 9
                        color: Theme.panelBackground
                        Row {
                            id: pilulas
                            anchors.centerIn: parent
                            spacing: 2
                            Pilula { texto: qsTr("Recentes"); ativo: root.filtro === "recentes"; onEscolhido: root.filtro = "recentes" }
                            Pilula { texto: qsTr("Do Studio"); ativo: root.filtro === "studio"; onEscolhido: root.filtro = "studio" }
                        }
                    }
                }
                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 12
                    ThemedTextField {
                        width: 260
                        placeholderText: qsTr("Buscar projeto")
                        onTextChanged: root.busca = text
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.itens.length === 1 ? qsTr("1 projeto") : qsTr("%1 projetos").arg(root.itens.length)
                        color: Theme.mutedForeground
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSizeXs
                    }
                }
            }

            // Continuar de onde parou
            Rectangle {
                id: continuar
                readonly property var resumo: root.destaque ? (root.resumos[root.destaque.path] || {}) : {}
                visible: root.destaque !== null && root.filtro === "recentes" && root.busca.length === 0
                width: parent.width
                height: 208
                radius: 12
                color: Theme.panelBackground

                Capa {
                    id: capaDestaque
                    x: 14; y: 14
                    width: 320; height: 180
                    radius: 9
                    fonte: continuar.resumo.thumbnail || ""
                    Selo { x: 8; y: 8; visible: !!continuar.resumo.fromStudio; texto: qsTr("DO STUDIO"); laranja: true }
                    Selo {
                        anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: 8
                        visible: texto.length > 0
                        texto: root.duracaoTexto(continuar.resumo.duration)
                    }
                }

                Column {
                    anchors.left: capaDestaque.right
                    anchors.leftMargin: 18
                    anchors.right: parent.right
                    anchors.rightMargin: 16
                    y: 16
                    spacing: 4

                    Text {
                        text: qsTr("CONTINUAR DE ONDE PAROU")
                        color: Theme.primary
                        font.family: Theme.fontFamily
                        font.pixelSize: 11
                        font.weight: Font.Bold
                        font.letterSpacing: 1
                    }
                    Text {
                        width: parent.width
                        text: root.destaque ? root.nomeSemExtensao(root.destaque.name) : ""
                        color: Theme.foreground
                        font.family: Theme.fontFamily
                        font.pixelSize: 20
                        font.weight: Font.Bold
                        elide: Text.ElideRight
                    }
                    Text {
                        width: parent.width
                        color: Theme.mutedForeground
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSizeXs
                        elide: Text.ElideRight
                        text: {
                            const r = continuar.resumo
                            const partes = []
                            const q = root.destaque ? root.quando(r.modified) : ""
                            if (q.length) partes.push(qsTr("Editado: %1").arg(q))
                            if (r.width > 0) partes.push(r.width + "×" + r.height)
                            if (r.fps > 0) partes.push(Math.round(r.fps) + " fps")
                            if (r.videoClips > 0) partes.push(r.videoClips === 1 ? qsTr("1 clipe de vídeo") : qsTr("%1 clipes de vídeo").arg(r.videoClips))
                            if (r.subtitles > 0) partes.push(qsTr("com legendas"))
                            return partes.join("  ·  ")
                        }
                    }
                    Item { width: 1; height: 8 }
                    Rectangle {
                        width: parent.width
                        height: miniDestaque.implicitHeight + 16
                        radius: 7
                        color: "#0d0d0d"
                        visible: (continuar.resumo.tracks || []).length > 0
                        MiniTimeline {
                            id: miniDestaque
                            x: 10; y: 8
                            width: parent.width - 20
                            alturaFaixa: 9
                            trilhas: continuar.resumo.tracks || []
                        }
                    }
                    Item { width: 1; height: 8 }
                    Row {
                        spacing: 8
                        ThemedButton {
                            variant: "primary"
                            text: qsTr("Abrir")
                            onClicked: root.openRecentRequested(root.destaque.path)
                        }
                        ThemedButton {
                            variant: "secondary"
                            glyph: Theme.icons.upload
                            text: qsTr("Exportar direto")
                            onClicked: root.exportRecentRequested(root.destaque.path)
                        }
                        ThemedButton {
                            variant: "secondary"
                            glyph: Theme.icons.copy
                            text: qsTr("Duplicar")
                            onClicked: {
                                if (EditorState.duplicateProject(root.destaque.path).length > 0)
                                    Toasts.success(qsTr("Projeto duplicado"))
                                else
                                    Toasts.error(qsTr("Não foi possível duplicar o projeto"))
                            }
                        }
                    }
                }
            }

            // Grade: novo projeto + projetos
            Flow {
                id: grade
                width: parent.width
                spacing: 14
                readonly property int colunas: Math.max(2, Math.floor((width + spacing) / (230 + spacing)))
                readonly property real larguraCard: (width - spacing * (colunas - 1)) / colunas

                // Novo projeto ja com o formato
                Rectangle {
                    width: grade.larguraCard
                    height: 214
                    radius: 11
                    color: Theme.panelBackground
                    Column {
                        x: 14; y: 14
                        width: parent.width - 28
                        spacing: 12
                        Text {
                            text: "+  " + qsTr("Novo projeto")
                            color: Theme.primary
                            font.family: Theme.fontFamily
                            font.pixelSize: 14
                            font.weight: Font.Bold
                        }
                        Row {
                            spacing: 6
                            FormatoBotao { templateId: "yt_video"; rotulo: qsTr("YouTube"); ladoW: 30; ladoH: 17 }
                            FormatoBotao { templateId: "yt_short"; rotulo: qsTr("Short"); ladoW: 12; ladoH: 21 }
                            FormatoBotao { templateId: "square"; rotulo: qsTr("Quadrado"); ladoW: 18; ladoH: 18 }
                        }
                        Text {
                            text: qsTr("Outros formatos...")
                            color: outrosHover.hovered ? Theme.foreground : Theme.mutedForeground
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSizeXs
                            HoverHandler { id: outrosHover; cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: root.newProjectRequested() }
                        }
                    }
                    Text {
                        x: 14
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 14
                        text: qsTr("Abrir projeto do computador...")
                        color: abrirHover.hovered ? Theme.foreground : Theme.mutedForeground
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSizeSm
                        HoverHandler { id: abrirHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: root.openProjectRequested() }
                    }
                }

                Repeater {
                    model: root.itens
                    delegate: Rectangle {
                        id: card
                        required property var modelData
                        readonly property var resumo: root.resumos[modelData.path] || {}
                        readonly property bool existe: modelData.exists !== false
                        width: grade.larguraCard
                        height: 214
                        radius: 11
                        clip: true
                        color: cardHover.hovered && existe ? Theme.accent : Theme.panelBackground
                        opacity: existe ? 1 : 0.55

                        HoverHandler { id: cardHover; cursorShape: card.existe ? Qt.PointingHandCursor : Qt.ArrowCursor }
                        TapHandler { onTapped: if (card.existe) root.openRecentRequested(card.modelData.path) }

                        Capa {
                            id: capaCard
                            width: parent.width
                            height: 118
                            fonte: card.resumo.thumbnail || ""
                            Selo { x: 8; y: 8; visible: !!card.resumo.fromStudio; texto: qsTr("DO STUDIO"); laranja: true }
                            Selo {
                                anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 8
                                visible: !!card.resumo.aspect
                                texto: card.resumo.aspect || ""
                            }
                            Selo {
                                anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: 8
                                visible: texto.length > 0
                                texto: root.duracaoTexto(card.resumo.duration)
                            }
                        }

                        Rectangle {
                            id: faixaMini
                            anchors.top: capaCard.bottom
                            width: parent.width
                            height: (card.resumo.tracks || []).length > 0 ? miniCard.implicitHeight + 12 : 0
                            color: "#101010"
                            MiniTimeline {
                                id: miniCard
                                x: 8; y: 6
                                width: parent.width - 16
                                trilhas: card.resumo.tracks || []
                            }
                        }

                        Column {
                            anchors.top: faixaMini.bottom
                            anchors.topMargin: 9
                            x: 12
                            width: parent.width - 24
                            spacing: 1
                            Text {
                                width: parent.width
                                text: root.nomeSemExtensao(card.modelData.name)
                                color: Theme.foreground
                                font.family: Theme.fontFamily
                                font.pixelSize: 13
                                font.weight: Font.Bold
                                elide: Text.ElideRight
                            }
                            Text {
                                width: parent.width
                                text: card.existe ? root.quando(card.resumo.modified) : qsTr("Arquivo movido ou apagado")
                                color: Theme.mutedForeground
                                font.family: Theme.fontFamily
                                font.pixelSize: 12
                                elide: Text.ElideRight
                            }
                        }

                        // Tirar dos recentes (nao apaga o arquivo)
                        Rectangle {
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            anchors.margins: 8
                            width: 24; height: 24; radius: 6
                            visible: cardHover.hovered
                            color: tirarHover.hovered ? Theme.panelBackground : "transparent"
                            IconGlyph {
                                anchors.centerIn: parent
                                glyph: Theme.icons.x
                                iconSize: Theme.iconSizeSm
                                iconColor: tirarHover.hovered ? Theme.foreground : Theme.mutedForeground
                            }
                            HoverHandler { id: tirarHover; cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: EditorState.removeRecentProject(card.modelData.path) }
                            ThemedToolTip { text: qsTr("Tirar dos recentes"); visible: tirarHover.hovered }
                        }
                    }
                }
            }

            Text {
                visible: root.itens.length === 0
                text: root.filtro === "studio"
                      ? qsTr("Nenhum projeto do Studio ainda: os projetos que o chat do Studio salvar aparecem aqui.")
                      : qsTr("Os projetos que você salvar aparecem aqui.")
                color: Theme.mutedForeground
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSizeSm
            }

            // Arrastar midia
            Rectangle {
                width: parent.width
                height: 44
                radius: 10
                color: soltar.containsDrag ? "#2a1a12" : "#121212"
                Text {
                    anchors.centerIn: parent
                    text: qsTr("Arraste vídeos, áudios ou imagens para cá e comece um projeto com eles")
                    color: soltar.containsDrag ? Theme.primary : Theme.mutedForeground
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSizeSm
                }
            }
        }
    }

    // A tela inteira aceita o arrasto, nao so a faixa: soltar em qualquer lugar funciona.
    DropArea {
        id: soltar
        anchors.fill: parent
        keys: ["text/uri-list"]
        onDropped: (drop) => {
            if (drop.hasUrls && drop.urls.length > 0) {
                root.newProjectWithMediaRequested(drop.urls)
                drop.accept()
            }
        }
    }
}
