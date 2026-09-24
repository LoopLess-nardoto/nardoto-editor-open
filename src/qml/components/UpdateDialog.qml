import QtQuick
import QtQuick.Controls.Basic
import Drift

// Opened from the badge in EditorHeader, never by itself — a dialog over the project someone just
// launched to work on is an interruption, and the badge is already the notification.
//
// On Windows the primary action downloads the installer here; when it is on disk, Main.qml closes
// the window (through the unsaved-changes prompt) and the installer takes over. Elsewhere the
// primary action opens the release page. "Skip" belongs away from the two safe actions, so the
// buttons live in the content and ThemedDialog's two-button footer is off.
ThemedDialog {
    id: root

    title: qsTr("Update available")
    preferredWidth: Theme.dialogWidthMd
    showFooter: false
    acceptOnReturn: false
    closePolicy: Updates.downloading ? Popup.NoAutoClose : Popup.CloseOnEscape | Popup.CloseOnPressOutside

    Shortcut {
        sequences: ["Return", "Enter"]
        enabled: root.visible && !Updates.downloading
        onActivated: root.update()
    }

    function update() {
        if (Updates.canInstall) {
            Updates.downloadAndInstall()
        } else {
            Updates.openDownloadPage()
            close()
        }
    }

    contentItem: Column {
        spacing: Theme.spacingLg
        width: parent ? parent.width : Theme.dialogWidthMd

        ThemedLabel {
            width: parent.width
            size: "base"
            tone: "default"
            text: qsTr("Nardoto Editor %1 está disponível").arg(Updates.latestVersion)
        }

        ThemedLabel {
            width: parent.width
            text: qsTr("You have %1.").arg(Updates.currentVersion)
        }

        Rectangle {
            width: parent.width
            height: Theme.borderWidth
            color: Theme.panelBorder
            visible: notesFlick.visible
        }

        // The release body verbatim. Scrolled rather than trimmed: matching on a heading to cut
        // it off would break silently the day the template changes.
        Flickable {
            id: notesFlick
            width: parent.width
            height: Math.min(notes.implicitHeight, 240)
            contentHeight: notes.implicitHeight
            clip: true
            visible: notes.text.length > 0
            ScrollBar.vertical: AppScrollBar { }

            ThemedLabel {
                id: notes
                width: notesFlick.width - Theme.spacingLg
                size: "sm"
                tone: "default"
                textFormat: Text.MarkdownText
                text: Updates.releaseNotes
                onLinkActivated: (link) => Qt.openUrlExternally(link)
            }
        }

        // Download in progress or done: the bar and the one-line status from the checker.
        Column {
            width: parent.width
            spacing: Theme.spacingSm
            visible: Updates.downloading || Updates.installerReady || Updates.status.length > 0

            ThemedProgressBar {
                width: parent.width
                value: Updates.downloadProgress
                visible: Updates.downloading || Updates.installerReady
            }

            ThemedLabel {
                width: parent.width
                size: "sm"
                wrapMode: Text.WordWrap
                text: Updates.status
            }
        }

        Item {
            width: parent.width
            height: updateButton.height

            ThemedButton {
                anchors.left: parent.left
                variant: "ghost"
                text: qsTr("Skip")
                enabled: !Updates.downloading && !Updates.installerReady
                tooltip: qsTr("Don't mention %1 again. Later releases are still announced.")
                            .arg(Updates.latestVersion)
                onClicked: {
                    Updates.skipVersion()
                    root.close()
                }
            }

            Row {
                anchors.right: parent.right
                spacing: Theme.spacingLg

                ThemedButton {
                    variant: "secondary"
                    text: qsTr("Later")
                    enabled: !Updates.downloading
                    onClicked: root.close()
                }

                ThemedButton {
                    id: updateButton
                    variant: "primary"
                    glyph: Theme.icons.download
                    enabled: !Updates.downloading
                    text: Updates.installerReady
                          ? qsTr("Fechar e atualizar")
                          : Updates.canInstall ? qsTr("Atualizar agora") : qsTr("Download")
                    tooltip: Updates.canInstall
                             ? qsTr("Baixa o instalador; o editor fecha e reabre já atualizado")
                             : qsTr("Opens the release page in your browser")
                    onClicked: root.update()
                }
            }
        }
    }

    onOpened: updateButton.forceActiveFocus()
}
