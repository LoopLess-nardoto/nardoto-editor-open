import QtQuick
import QtQuick.Controls.Basic
import QtMultimedia
import Drift
import ".."

// Aba Motion: galeria dos motion graphics que o Nardoto Studio gera em disco (clipe com
// fundo transparente). "Usar" põe o clipe numa trilha nova no topo, no playhead;
// "Modificar" grava um pedido.json que o Studio atende gerando uma versão nova.
//
// Um único MediaPlayer para a aba inteira: toca a prévia do card sob o mouse e para quando a
// aba some. Os outros cards mostram só a miniatura.
Item {
    id: root

    // Pasta do card sob o mouse e o retângulo da miniatura dele, onde a prévia é desenhada.
    property Item hoverCard: null
    property string hoverPrevia: ""
    // Último pedido de modificação e o card que ficou sem resposta do Studio.
    property string pedidoPasta: ""
    property string pastaSemResposta: ""

    readonly property var secoes: [
        { id: "modelos", titulo: qsTr("Templates"),
          vazio: qsTr("No templates yet. The Nardoto Studio installs them here.") },
        { id: "meus", titulo: qsTr("Mine"),
          vazio: qsTr("Motion graphics you create in the Nardoto Studio chat show up here.") },
        { id: "projeto", titulo: qsTr("This project"),
          vazio: qsTr("No motion graphics in this project's folder yet.") }
    ]

    onVisibleChanged: {
        if (visible)
            MotionLibrary.recarregar()
        else
            root.hoverCard = null
    }

    function duracaoTexto(segundos) {
        const total = Math.max(0, Math.round(segundos))
        const s = total % 60
        return Math.floor(total / 60) + ":" + (s < 10 ? "0" + s : s)
    }

    Connections {
        target: MotionLibrary
        function onErro(mensagem) { Toasts.error(mensagem) }
    }

    MediaPlayer {
        id: player
        // Sem AudioOutput: a prévia é muda.
        source: root.visible && root.hoverCard !== null ? root.hoverPrevia : ""
        loops: MediaPlayer.Infinite
        videoOutput: previewOut
        onSourceChanged: {
            if (source.toString().length > 0)
                play()
            else
                stop()
        }
    }

    // Guarda a VideoOutput quando nenhum card está sob o mouse.
    Item { id: previewHolder; visible: false }

    VideoOutput {
        id: previewOut
        parent: root.hoverCard !== null ? root.hoverCard : previewHolder
        anchors.fill: parent
        z: 1
        fillMode: VideoOutput.PreserveAspectFit
        visible: root.hoverCard !== null && player.playbackState === MediaPlayer.PlayingState
    }

    Timer {
        id: pedidoTimer
        interval: 5000
        onTriggered: root.pastaSemResposta = root.pedidoPasta
    }

    Flickable {
        anchors.fill: parent
        contentHeight: secoesColumn.height + Theme.pagePadding * 2
        clip: true
        ScrollBar.vertical: AppScrollBar { }

        Column {
            id: secoesColumn
            x: Theme.pagePadding
            y: Theme.pagePadding
            width: parent.width - Theme.pagePadding * 2
            spacing: Theme.spacing2xl

            Repeater {
                model: root.secoes

                delegate: Column {
                    id: secaoCol
                    required property var modelData
                    readonly property int quantidade: MotionLibrary.contagens[modelData.id] || 0
                    width: secoesColumn.width
                    spacing: Theme.spacingMd
                    visible: modelData.id !== "projeto" || MotionLibrary.temProjeto

                    Text {
                        text: secaoCol.modelData.titulo
                        color: Theme.foreground
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSizeSm
                        font.weight: Font.Medium
                    }

                    Text {
                        width: parent.width
                        visible: secaoCol.quantidade === 0
                        text: secaoCol.modelData.vazio
                        color: Theme.mutedForeground
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSizeXs
                        wrapMode: Text.WordWrap
                    }

                    Flow {
                        width: parent.width
                        visible: secaoCol.quantidade > 0
                        spacing: Theme.assetCardGap

                        Repeater {
                            model: MotionLibrary

                            delegate: Column {
                                id: card
                                required property string nome
                                required property string secao
                                required property string pasta
                                required property string miniatura
                                required property string previa
                                required property bool temClipe
                                required property double duracao
                                required property string estado
                                required property string mensagem
                                required property bool pedidoPendente

                                readonly property bool renderizando: estado === "renderizando"
                                readonly property bool comErro: estado === "erro"
                                readonly property bool semResposta:
                                    pedidoPendente && root.pastaSemResposta === pasta

                                visible: secao === secaoCol.modelData.id
                                width: Theme.assetCardWidth * 1.5
                                spacing: Theme.spacingSm

                                Rectangle {
                                    id: thumb
                                    width: parent.width
                                    height: width * 9 / 16
                                    radius: Theme.radiusSm
                                    color: Theme.panelAccent
                                    clip: true
                                    border.width: cardHover.hovered ? Theme.borderWidth : 0
                                    border.color: Theme.primary

                                    HoverHandler {
                                        id: cardHover
                                        onHoveredChanged: {
                                            if (hovered && card.previa.length > 0) {
                                                root.hoverPrevia = card.previa
                                                root.hoverCard = thumb
                                            } else if (!hovered && root.hoverCard === thumb) {
                                                root.hoverCard = null
                                            }
                                        }
                                    }

                                    Image {
                                        id: thumbImage
                                        anchors.fill: parent
                                        source: card.miniatura
                                        fillMode: Image.PreserveAspectFit
                                        asynchronous: true
                                        visible: status === Image.Ready
                                    }

                                    IconGlyph {
                                        anchors.centerIn: parent
                                        visible: thumbImage.status !== Image.Ready
                                        glyph: Theme.icons.sparkles
                                        iconSize: Theme.spacing3xl
                                        iconColor: Theme.mutedForeground
                                    }

                                    // Estado: gerando (sem clipe), renderizando ou erro.
                                    Rectangle {
                                        z: 2
                                        visible: estadoLabel.text.length > 0
                                        anchors.left: parent.left
                                        anchors.top: parent.top
                                        anchors.margins: Theme.spacingSm
                                        color: card.comErro ? Theme.destructive : Theme.scrimStrong
                                        radius: Theme.radiusXs
                                        width: estadoLabel.implicitWidth + Theme.spacingLg
                                        height: estadoLabel.implicitHeight + Theme.spacingSm
                                        Text {
                                            id: estadoLabel
                                            anchors.centerIn: parent
                                            text: card.comErro ? qsTr("Error")
                                                  : card.renderizando ? qsTr("Rendering")
                                                  : !card.temClipe ? qsTr("Generating")
                                                  : ""
                                            color: Theme.onMedia
                                            font.pixelSize: Theme.fontSizeXs
                                            font.family: Theme.fontFamily
                                        }
                                    }

                                    Rectangle {
                                        z: 2
                                        visible: card.duracao > 0
                                        anchors.right: parent.right
                                        anchors.bottom: parent.bottom
                                        anchors.margins: Theme.spacingSm
                                        color: Theme.scrimStrong
                                        radius: Theme.radiusXs
                                        width: duracaoLabel.implicitWidth + Theme.spacingLg
                                        height: duracaoLabel.implicitHeight + Theme.spacingSm
                                        Text {
                                            id: duracaoLabel
                                            anchors.centerIn: parent
                                            text: root.duracaoTexto(card.duracao)
                                            color: Theme.onMedia
                                            font.pixelSize: Theme.fontSizeXs
                                            font.family: Theme.fontFamily
                                        }
                                    }
                                }

                                Text {
                                    width: parent.width
                                    text: card.nome
                                    color: Theme.foreground
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSizeXs
                                    elide: Text.ElideRight
                                }

                                Row {
                                    spacing: Theme.spacingSm

                                    ThemedButton {
                                        text: qsTr("Use")
                                        variant: "primary"
                                        enabled: card.temClipe
                                        font.pixelSize: Theme.fontSizeXs
                                        leftPadding: Theme.spacingLg
                                        rightPadding: Theme.spacingLg
                                        topPadding: Theme.spacingSm
                                        bottomPadding: Theme.spacingSm
                                        width: (card.width - Theme.spacingSm) / 2
                                        tooltip: qsTr("Add to a new top track at the playhead")
                                        onClicked: MotionLibrary.usar(card.pasta)
                                    }

                                    ThemedButton {
                                        text: qsTr("Modify")
                                        enabled: !card.renderizando
                                        font.pixelSize: Theme.fontSizeXs
                                        leftPadding: Theme.spacingLg
                                        rightPadding: Theme.spacingLg
                                        topPadding: Theme.spacingSm
                                        bottomPadding: Theme.spacingSm
                                        width: (card.width - Theme.spacingSm) / 2
                                        onClicked: modificarDialog.abrir(card.pasta, card.nome)
                                    }
                                }

                                Text {
                                    width: parent.width
                                    visible: text.length > 0
                                    text: card.comErro ? card.mensagem
                                          : card.renderizando ? qsTr("Generating the new version…")
                                          : card.semResposta
                                            ? qsTr("Open the Nardoto Studio to generate the new version.")
                                          : ""
                                    color: card.comErro ? Theme.destructive : Theme.mutedForeground
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSizeXs
                                    wrapMode: Text.WordWrap
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Formulário gerado a partir dos campos do meta.json: texto, número e cor.
    ThemedDialog {
        id: modificarDialog
        property string pasta: ""
        property var campos: []
        property var valores: ({})

        function abrir(pasta, nome) {
            modificarDialog.pasta = pasta
            modificarDialog.campos = MotionLibrary.campos(pasta)
            const iniciais = {}
            for (const campo of modificarDialog.campos)
                iniciais[campo.id] = campo.valor
            modificarDialog.valores = iniciais
            modificarDialog.title = qsTr("Modify “%1”").arg(nome)
            open()
        }

        acceptText: qsTr("Confirm")
        preferredWidth: Theme.dialogWidthSm

        contentItem: Column {
            width: parent ? parent.width : Theme.dialogWidthSm
            spacing: Theme.spacingMd

            ThemedLabel {
                width: parent.width
                visible: modificarDialog.campos.length === 0
                wrapMode: Text.WordWrap
                size: "sm"
                text: qsTr("This motion graphic has no editable fields.")
            }

            Repeater {
                model: modificarDialog.campos

                delegate: Column {
                    id: campoItem
                    required property var modelData
                    width: parent.width
                    spacing: Theme.spacingXs

                    ThemedLabel {
                        text: campoItem.modelData.rotulo || campoItem.modelData.id
                        size: "xs"
                    }

                    ThemedTextField {
                        visible: campoItem.modelData.tipo === "texto"
                        width: parent.width
                        text: visible ? String(campoItem.modelData.valor) : ""
                        onTextEdited: modificarDialog.valores[campoItem.modelData.id] = text
                    }

                    ThemedNumberField {
                        visible: campoItem.modelData.tipo === "numero"
                        width: parent.width
                        decimals: Number.isInteger(Number(campoItem.modelData.valor)) ? 0 : 2
                        value: Number(campoItem.modelData.valor) || 0
                        onEdited: (novo) => modificarDialog.valores[campoItem.modelData.id] = novo
                    }

                    ColorSwatchField {
                        visible: campoItem.modelData.tipo === "cor"
                        hex: visible ? String(campoItem.modelData.valor) : "#ffffffff"
                        // O Studio recebe #RRGGBB; o alfa só vai junto quando não é opaco.
                        onEdited: (novo) => modificarDialog.valores[campoItem.modelData.id] =
                                  (novo.length === 9 && novo.substring(1, 3).toLowerCase() === "ff")
                                  ? "#" + novo.substring(3) : novo
                    }
                }
            }
        }

        onAccepted: {
            if (MotionLibrary.pedirModificacao(modificarDialog.pasta, modificarDialog.valores)) {
                root.pedidoPasta = modificarDialog.pasta
                root.pastaSemResposta = ""
                pedidoTimer.restart()
            }
        }
    }
}
