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
    readonly property string curve: setting("curve", "expo")
    readonly property bool   axisLock: setting("axis_lock", true)
    readonly property string language: setting("language", "auto")
    onLanguageChanged: Strings.language = language

    // Drag-to-scroll. The plugin consumes a single signed ratio, so direction
    // and speed are two knobs on this side and one derived value on the way out.
    readonly property bool   dragEnabled: setting("drag_scroll", true)
    readonly property string dragButton: setting("drag_button", "right")
    readonly property string dragDirection: setting("drag_direction", "mobile")
    readonly property int    dragSpeed: setting("drag_speed", 100)
    readonly property bool   clickSuppress: setting("drag_click_suppress", true)
    readonly property bool   dragFling: setting("drag_fling", true)
    readonly property int    dragCoast: setting("drag_fling_tau", 380)
    readonly property real   dragRatio: (dragDirection === "laptop" ? 1 : -1) * (dragSpeed / 100)

    // Which control page the popup shows. Navigation, not configuration, so it
    // deliberately stays out of the settings store.
    property string tab: "wheel"

    function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

    readonly property color  foreground: bar ? bar.foreground : Color.foreground
    readonly property color  barForeground: bar ? bar.barForeground : Color.foreground
    readonly property color  dim: Qt.darker(foreground, 1.55)
    readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
    // the Hymos mark's gradient, as in assets/hymos-icon.svg
    readonly property var brandGradient: ["#3de8ff", "#7d8cff", "#c47dff"]

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
            "--duration", String(root.duration),
            "--curve", root.curve,
            "--axis-lock", root.axisLock ? "1" : "0",
            "--drag-scroll", root.dragEnabled ? "1" : "0",
            "--drag-button", root.dragButton,
            "--drag-ratio", root.dragRatio.toFixed(2),
            "--drag-fling", root.dragFling ? "1" : "0",
            "--drag-fling-tau", String(root.dragCoast),
            "--drag-click-suppress", root.clickSuppress ? "1" : "0"];
        applyProc.running = true;
    }

    // settings change → push to Hyprland; debounced so one edit is one call
    Timer { id: applyDebounce; interval: 150; onTriggered: root.apply() }
    onEnabledChanged: applyDebounce.restart()
    onStepChanged: applyDebounce.restart()
    onDurationChanged: applyDebounce.restart()
    onCurveChanged: applyDebounce.restart()
    onAxisLockChanged: applyDebounce.restart()
    onDragEnabledChanged: applyDebounce.restart()
    onDragButtonChanged: applyDebounce.restart()
    onDragDirectionChanged: applyDebounce.restart()
    onDragSpeedChanged: applyDebounce.restart()
    onDragFlingChanged: applyDebounce.restart()
    onClickSuppressChanged: applyDebounce.restart()
    onDragCoastChanged: applyDebounce.restart()
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
        contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(660))

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent

            onCloseRequested: root.close()
            onTabRequested: function (direction) { root.switchPanel(direction) }
            // ←/→ nudge the horizontal knob, ↑/↓ the vertical one, for
            // whichever page is showing so the keys never edit a hidden tab.
            onMoveRequested: function (dx, dy) {
                if (root.tab === "drag") {
                    if (dx !== 0) root.writeSettings({drag_speed: root.clamp(root.dragSpeed + dx * 5, 0, 100)});
                    if (dy !== 0) root.writeSettings({drag_fling_tau: root.clamp(root.dragCoast - dy * 10, 150, 900)});
                } else {
                    if (dx !== 0) root.writeSettings({step: root.clamp(root.step + dx, 1, 12)});
                    if (dy !== 0) root.writeSettings({duration: root.clamp(root.duration - dy * 40, 80, 900)});
                }
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
                        Logo { size: Style.font.display * 1.25; weight: 44; gradient: root.brandGradient }
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

                ButtonGroup {
                    id: tabStrip
                    width: parent.width
                    focusable: false
                    options: [
                        { value: "wheel", label: Strings.t("tabWheel") },
                        { value: "drag", label: Strings.t("tabDrag") }
                    ]
                    value: root.tab
                    onChanged: function (value) { root.tab = value }
                }

                // Only the visible page is instantiated, so the drag controls
                // cost nothing until the tab is actually opened.
                Loader {
                    id: page
                    width: parent.width
                    sourceComponent: root.tab === "drag" ? dragPage : wheelPage
                }

                Component {
                    id: wheelPage
                    Column {
                        width: page.width
                        spacing: Style.space(12)

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

                Component {
                    id: dragPage
                    Column {
                        width: page.width
                        spacing: Style.space(12)

                        Toggle {
                            width: parent.width
                            label: Strings.t("dragEnable")
                            description: Strings.t("dragEnableHint")
                            checked: root.dragEnabled
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            onClicked: root.writeSettings({drag_scroll: !root.dragEnabled})
                        }

                        SliderRow {
                            width: parent.width
                            dimmed: false
                            title: Strings.t("curve").toUpperCase()
                            valueText: ""
                            hint: Strings.t("curveHint")

                            ButtonGroup {
                                width: parent.width
                                focusable: false
                                options: [
                                    { value: "expo", label: Strings.t("curveExpo") },
                                    { value: "linear", label: Strings.t("curveLinear") },
                                    { value: "smooth", label: Strings.t("curveSmooth") }
                                ]
                                value: root.curve
                                onChanged: function (value) { root.writeSettings({curve: value}) }
                            }
                        }

                        Toggle {
                            width: parent.width
                            label: Strings.t("axisLock")
                            description: Strings.t("axisLockHint")
                            checked: root.axisLock
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            onClicked: root.writeSettings({axis_lock: !root.axisLock})
                        }

                        Toggle {
                            width: parent.width
                            label: Strings.t("clickSuppress")
                            description: Strings.t("clickSuppressHint")
                            checked: root.clickSuppress
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            onClicked: root.writeSettings({drag_click_suppress: !root.clickSuppress})
                        }

                        SliderRow {
                            width: parent.width
                            dimmed: false
                            title: Strings.t("dragButton").toUpperCase()
                            valueText: ""
                            hint: Strings.t("dragButtonHint")

                            ButtonGroup {
                                width: parent.width
                                focusable: false
                                options: [
                                    { value: "left", label: Strings.t("btnLeft") },
                                    { value: "middle", label: Strings.t("btnMiddle") },
                                    { value: "right", label: Strings.t("btnRight") }
                                ]
                                value: root.dragButton
                                onChanged: function (value) { root.writeSettings({drag_button: value}) }
                            }
                        }

                        SliderRow {
                            width: parent.width
                            dimmed: false
                            title: Strings.t("dragDirection").toUpperCase()
                            valueText: ""
                            hint: Strings.t("dragDirectionHint")

                            ButtonGroup {
                                width: parent.width
                                focusable: false
                                options: [
                                    { value: "mobile", label: Strings.t("dirMobile") },
                                    { value: "laptop", label: Strings.t("dirLaptop") }
                                ]
                                value: root.dragDirection
                                onChanged: function (value) { root.writeSettings({drag_direction: value}) }
                            }
                        }

                        SliderRow {
                            width: parent.width
                            dimmed: false
                            title: Strings.t("dragSpeed").toUpperCase()
                            valueText: Math.round(speed.liveValue) + "%"
                            hint: Strings.t("dragSpeedHint")

                            PanelSlider {
                                id: speed
                                bar: root.bar
                                width: parent.width
                                minimum: 0
                                maximum: 100
                                step: 5
                                integer: true
                                value: root.dragSpeed
                                onReleased: function (v) { root.writeSettings({drag_speed: Math.round(v)}) }
                            }
                        }

                        Toggle {
                            width: parent.width
                            label: Strings.t("dragFling")
                            description: Strings.t("dragFlingHint")
                            checked: root.dragFling
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            onClicked: root.writeSettings({drag_fling: !root.dragFling})
                        }

                        SliderRow {
                            width: parent.width
                            dimmed: !root.dragFling
                            title: Strings.t("dragCoast").toUpperCase()
                            valueText: root.dragFling ? Math.round(coast.liveValue) + " ms" : ""
                            hint: Strings.t("dragCoastHint")

                            PanelSlider {
                                id: coast
                                bar: root.bar
                                width: parent.width
                                minimum: 150
                                maximum: 900
                                step: 10
                                integer: true
                                value: root.dragCoast
                                onReleased: function (v) { root.writeSettings({drag_fling_tau: Math.round(v)}) }
                            }
                        }

                        Text {
                            width: parent.width
                            topPadding: Style.space(2)
                            text: Strings.t("dragFooter")
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.WordWrap
                        }
                    }
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
        // Rows grey out when the feature they drive is off. Drag rows pass
        // dimmed: false, since the wheel toggle says nothing about them.
        property bool dimmed: !root.enabled
        default property alias content: slot.data
        spacing: Style.space(6)
        opacity: dimmed ? 0.5 : 1.0
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
