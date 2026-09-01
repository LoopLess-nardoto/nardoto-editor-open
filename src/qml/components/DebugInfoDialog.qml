import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Window
import Drift

// Header bug button. Decoder/encoder capability plus host facts to paste into a GitHub issue.
ThemedDialog {
    id: root

    title: qsTr("Debug info")
    preferredWidth: Theme.dialogWidthLg
    acceptText: qsTr("Copy report")
    rejectText: qsTr("Close")

    property var info: ({ codecs: [], encoders: [], system: [], hints: [] })

    onOpened: info = EditorState.debugInfo()
    onAccepted: {
        EditorState.copyDebugInfo()
        Toasts.success(qsTr("Copied to clipboard"))
    }

    function cellFill(state, striped) {
        if (state === "unavailable")
            return striped ? Theme.panelAccent : "transparent"
        const c = state === "supported" ? Theme.constructive : Theme.destructive
        return Qt.rgba(c.r, c.g, c.b, striped ? 0.10 : 0.16)
    }

    function cellTextColor(state) {
        if (state === "unavailable")
            return Theme.mutedForeground
        return state === "supported" ? Theme.constructive : Theme.destructive
    }

    function cellLabel(state) {
        if (state === "unavailable")
            return qsTr("Unavailable")
        return state === "supported" ? qsTr("Supported") : qsTr("Not supported")
    }

    function cellState(row, hardwareColumn) {
        if (hardwareColumn && row && row.hardwareUnavailable)
            return "unavailable"
        const ok = hardwareColumn ? !!(row && row.hardware) : !!(row && row.software)
        return ok ? "supported" : "unsupported"
    }

    contentItem: Flickable {
        id: contentFlick
        width: parent ? parent.width : Theme.dialogWidthLg
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

            Repeater {
                model: [
                    {
                        title: qsTr("Video decoders"),
                        headers: [qsTr("Codec Name"), qsTr("Software Decoding"), qsTr("Hardware Decoding")],
                        rows: root.info.codecs || [],
                        softwareKey: "softwareDecoder",
                        hardwareKey: "hardwareDecoder"
                    },
                    {
                        title: qsTr("Video encoders"),
                        headers: [qsTr("Codec Name"), qsTr("Software Encoding"), qsTr("Hardware Encoding")],
                        rows: root.info.encoders || [],
                        softwareKey: "softwareEncoder",
                        hardwareKey: "hardwareEncoder"
                    }
                ]

                Column {
                    id: tableBlock
                    required property var modelData

                    width: parent.width
                    spacing: Theme.spacingLg

                    ThemedLabel {
                        width: parent.width
                        size: "sm"
                        tone: "default"
                        text: tableBlock.modelData.title
                        font.weight: Font.Medium
                    }

                    Rectangle {
                        width: parent.width
                        height: tableCol.height
                        radius: Theme.radiusSm
                        color: "transparent"
                        border.width: Theme.borderWidth
                        border.color: Theme.panelBorder
                        clip: true

                        Column {
                            id: tableCol
                            width: parent.width
                            spacing: 0

                            Row {
                                width: parent.width
                                height: Theme.controlHeightSm

                                Repeater {
                                    model: tableBlock.modelData.headers

                                    Rectangle {
                                        required property int index
                                        required property string modelData

                                        width: tableCol.width / 3
                                        height: Theme.controlHeightSm
                                        color: Theme.panelAccent

                                        Rectangle {
                                            anchors.right: parent.right
                                            width: Theme.borderWidth
                                            height: parent.height
                                            color: Theme.panelBorder
                                            visible: index < 2
                                        }

                                        ThemedLabel {
                                            anchors.fill: parent
                                            anchors.leftMargin: Theme.spacingLg
                                            anchors.rightMargin: Theme.spacingLg
                                            size: "xs"
                                            tone: "default"
                                            font.weight: Font.DemiBold
                                            wrapMode: Text.NoWrap
                                            elide: Text.ElideRight
                                            verticalAlignment: Text.AlignVCenter
                                            text: modelData
                                        }
                                    }
                                }
                            }

                            Repeater {
                                model: tableBlock.modelData.rows

                                Row {
                                    id: codecRow
                                    required property var modelData
                                    required property int index

                                    width: parent.width
                                    height: Theme.controlHeight

                                    readonly property bool striped: index % 2 === 1
                                    readonly property var row: modelData

                                    Rectangle {
                                        width: tableCol.width / 3
                                        height: parent.height
                                        color: codecRow.striped ? Theme.panelAccent : "transparent"

                                        Rectangle {
                                            anchors.right: parent.right
                                            width: Theme.borderWidth
                                            height: parent.height
                                            color: Theme.panelBorder
                                        }

                                        Rectangle {
                                            anchors.top: parent.top
                                            width: parent.width
                                            height: Theme.borderWidth
                                            color: Theme.panelBorder
                                        }

                                        ThemedLabel {
                                            anchors.fill: parent
                                            anchors.leftMargin: Theme.spacingLg
                                            anchors.rightMargin: Theme.spacingLg
                                            size: "xs"
                                            tone: "default"
                                            font.weight: Font.DemiBold
                                            wrapMode: Text.NoWrap
                                            elide: Text.ElideRight
                                            verticalAlignment: Text.AlignVCenter
                                            text: codecRow.row.name || ""

                                            HoverHandler { id: codecHover }
                                            ThemedToolTip {
                                                visible: codecHover.hovered && text.length > 0
                                                text: {
                                                    const parts = []
                                                    const sw = codecRow.row[tableBlock.modelData.softwareKey]
                                                    const hw = codecRow.row[tableBlock.modelData.hardwareKey]
                                                    if (sw)
                                                        parts.push(qsTr("Software: %1").arg(sw))
                                                    if (hw)
                                                        parts.push(qsTr("Hardware: %1").arg(hw))
                                                    return parts.join("\n")
                                                }
                                            }
                                        }
                                    }

                                    Repeater {
                                        model: [
                                            root.cellState(codecRow.row, false),
                                            root.cellState(codecRow.row, true)
                                        ]

                                        Rectangle {
                                            required property int index
                                            required property string modelData

                                            width: tableCol.width / 3
                                            height: codecRow.height
                                            color: root.cellFill(modelData, codecRow.striped)

                                            Rectangle {
                                                anchors.right: parent.right
                                                width: Theme.borderWidth
                                                height: parent.height
                                                color: Theme.panelBorder
                                                visible: index === 0
                                            }

                                            Rectangle {
                                                anchors.top: parent.top
                                                width: parent.width
                                                height: Theme.borderWidth
                                                color: Theme.panelBorder
                                            }

                                            Text {
                                                anchors.fill: parent
                                                anchors.leftMargin: Theme.spacingLg
                                                anchors.rightMargin: Theme.spacingLg
                                                font.family: Theme.fontFamily
                                                font.pixelSize: Theme.fontSizeXs
                                                font.weight: Font.Medium
                                                color: root.cellTextColor(modelData)
                                                wrapMode: Text.NoWrap
                                                elide: Text.ElideRight
                                                verticalAlignment: Text.AlignVCenter
                                                text: root.cellLabel(modelData)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Column {
                width: parent.width
                spacing: Theme.spacingLg
                visible: (root.info.hints || []).length > 0
                height: visible ? implicitHeight : 0

                ThemedLabel {
                    width: parent.width
                    size: "sm"
                    tone: "default"
                    text: qsTr("Checks")
                    font.weight: Font.Medium
                }

                Repeater {
                    model: root.info.hints || []

                    Rectangle {
                        required property var modelData

                        width: parent.width
                        implicitHeight: hintCol.height + Theme.spacingLg * 2
                        radius: Theme.radiusSm
                        color: "transparent"
                        border.width: Theme.borderWidth
                        border.color: Theme.panelBorder

                        Column {
                            id: hintCol
                            x: Theme.spacingLg
                            y: Theme.spacingLg
                            width: parent.width - Theme.spacingLg * 2
                            spacing: Theme.spacingSm

                            ThemedLabel {
                                width: parent.width
                                size: "sm"
                                tone: "default"
                                font.weight: Font.Medium
                                text: modelData.title || ""
                            }

                            ThemedLabel {
                                width: parent.width
                                size: "sm"
                                text: modelData.detail || ""
                            }

                            ThemedLabel {
                                width: parent.width
                                size: "xs"
                                tone: "default"
                                visible: !!(modelData.command)
                                height: visible ? implicitHeight : 0
                                font.family: Theme.monoFontFamily
                                wrapMode: Text.WrapAnywhere
                                text: modelData.command || ""
                            }

                            ThemedButton {
                                visible: modelData.action === "addons"
                                height: visible ? implicitHeight : 0
                                text: qsTr("Open Add-ons")
                                variant: "secondary"
                                onClicked: {
                                    root.close()
                                    if (typeof Window !== "undefined" && Window.window
                                            && Window.window.openAddonManager)
                                        Window.window.openAddonManager("onnxruntime")
                                }
                            }
                        }
                    }
                }
            }

            ThemedLabel {
                width: parent.width
                size: "sm"
                tone: "default"
                text: qsTr("System")
                font.weight: Font.Medium
            }

            Column {
                width: parent.width
                spacing: 0

                Repeater {
                    model: root.info.system || []

                    Item {
                        required property var modelData
                        required property int index

                        width: parent.width
                        height: Math.max(Theme.controlHeightSm,
                                         valueLabel.implicitHeight + Theme.spacingSm)

                        Rectangle {
                            anchors.fill: parent
                            color: index % 2 === 1 ? Theme.panelAccent : "transparent"
                            radius: Theme.radiusXs
                        }

                        ThemedLabel {
                            width: Math.round(parent.width * 0.34)
                            anchors.verticalCenter: parent.verticalCenter
                            leftPadding: Theme.spacingLg
                            size: "xs"
                            text: modelData.label || ""
                        }

                        ThemedLabel {
                            id: valueLabel
                            x: Math.round(parent.width * 0.34)
                            width: parent.width - x
                            anchors.verticalCenter: parent.verticalCenter
                            rightPadding: Theme.spacingLg
                            size: "xs"
                            tone: "default"
                            wrapMode: Text.WordWrap
                            text: modelData.value || ""
                        }
                    }
                }
            }

            Rectangle {
                width: parent.width
                height: Theme.borderWidth
                color: Theme.panelBorder
            }

            Column {
                width: parent.width
                spacing: Theme.spacingSm

                ThemedLabel {
                    width: parent.width
                    size: "sm"
                    text: qsTr("Need help? Copy the report above when you file an issue.")
                }

                ThemedLabel {
                    width: parent.width
                    size: "sm"
                    tone: "default"
                    textFormat: Text.RichText
                    linkColor: Theme.primary
                    text: "<a href=\"https://github.com/LoopLess-nardoto/nardoto-editor-open/issues\">%1</a>"
                          .arg(qsTr("Report a bug"))
                    onLinkActivated: (link) => Qt.openUrlExternally(link)
                    HoverHandler {
                        cursorShape: parent.hoveredLink ? Qt.PointingHandCursor : Qt.ArrowCursor
                    }
                }

                ThemedLabel {
                    width: parent.width
                    size: "sm"
                    tone: "default"
                    textFormat: Text.RichText
                    linkColor: Theme.primary
                    text: "<a href=\"https://github.com/LoopLess-nardoto/nardoto-editor-open\">%1</a>"
                          .arg(qsTr("Documentation"))
                    onLinkActivated: (link) => Qt.openUrlExternally(link)
                    HoverHandler {
                        cursorShape: parent.hoveredLink ? Qt.PointingHandCursor : Qt.ArrowCursor
                    }
                }

                ThemedLabel {
                    width: parent.width
                    size: "sm"
                    tone: "default"
                    textFormat: Text.RichText
                    linkColor: Theme.primary
                    text: "<a href=\"https://cutwire.org/discord\">%1</a>"
                          .arg(qsTr("Questions and support on Discord"))
                    onLinkActivated: (link) => Qt.openUrlExternally(link)
                    HoverHandler {
                        cursorShape: parent.hoveredLink ? Qt.PointingHandCursor : Qt.ArrowCursor
                    }
                }
            }
        }
    }
}
