import QtQuick
import QtQuick.Controls.Basic
import Drift

// Aba "Falas e mídias": cada cena (clipe de vídeo ou imagem) com a fala da legenda que toca durante
// ela. Serve para bater o olho e achar a mídia que não combina com o que o narrador diz, e trocar
// só essa (TrocarMidiaDialog). Dados de EditorState.scenesWithSpeech(), refeitos a cada edição.
Item {
    id: root

    property var cenas: []
    property string busca: ""
    property string selecionada: ""

    function recarregar() {
        root.cenas = EditorState.scenesWithSpeech()
    }

    function tempo(s) {
        const t = Math.max(0, Math.floor(s))
        return Math.floor(t / 60) + ":" + (t % 60 < 10 ? "0" : "") + (t % 60)
    }

    function irPara(cena) {
        root.selecionada = cena.clipId
        EditorState.playheadSeconds = cena.start + 0.05
        EditorState.selectClip(cena.track, cena.index)
    }

    Component.onCompleted: recarregar()

    Connections {
        target: EditorState
        function onTracksChanged() { recargaTimer.restart() }
    }
    // Edições vêm em rajada (arrastar um clipe emite várias): agrupa antes de refazer a lista.
    Timer { id: recargaTimer; interval: 250; onTriggered: root.recarregar() }

    readonly property var filtradas: {
        const termo = busca.trim().toLowerCase()
        if (!termo.length)
            return cenas
        return cenas.filter(c => (c.fala || "").toLowerCase().indexOf(termo) >= 0
                                 || (c.name || "").toLowerCase().indexOf(termo) >= 0)
    }

    Column {
        anchors.fill: parent
        anchors.margins: Theme.spacingMd
        spacing: Theme.spacingMd

        Item {
            width: parent.width
            height: 20
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Falas e mídias")
                color: Theme.foreground
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSizeSm
                font.weight: Font.Bold
            }
            Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.cenas.length === 1 ? qsTr("1 cena") : qsTr("%1 cenas").arg(root.cenas.length)
                color: Theme.mutedForeground
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSizeXs
            }
        }

        ThemedTextField {
            width: parent.width
            placeholderText: qsTr("Buscar na fala ou no nome do arquivo...")
            onTextChanged: root.busca = text
        }

        Text {
            width: parent.width
            visible: root.cenas.length === 0
            wrapMode: Text.WordWrap
            text: qsTr("Nenhuma cena de vídeo ou imagem na timeline ainda.")
            color: Theme.mutedForeground
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSizeSm
        }

        ListView {
            id: lista
            width: parent.width
            height: parent.height - y
            clip: true
            spacing: 6
            model: root.filtradas
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            delegate: Rectangle {
                id: linha
                required property var modelData
                required property int index
                readonly property bool sel: root.selecionada === modelData.clipId
                width: lista.width - 8
                height: corpo.implicitHeight + 14
                radius: Theme.radiusMd
                color: sel ? "#2a1a12" : (hover.hovered ? Theme.accent : Theme.panelBackground)

                // Window.window lido no próprio item: dentro do TapHandler (que não é Item) ele vem vazio.
                function trocar() {
                    root.irPara(linha.modelData)
                    const janela = linha.Window.window
                    if (janela && typeof janela.abrirTrocaDoClipe === "function")
                        janela.abrirTrocaDoClipe(linha.modelData.track, linha.modelData.index)
                }

                HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
                // Clicar na cena já leva até ela e abre a troca: é para isso que a lista existe.
                TapHandler { onTapped: linha.trocar() }

                Row {
                    id: corpo
                    x: 7; y: 7
                    width: parent.width - 14
                    spacing: 9

                    Rectangle {
                        width: 96; height: 54; radius: 5
                        color: "#000"
                        clip: true
                        Image {
                            anchors.fill: parent
                            source: linha.modelData.thumbnail || ""
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            visible: status === Image.Ready
                        }
                        IconGlyph {
                            anchors.centerIn: parent
                            visible: !linha.modelData.thumbnail
                            glyph: linha.modelData.kind === "image" ? Theme.icons.image : Theme.icons.film
                            iconSize: 18
                            iconColor: Theme.mutedForeground
                        }
                        Rectangle {
                            anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: 3
                            width: tTempo.implicitWidth + 8; height: 15; radius: 3
                            color: Qt.rgba(0, 0, 0, 0.75)
                            Text {
                                id: tTempo
                                anchors.centerIn: parent
                                text: root.tempo(linha.modelData.start)
                                color: "white"
                                font.family: Theme.fontFamily
                                font.pixelSize: 10
                            }
                        }
                    }

                    Column {
                        width: parent.width - 96 - parent.spacing
                        spacing: 3

                        Item {
                            width: parent.width
                            height: 14
                            Text {
                                text: qsTr("Cena %1  ·  %2 s").arg(linha.index + 1)
                                      .arg((linha.modelData.end - linha.modelData.start).toFixed(1).replace(".", ","))
                                color: Theme.mutedForeground
                                font.family: Theme.fontFamily
                                font.pixelSize: 11
                            }
                            Text {
                                anchors.right: parent.right
                                width: parent.width * 0.5
                                horizontalAlignment: Text.AlignRight
                                text: linha.modelData.name
                                elide: Text.ElideMiddle
                                color: Theme.mutedForeground
                                font.family: Theme.fontFamily
                                font.pixelSize: 11
                            }
                        }
                        Text {
                            width: parent.width
                            text: linha.modelData.fala ? "\"" + linha.modelData.fala + "\"" : qsTr("(sem fala neste trecho)")
                            color: linha.modelData.fala ? Theme.foreground : Theme.mutedForeground
                            font.family: Theme.fontFamily
                            font.pixelSize: 12
                            wrapMode: Text.WordWrap
                            maximumLineCount: linha.sel ? 6 : 2
                            elide: Text.ElideRight
                        }
                        Rectangle {
                            width: tTrocar.implicitWidth + 16
                            height: 22
                            radius: 4
                            color: botaoTrocar.hovered ? Theme.primary : "#3a2418"
                            HoverHandler { id: botaoTrocar; cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: linha.trocar() }
                            Text {
                                id: tTrocar
                                anchors.centerIn: parent
                                text: qsTr("Trocar mídia")
                                color: botaoTrocar.hovered ? "white" : Theme.primary
                                font.family: Theme.fontFamily
                                font.pixelSize: 11
                            }
                        }
                    }
                }
            }
        }
    }

    // Clicou numa mídia na timeline: a lista marca e mostra a cena dela no topo.
    Connections {
        target: EditorState
        function onSelectionChanged() {
            const lista_ = root.filtradas
            for (let i = 0; i < lista_.length; ++i) {
                if (lista_[i].track === EditorState.selectedTrack && lista_[i].index === EditorState.selectedClip) {
                    root.selecionada = lista_[i].clipId
                    lista.positionViewAtIndex(i, ListView.Beginning)
                    return
                }
            }
        }
    }
}
