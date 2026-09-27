import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar icon + popup for Hymos, built on the shell's native panel kit
// (KeyboardPanel / PanelHero / section headers / sliders). Settings live in
// the shell's store (shell.json); every change is pushed to the Hyprland
// plugin through hymos-apply.sh, which also builds and loads the plugin when
// needed, so the shell starting up is what brings smooth scrolling back after
// a reboot.
Panel {
    id: root
    moduleName: "diogocezar.hymos"  // must match manifest id
    ipcTarget: "diogocezar.hymos"

    readonly property bool   enabled: setting("enabled", true)
    readonly property int    step: setting("step", 4)
    readonly property int    duration: setting("duration", 320)
    readonly property string language: setting("language", "auto")
    onLanguageChanged: Strings.language = language

    readonly property color  foreground: bar ? bar.foreground : Color.foreground
    readonly property color  barForeground: bar ? bar.barForeground : Color.foreground
    readonly property color  dim: Qt.darker(foreground, 1.55)
    readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

    // last hymos-apply.sh failure, shown in the popup; empty when all is well
    property string error: ""

    function localPath(relativePath) {
        var url = Qt.resolvedUrl(relativePath).toString();
        return url.startsWith("file://") ? decodeURIComponent(url.substring(7)) : url;
    }

    function writeSettings(patch) {
        var updated = Object.assign({}, root.settings, patch);
        if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, updated);
    }

    // stderr is capped before it reaches the collector (the panel shows it)
    Process {
        id: applyProc
        stdout: StdioCollector { id: applyErr }
        onExited: function (code) { root.error = code === 0 ? "" : (applyErr.text.trim() || ("exit " + code)) }
    }

    function apply() {
        if (applyProc.running) { applyDebounce.restart(); return; }
        applyProc.command = ["bash", "-c", 'bash "$0" "$@" 2>&1 >/dev/null | head -c 4096; exit "${PIPESTATUS[0]}"',
            localPath("hymos-apply.sh"),
            "--enabled", root.enabled ? "1" : "0",
            "--step", String(root.step),
            "--duration", String(root.duration)];
        applyProc.running = true;
    }

    // settings change → push to Hyprland; debounced so one edit is one call
    Timer { id: applyDebounce; interval: 150; onTriggered: root.apply() }
    onEnabledChanged: applyDebounce.restart()
    onStepChanged: applyDebounce.restart()
    onDurationChanged: applyDebounce.restart()
    Component.onCompleted: {
        Strings.language = language;
        applyDebounce.restart();
    }

    function intensityLabel(v) {
        if (v <= 2) return Strings.t("level_low");
        if (v <= 5) return Strings.t("level_medium");
        if (v <= 8) return Strings.t("level_high");
        return Strings.t("level_max");
    }
    function glideLabel(ms) {
        if (ms <= 180) return Strings.t("glide_short");
        if (ms <= 400) return Strings.t("glide_medium");
        if (ms <= 650) return Strings.t("glide_long");
        return Strings.t("glide_max");
    }

    onOpenedChanged: if (opened) Qt.callLater(function () { keyCatcher.forceActiveFocus() })

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        useActiveColor: false
        tooltipText: root.error !== "" ? Strings.t("error")
                                       : Strings.t(root.enabled ? "tooltipOn" : "tooltipOff")
        onPressed: function (b) {
            if (b === Qt.MiddleButton) root.writeSettings({enabled: !root.enabled});
            else root.toggle();
        }

        iconComponent: Component {
            Logo {
                size: Math.round(Style.bar.iconCanvas * 0.8)
                weight: 64
                color: root.error !== "" ? Color.urgent
                     : root.enabled ? root.barForeground : Qt.darker(root.barForeground, 1.9)
            }
        }
    }

    KeyboardPanel {
        id: panel
        anchorItem: button
        owner: root
        bar: root.bar
        open: root.opened
        focusTarget: keyCatcher
        contentWidth: panel.fittedContentWidth(Style.space(340))
        contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent

            onCloseRequested: root.close()
            onTabRequested: function (direction) { root.switchPanel(direction) }
            // ←/→ nudge intensity, ↑/↓ nudge glide
            onMoveRequested: function (dx, dy) {
                if (dx !== 0) root.writeSettings({step: Math.max(1, Math.min(12, root.step + dx))});
                if (dy !== 0) root.writeSettings({duration: Math.max(80, Math.min(900, root.duration - dy * 40))});
            }

            Column {
                id: column
                width: parent.width
                spacing: Style.space(12)

                PanelHero {
                    width: parent.width
                    title: "Hymos"
                    meta: Strings.t(root.enabled ? "on" : "off")
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    iconOpacity: root.enabled ? 1.0 : 0.45

                    iconComponent: Component {
                        Logo { size: Style.font.display * 1.25; weight: 44; color: root.foreground }
                    }

                    trailingControl: Component {
                        ToggleSwitch {
                            checked: root.enabled
                            foreground: root.foreground
                            onToggled: root.writeSettings({enabled: !root.enabled})
                        }
                    }
                }

                Text {
                    visible: root.error !== ""
                    width: parent.width
                    textFormat: Text.PlainText
                    text: Strings.t("error") + ": " + root.error
                    color: Color.urgent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                }

                PanelSeparator { width: parent.width; foreground: root.foreground }

                SliderRow {
                    width: parent.width
                    title: Strings.t("intensity").toUpperCase()
                    valueText: root.intensityLabel(intensity.liveValue) + " · " + Math.round(intensity.liveValue)
                    hint: Strings.t("intensityHint")

                    PanelSlider {
                        id: intensity
                        bar: root.bar
                        width: parent.width
                        minimum: 1
                        maximum: 12
                        step: 1
                        integer: true
                        value: root.step
                        onReleased: function (v) { root.writeSettings({step: Math.round(v)}) }
                    }
                }

                SliderRow {
                    width: parent.width
                    title: Strings.t("glide").toUpperCase()
                    valueText: root.glideLabel(glide.liveValue) + " · " + Math.round(glide.liveValue) + " ms"
                    hint: Strings.t("glideHint")

                    PanelSlider {
                        id: glide
                        bar: root.bar
                        width: parent.width
                        minimum: 80
                        maximum: 900
                        step: 20
                        integer: true
                        value: root.duration
                        onReleased: function (v) { root.writeSettings({duration: Math.round(v / 10) * 10}) }
                    }
                }

                Text {
                    width: parent.width
                    topPadding: Style.space(2)
                    text: Strings.t("footer")
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                }
            }
        }
    }

    // Section header with the current value on the right, the slider, and a hint.
    component SliderRow: Column {
        id: sliderRow
        property string title: ""
        property string valueText: ""
        property string hint: ""
        default property alias content: slot.data
        spacing: Style.space(6)
        opacity: root.enabled ? 1.0 : 0.5
        Behavior on opacity { NumberAnimation { duration: 120 } }

        Item {
            width: parent.width
            implicitHeight: header.implicitHeight

            PanelSectionHeader {
                id: header
                anchors.left: parent.left
                anchors.right: valueLabel.left
                text: sliderRow.title
                foreground: root.foreground
                fontFamily: root.fontFamily
            }

            Text {
                id: valueLabel
                anchors.right: parent.right
                anchors.verticalCenter: header.verticalCenter
                textFormat: Text.PlainText
                text: sliderRow.valueText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
            }
        }

        Item {
            id: slot
            width: parent.width
            implicitHeight: childrenRect.height
        }

        Text {
            width: parent.width
            textFormat: Text.PlainText
            text: sliderRow.hint
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
        }
    }
}
