import QtQuick
import QtQuick.Controls.Basic
import Drift

// Header Agent button. Session-only localhost MCP, written for the person
// connecting an assistant — not for someone reading a protocol spec.
ThemedDialog {
    id: root

    title: qsTr("Agent access")
    preferredWidth: Theme.dialogWidthMd
    showAccept: false
    rejectText: qsTr("Close")

    property bool detailsOpen: false

    function openDialog() {
        detailsOpen = false
        open()
    }

    contentItem: Flickable {
        id: contentFlick
        width: parent ? parent.width : Theme.dialogWidthMd
        implicitHeight: Math.min(body.height, root.availableContentHeight)
        contentWidth: width
        contentHeight: body.height
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: AppScrollBar {
            policy: contentFlick.contentHeight > contentFlick.height
                    ? ScrollBar.AlwaysOn : ScrollBar.AsNeeded
        }

        Column {
            id: body
            width: contentFlick.width
            spacing: Theme.spacingXl

            ThemedLabel {
                width: parent.width
                size: "sm"
                wrapMode: Text.WordWrap
                text: qsTr("Permita que o chat do Nardoto Studio, o Cursor ou o Claude editem este projeto: adicionem clipes, alterem a timeline e confiram o resultado. Apenas programas deste computador podem acessar. O recurso inicia desativado a cada abertura do Nardoto Editor; desligue-o ao terminar.")
            }

            ThemedSwitch {
                checked: EditorState.mcpEnabled
                text: qsTr("Allow for this session")
                tooltip: qsTr("Allows an assistant on this computer to edit this project until you turn it off or quit.")
                onToggled: EditorState.mcpEnabled = checked
            }

            ThemedLabel {
                width: parent.width
                visible: EditorState.mcpError.length > 0
                text: EditorState.mcpError
                color: Theme.destructive
            }

            ThemedLabel {
                width: parent.width
                visible: !EditorState.mcpRunning
                wrapMode: Text.WordWrap
                text: qsTr("Turn this on so the Nardoto Studio chat, Cursor or Claude can edit this project.")
            }

            Column {
                width: parent.width
                spacing: Theme.spacingLg
                visible: EditorState.mcpRunning

                Row {
                    spacing: Theme.spacingMd

                    IconGlyph {
                        glyph: Theme.icons.success
                        iconSize: Theme.iconSizeMd
                        iconColor: Theme.constructive
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                        text: qsTr("Access is on")
                        color: Theme.constructive
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSizeSm
                        font.weight: Font.Medium
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                // Nardoto Studio primeiro: o chat de lá já enxerga o editor, então
                // a pessoa só precisa de um pedido pronto, nada de configuração.
                ThemedLabel {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: qsTr("Using Nardoto Studio? Its chat already sees this editor, no setup needed. Copy a ready request, paste it into the Studio chat and fill in your files.")
                }

                ThemedButton {
                    width: parent.width
                    variant: "primary"
                    glyph: Theme.icons.copy
                    text: qsTr("Copy request for the Studio chat")
                    tooltip: qsTr("A ready request to paste into the Nardoto Studio chat")
                    onClicked: {
                        EditorState.copyStudioChatPrompt()
                        Toasts.success(qsTr("Copied. Paste it into the Studio chat"))
                    }
                }

                ThemedLabel {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: qsTr("Using Cursor or Claude? Copy the setup for the one you use.")
                }

                ThemedButton {
                    width: parent.width
                    variant: "secondary"
                    glyph: Theme.icons.copy
                    text: qsTr("Copy for Cursor")
                    tooltip: qsTr("Copy a setup snippet to paste into Cursor")
                    onClicked: {
                        EditorState.copyMcpCursorSnippet()
                        Toasts.success(qsTr("Copied for Cursor"))
                    }
                }

                ThemedButton {
                    width: parent.width
                    variant: "secondary"
                    glyph: Theme.icons.copy
                    text: qsTr("Copy for Claude")
                    tooltip: qsTr("Copy a command to paste into Claude Code")
                    onClicked: {
                        EditorState.copyMcpClaudeCommand()
                        Toasts.success(qsTr("Copied for Claude"))
                    }
                }

                ThemedLabel {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: qsTr("Paste that into the assistant. To help it use this editor, copy the how-to next and paste it into the chat.")
                }

                ThemedButton {
                    width: parent.width
                    variant: "ghost"
                    glyph: Theme.icons.copy
                    text: qsTr("Copy a how-to for the agent")
                    tooltip: qsTr("A short list of what the agent can do here — paste it into the chat")
                    onClicked: {
                        EditorState.copyMcpAgentGuide()
                        Toasts.success(qsTr("Copied how-to"))
                    }
                }

                ThemedButton {
                    variant: "ghost"
                    glyph: root.detailsOpen ? Theme.icons.chevronDown : Theme.icons.chevronRight
                    text: qsTr("More options")
                    onClicked: root.detailsOpen = !root.detailsOpen
                }

                Column {
                    width: parent.width
                    spacing: Theme.spacingMd
                    visible: root.detailsOpen

                    ThemedLabel {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: qsTr("For a different assistant, copy a one-time setup. The address and key are already in the Cursor and Claude copies above.")
                    }

                    ThemedButton {
                        width: parent.width
                        variant: "ghost"
                        glyph: Theme.icons.copy
                        text: qsTr("Copy one-time setup")
                        tooltip: qsTr("Add this once to the assistant’s config. Access still has to be turned on here.")
                        onClicked: {
                            EditorState.copyMcpStdioSnippet()
                            Toasts.success(qsTr("Copied one-time setup"))
                        }
                    }
                }
            }
        }
    }
}
