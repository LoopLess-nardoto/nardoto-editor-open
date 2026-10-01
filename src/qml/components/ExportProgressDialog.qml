import QtQuick
import QtQuick.Controls.Basic
import Drift

// Shows live progress for a background export. Closable while the export keeps
// running; EditorHeader reopens it via the circular-progress badge next to the
// Export button when it's been dismissed mid-export. Cancel stops the encoder.
ThemedDialog {
    id: root

    title: EditorState.exportInProgress ? qsTr("Exporting video") : qsTr("Export")
    preferredWidth: Theme.dialogWidthSm
    // Cancel export is the primary destructive action while busy; Close dismisses
    // the dialog without stopping the job (badge in the header reopens it).
    showAccept: EditorState.exportInProgress
    acceptText: qsTr("Cancel export")
    acceptVariant: "destructive"
    acceptOnReturn: false
    rejectText: qsTr("Close")
    rejectVariant: "secondary"

    // Tempo do export: sem ele nao da pra dizer se ficou lento nem comparar um render com outro.
    property double startedAt: 0
    property double elapsedMs: 0
    // Erro do ultimo export (a mensagem que o AppController manda quando ele termina mal).
    property string exportError: ""

    function openDialog() {
        open()
    }

    function formatElapsed(ms) {
        const total = Math.max(0, Math.round(ms / 1000))
        const min = Math.floor(total / 60)
        const sec = total % 60
        return min > 0 ? qsTr("%1 min %2 s").arg(min).arg(sec < 10 ? "0" + sec : sec)
                       : qsTr("%1 s").arg(sec)
    }

    function copyText(text) {
        clipboardHelper.text = text
        clipboardHelper.selectAll()
        clipboardHelper.copy()
    }

    // Relatorio que a IA do Studio le: o que aconteceu, quanto levou e o diagnostico do editor
    // (sistema, codecs, GPU e as ultimas linhas do motor de motion).
    function report() {
        const outcome = root.exportError.length > 0
                ? qsTr("The export failed: %1").arg(root.exportError)
                : qsTr("The export finished in %1.").arg(root.formatElapsed(root.elapsedMs))
        return outcome + "\n\n" + EditorState.debugInfoText()
    }

    Connections {
        target: EditorState
        function onExportInProgressChanged() {
            if (EditorState.exportInProgress) {
                root.startedAt = Date.now()
                root.elapsedMs = 0
                root.exportError = ""
            } else if (root.startedAt > 0) {
                root.elapsedMs = Date.now() - root.startedAt
                root.exportError = EditorState.lastMessageSeverity === "error" ? EditorState.lastMessage : ""
            }
        }
    }

    Timer {
        interval: 500
        repeat: true
        running: EditorState.exportInProgress && root.startedAt > 0
        onTriggered: root.elapsedMs = Date.now() - root.startedAt
    }

    onAccepted: {
        if (EditorState.exportInProgress)
            EditorState.cancelExport()
    }

    TextEdit {
        id: clipboardHelper
        visible: false
    }

    contentItem: Column {
        spacing: Theme.spacing2xl
        width: parent ? parent.width : 308

        LabelledProgressRing {
            width: parent.width
            value: EditorState.exportProgress
            indeterminate: EditorState.exportInProgress && EditorState.exportProgress <= 0
        }

        ThemedLabel {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            size: "sm"
            wrapMode: Text.WordWrap
            text: EditorState.exportInProgress
                  ? qsTr("Rendering your video. Close to keep editing, or cancel to stop.")
                  : root.exportError.length > 0
                    ? qsTr("The export failed: %1").arg(root.exportError)
                    : qsTr("Export finished.")
        }

        ThemedLabel {
            width: parent.width
            visible: root.startedAt > 0
            horizontalAlignment: Text.AlignHCenter
            size: "xs"
            color: Theme.mutedForeground
            text: EditorState.exportInProgress
                  ? qsTr("Elapsed: %1").arg(root.formatElapsed(root.elapsedMs))
                  : qsTr("Took %1").arg(root.formatElapsed(root.elapsedMs))
        }

        // Abrir a pasta do video pronto. So aparece quando o export deu certo.
        ThemedButton {
            width: parent.width
            visible: !EditorState.exportInProgress && root.exportError.length === 0
                     && EditorState.lastExportFile.length > 0
            variant: "primary"
            glyph: Theme.icons.folder
            text: qsTr("Open folder")
            tooltip: EditorState.lastExportFile
            onClicked: EditorState.revealLastExport()
        }

        // Render que falhou ou ficou lento: a pessoa nao precisa entender o erro, so mandar.
        // Botoes compactos, secundarios ao "Abrir pasta".
        Row {
            id: acoes
            width: parent.width
            spacing: 6
            visible: !EditorState.exportInProgress && root.startedAt > 0
            readonly property real larguraBotao: (width - spacing) / 2

            ThemedButton {
                width: acoes.larguraBotao
                variant: "secondary"
                glyph: Theme.icons.copy
                glyphSize: Theme.iconSizeSm
                font.pixelSize: Theme.fontSizeXs
                topPadding: 5; bottomPadding: 5; leftPadding: 8; rightPadding: 8
                text: qsTr("Report a problem")
                tooltip: qsTr("Copies a diagnostic report to send to support")
                onClicked: {
                    root.copyText(root.report())
                    Toasts.success(qsTr("Report copied. Send it to support or paste it into the Studio chat"))
                }
            }

            ThemedButton {
                width: acoes.larguraBotao
                variant: root.exportError.length > 0 ? "primary" : "secondary"
                glyph: Theme.icons.copy
                glyphSize: Theme.iconSizeSm
                font.pixelSize: Theme.fontSizeXs
                topPadding: 5; bottomPadding: 5; leftPadding: 8; rightPadding: 8
                text: qsTr("Send to Studio")
                tooltip: qsTr("A ready request for the Studio chat to fix the problem and render for you")
                onClicked: {
                    root.copyText(qsTr("My export in Nardoto Editor did not go well. Find the cause in the report below, fix what is needed (the project, a motion composition or a setting) and render the video for me through the editor.")
                                  + "\n\n" + root.report())
                    Toasts.success(qsTr("Copied. Paste it into the Studio chat"))
                }
            }
        }

        // The finished state used to be that sentence and nothing else — the file was on the
        // device and every way to it was outside the app. Both actions publish to the gallery
        // first, which is a second full copy of the video and the reason it is not done as part
        // of the export.
        //
        // Bound to canShareExport rather than to "the export ended": the publish runs on a
        // worker, so it is false again for as long as either button's copy is in flight, and
        // that is exactly when neither should be pressable.
        Row {
            width: parent.width
            spacing: Theme.androidTouchGap
            visible: !EditorState.exportInProgress && EditorState.canShareExport

            ThemedButton {
                width: (parent.width - parent.spacing) / 2
                height: Theme.androidMinTouchTarget
                variant: "secondary"
                glyph: Theme.icons.play
                text: qsTr("Play")
                onClicked: EditorState.playLastExport()
            }

            ThemedButton {
                width: (parent.width - parent.spacing) / 2
                height: Theme.androidMinTouchTarget
                variant: "primary"
                glyph: Theme.icons.upload
                text: qsTr("Share")
                onClicked: EditorState.shareLastExport()
            }
        }
    }
}
