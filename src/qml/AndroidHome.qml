import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Window
import Drift
import "components"

// Combined start page: recent projects + layout picker + new-project CTAs.
Item {
    id: root

    signal enterEditor()
    signal openProjectRequested()
    signal openRecentRequested(string path)

    readonly property bool needsAttention: {
        const win = root.Window.window
        return (win ? win.addonAttentionNeeded : false) || Updates.updateAvailable
    }

    function startWithLayout() {
        EditorState.newProject()
        layoutPicker.apply()
        root.enterEditor()
    }

    // Leaves the canvas undecided so the first video/image dropped on the timeline opens
    // ProjectSetupDialog, the same route the desktop's "Decide later" takes. newProject()
    // resets projectLayoutChosen, so it is enough to just not apply the picker here.
    function startUndecided() {
        EditorState.newProject()
        root.enterEditor()
    }

    Component.onCompleted: layoutPicker.resetForMobile()

    Flickable {
        id: flick
        anchors.fill: parent
        // The home page owns the whole window, so it is the one that has to clear the
        // status bar, the gesture pill and any landscape cutout itself.
        anchors.topMargin: root.SafeArea.margins.top
        anchors.bottomMargin: Theme.spacingXl + root.SafeArea.margins.bottom
        anchors.leftMargin: root.SafeArea.margins.left
        anchors.rightMargin: root.SafeArea.margins.right
        contentWidth: width
        contentHeight: pageColumn.implicitHeight + Theme.spacing3xl
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick

        Column {
            id: pageColumn
            width: parent.width
            spacing: Theme.spacing2xl
            topPadding: Theme.spacing2xl
            leftPadding: Theme.pagePadding
            rightPadding: Theme.pagePadding

            // --- Header -------------------------------------------------------
            Item {
                width: parent.width - parent.leftPadding - parent.rightPadding
                height: Math.max(brandCol.height, headerActions.height)

                Column {
                    id: brandCol
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    Text {
                        text: "Nardoto Editor"
                        color: Theme.foreground
                        font.family: Theme.fontFamily
                        font.pixelSize: 22
                        font.weight: Font.Bold
                    }

                    Text {
                        text: qsTr("Crie vídeos bem-acabados em poucos passos")
                        color: Theme.mutedForeground
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSizeSm
                    }
                }

                Row {
                    id: headerActions
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.spacingSm

                    ThemedButton {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Open")
                        glyph: Theme.icons.folder
                        variant: "secondary"
                        onClicked: root.openProjectRequested()
                    }

                    // The theme toggle, the addon manager and the update prompt used to live
                    // only in the editor's overflow, so a first run — which has no project yet
                    // — could not reach the packs the editor needs to be usable at all.
                    Item {
                        width: Theme.androidIconButtonSize
                        height: Theme.androidIconButtonSize
                        anchors.verticalCenter: parent.verticalCenter

                        IconButton {
                            anchors.fill: parent
                            buttonSize: Theme.androidIconButtonSize
                            iconSize: Theme.iconSizeLg
                            glyph: Theme.icons.ellipsis
                            variant: "text"
                            tooltip: qsTr("More")
                            onClicked: homeMenu.popup()
                        }

                        // The editor's Extras button pulses; a badge is the phone-sized
                        // version of the same "something needs you" signal.
                        Rectangle {
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: 4
                            width: 8
                            height: 8
                            radius: 4
                            visible: root.needsAttention
                            color: Theme.destructive
                        }

                        ThemedContextMenu {
                            id: homeMenu

                            ThemedMenuItem {
                                text: Theme.darkMode ? qsTr("Light mode") : qsTr("Dark mode")
                                icon.name: Theme.darkMode ? Theme.icons.sun : Theme.icons.moon
                                onTriggered: Theme.toggleDarkMode()
                            }
                            ThemedMenuItem {
                                text: qsTr("Extras")
                                icon.name: Theme.icons.package
                                onTriggered: root.Window.window.openExtras()
                            }
                            ThemedMenuItem {
                                text: qsTr("Update available")
                                icon.name: Theme.icons.download
                                visible: Updates.updateAvailable
                                onTriggered: root.Window.window.openUpdateDialog()
                            }
                        }
                    }
                }
            }

            // --- Recent projects ----------------------------------------------
            Column {
                width: parent.width - parent.leftPadding - parent.rightPadding
                spacing: Theme.spacingMd
                visible: EditorState.recentProjects.length > 0

                ThemedLabel {
                    text: qsTr("Recent projects")
                    tone: "default"
                    size: "sm"
                }

                Flickable {
                    width: parent.width
                    height: Theme.androidHomeRecentCardHeight
                    contentWidth: recentRow.width
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    flickableDirection: Flickable.HorizontalFlick

                    Row {
                        id: recentRow
                        spacing: Theme.spacingMd
                        height: parent.height

                        Repeater {
                            model: EditorState.recentProjects

                            delegate: Rectangle {
                                id: card
                                required property var modelData
                                width: Theme.androidHomeRecentCardWidth
                                height: Theme.androidHomeRecentCardHeight
                                radius: Theme.radiusMd
                                color: Theme.panelBackground
                                border.width: Theme.borderWidth
                                border.color: Theme.panelBorder
                                opacity: modelData.exists === false ? 0.55 : 1

                                Column {
                                    anchors.fill: parent
                                    anchors.margins: Theme.spacingLg
                                    spacing: Theme.spacingSm

                                    Rectangle {
                                        width: parent.width
                                        height: 32
                                        radius: Theme.radiusSm
                                        color: Theme.panelAccent

                                        IconGlyph {
                                            anchors.centerIn: parent
                                            glyph: Theme.icons.film
                                            iconSize: 18
                                            iconColor: Theme.mutedForeground
                                        }

                                        // Same on-disk signal the desktop recents list carries;
                                        // the card's dimming alone did not say what was wrong.
                                        Rectangle {
                                            anchors.right: parent.right
                                            anchors.top: parent.top
                                            anchors.margins: 4
                                            width: 8
                                            height: 8
                                            radius: 4
                                            color: card.modelData.exists === false
                                                   ? Theme.mutedForeground : Theme.constructive
                                        }
                                    }

                                    Text {
                                        width: parent.width
                                        text: {
                                            const n = card.modelData.name || ""
                                            return n.replace(/\.drift$/i, "") || qsTr("Untitled")
                                        }
                                        color: Theme.panelForeground
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontSizeXs
                                        font.weight: Font.Medium
                                        elide: Text.ElideMiddle
                                    }

                                    // Elided from the left: on a 140px card the tail — the folder
                                    // and file name — is the half that tells two projects apart.
                                    Text {
                                        width: parent.width
                                        text: card.modelData.path
                                        color: Theme.mutedForeground
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontSizeXs
                                        elide: Text.ElideLeft
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    pressAndHoldInterval: 450
                                    // Long-press stands in for the right click the phone
                                    // does not have.
                                    property bool heldMenu: false
                                    onPressed: heldMenu = false
                                    onPressAndHold: {
                                        heldMenu = true
                                        Haptics.pickUp()
                                        cardMenu.popup()
                                    }
                                    onClicked: {
                                        if (heldMenu)
                                            return
                                        if (card.modelData.exists === false) {
                                            Toasts.warning(qsTr("That project file is missing."))
                                            return
                                        }
                                        Haptics.select()
                                        root.openRecentRequested(card.modelData.path)
                                    }
                                }

                                ThemedContextMenu {
                                    id: cardMenu

                                    ThemedMenuItem {
                                        text: qsTr("Remove from recents")
                                        icon.name: Theme.icons.trash
                                        onTriggered: EditorState.removeRecentProject(card.modelData.path)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // --- Layout picker ------------------------------------------------
            Column {
                width: parent.width - parent.leftPadding - parent.rightPadding
                spacing: Theme.spacingMd

                ThemedLabel {
                    text: qsTr("New project")
                    tone: "default"
                    size: "sm"
                }

                AndroidLayoutPicker {
                    id: layoutPicker
                    width: parent.width
                    compact: true
                }
            }

            // --- CTAs ---------------------------------------------------------
            Column {
                width: parent.width - parent.leftPadding - parent.rightPadding
                spacing: Theme.spacingMd

                ThemedButton {
                    width: parent.width
                    text: qsTr("Start with this layout")
                    glyph: Theme.icons.plus
                    variant: "primary"
                    onClicked: root.startWithLayout()
                }

                ThemedButton {
                    width: parent.width
                    text: qsTr("Decide layout later")
                    glyph: Theme.icons.clock
                    variant: "secondary"
                    onClicked: root.startUndecided()
                }
            }
        }
    }
}
