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
    moduleName: "io.github.TowhidMolla-Dev.omarchy-hymos"  // must match manifest id
    ipcTarget: "io.github.TowhidMolla-Dev.omarchy-hymos"

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

    // ---- per-app profiles -------------------------------------------------
    // Profiles live in ~/.config/hypr/hymos-profiles.conf and are edited through
    // hymos-profiles.sh rather than straight from QML: the file has to keep its
    // comments and section order, and the plugin is what validates the values.
    // The plugin owns matching, so the panel only ever shows what it reports.
    property var profileRows: []
    property string profileWindow: ""
    property string profileError: ""

    function profileExists(glob) {
        return profileRows.some(function (r) { return r.glob === glob; });
    }

    function parseProfiles(text) {
        var rows = [];
        String(text).split("\n").forEach(function (line) {
            if (line.trim() === "") return;
            // The first line is a "# <count>" header, not a profile.
            if (line.charAt(0) === "#") return;
            var parts = line.split("\t");
            var row = { glob: parts[0], step: null, duration: null, dragRatio: null,
                        dragScroll: null, curve: "", enabled: null };
            parts.slice(1).forEach(function (kv) {
                var eq = kv.indexOf("=");
                if (eq < 0) return;
                var k = kv.slice(0, eq), v = kv.slice(eq + 1);
                if (k === "step") row.step = parseFloat(v);
                else if (k === "duration") row.duration = parseFloat(v);
                else if (k === "drag_ratio") row.dragRatio = parseFloat(v);
                else if (k === "drag_scroll") row.dragScroll = (v === "1");
                else if (k === "enabled") row.enabled = (v === "1");
                else if (k === "curve") row.curve = v;
            });
            rows.push(row);
        });
        return rows;
    }

    function refreshProfiles() {
        listProfilesProc.running = true;
        windowProc.running = true;
    }

    // "Add for this window" is only useful if it follows the cursor. Reading the
    // class on a timer while the panel is open costs one cheap hyprctl call a
    // second and keeps the button pointed at the window actually under it.
    Timer {
        interval: 1000
        running: root.opened && root.tab === "profiles"
        repeat: true
        onTriggered: if (!windowProc.running) windowProc.running = true
    }

    // Every edit goes: write the file, tell the plugin to reread it, then read
    // the list back. Reading back rather than patching local state means the
    // panel can never show something the plugin disagrees with.
    //
    // One edit at a time. A click during an edit replaces the queued one rather
    // than queueing several: they are all "set this field", so the last wins and
    // the intermediate states are not worth a process each.
    function profileEdit(args) {
        if (profileEditProc.running) { profileEditQueue = args; return; }
        runProfileEdit(args);
    }

    function runProfileEdit(args) {
        profileEditProc.command = ["bash", localPath("hymos-profiles.sh")].concat(args);
        profileEditProc.running = true;
    }

    property var profileEditQueue: []

    function setProfileField(row, key, value) {
        if (value === null) profileEdit(["unset", row.glob, key]);
        else profileEdit(["set", row.glob, key, String(value)]);
    }

    Process {
        id: profileEditProc
        onExited: function (code) {
            // Reread the file either way, so the list always shows what is
            // really in it rather than what we hoped the edit did.
            reloadProc.running = true;
            listProfilesProc.running = true;

            if (profileEditQueue.length > 0) {
                // Report the failure of the edit that just finished, but let the
                // queued edit's own result decide the final message.
                root.profileError = code === 0 ? "" : (profileEditErr.text.trim() || ("exit " + code));
                var next = profileEditQueue;
                profileEditQueue = [];
                runProfileEdit(next);
                return;
            }
            // Last edit of the burst: its result is the one that stands.
            root.profileError = code === 0 ? "" : (profileEditErr.text.trim() || ("exit " + code));
        }
        stdout: StdioCollector { id: profileEditOut }
        stderr: StdioCollector { id: profileEditErr }
    }

    Process {
        id: reloadProc
        command: ["hyprctl", "hymos", "reload"]
        running: false
    }

    Process {
        id: listProfilesProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.profileRows = root.parseProfiles(text)
        }
    }

    Process {
        id: windowProc
        command: ["hyprctl", "hymos", "profile"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                // The class line is the one after "window:"; anything else in
                // the report (matched, effective) is about the cursor's window
                // rather than this query.
                var m = String(text).match(/^window:\s*(.+)$/m);
                root.profileWindow = m ? m[1].trim() : "";
                if (root.profileWindow === "<none>") root.profileWindow = "";
            }
        }
    }

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
    onTabChanged: if (tab === "profiles") refreshProfiles()

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
        // The panel is never taller than this, so the page area below the hero
        // and tabs has to fit inside it. maxPanelHeight is shared with the
        // Flickable so the two can never disagree about how much room is left.
        readonly property int maxPanelHeight: Style.space(660)
        contentHeight: panel.fittedContentHeight(column.implicitHeight, maxPanelHeight)

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent

            onCloseRequested: root.close()
            onTabRequested: function (direction) { root.switchPanel(direction) }
            // ←/→ nudge the horizontal knob, ↑/↓ the vertical one, for
            // whichever page is showing so the keys never edit a hidden tab.
            onMoveRequested: function (dx, dy) {
                if (root.tab === "profiles") return; // nothing to nudge here
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
                    id: hero
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
                    id: errorText
                    visible: root.error !== ""
                    width: parent.width
                    textFormat: Text.PlainText
                    text: Strings.t("error") + ": " + root.error
                    color: Color.urgent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                }

                PanelSeparator { id: separator; width: parent.width; foreground: root.foreground }

                ButtonGroup {
                    id: tabStrip
                    width: parent.width
                    focusable: false
                    options: [
                        { value: "wheel", label: Strings.t("tabWheel") },
                        { value: "drag", label: Strings.t("tabDrag") },
                        { value: "profiles", label: Strings.t("tabProfiles") }
                    ]
                    value: root.tab
                    onChanged: function (value) { root.tab = value }
                }

                // Only the visible page is instantiated, so the drag controls
                // cost nothing until the tab is actually opened.
                //
                // Wrapped in a Flickable because the drag page is taller than the
                // panel's height cap: without this the controls below the fold
                // (speed, fling, coast) simply could not be reached. The wheel
                // and hero stay outside it, so they never scroll away.
                Flickable {
                    id: pageScroll
                    width: parent.width
                    // Grow to the content, but never past the room the panel
                    // has left under the hero and the tab strip.
                    //
                    // The cap comes from availableCardHeight, which is derived
                    // from the screen, rather than from panel.contentHeight:
                    // that one is fitted to column.implicitHeight, so measuring
                    // against it would feed this item's height back into its own
                    // height and form a binding loop.
                    height: Math.min(contentHeight, maxScrollableHeight)
                    contentWidth: width
                    // Loader's own implicitHeight follows the loaded item, but
                    // reading it through `page.item` keeps this correct for any
                    // page that sizes itself from its children.
                    contentHeight: page.item ? page.item.implicitHeight : 0
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    // Only take wheel events when there is something below the
                    // fold; otherwise a short page swallows the scroll.
                    interactive: contentHeight > height
                    // How far down the page can go. Flickable has originY but no
                    // maximumY, so this is derived: without it the clamps below
                    // were reading an undefined property.
                    readonly property real maxScrollY: Math.max(0, contentHeight - height)
                    // Switching tabs must not leave the next page scrolled, and a
                    // card collapsing under the cursor must not strand the view
                    // past the new bottom.
                    onContentHeightChanged: if (contentY > maxScrollY) contentY = 0
                    onHeightChanged: if (contentY > maxScrollY) contentY = 0
                    onWidthChanged: contentX = 0

                    // Ceiling is min(the panel's own cap, the screen's room) minus
                    // the inset and the chrome above. Using the panel's cap as well
                    // matters: availableCardHeight alone is far larger than 660, so
                    // relying on it would size the page area past what the panel
                    // actually shows and clip it again.
                    readonly property real maxScrollableHeight: Math.max(0, Math.min(panel.maxPanelHeight, panel.availableCardHeight) - panel.verticalContentInset - chromeHeight)
                    readonly property real chromeHeight: hero.implicitHeight + separator.height + tabStrip.height + Style.space(12) * 4

                    Loader {
                        id: page
                        width: pageScroll.width
                        sourceComponent: {
                            if (root.tab === "drag") return dragPage;
                            if (root.tab === "profiles") return profilesPage;
                            return wheelPage;
                        }
                    }
                }

                Component {
                    id: wheelPage
                    Column {
                        width: pageScroll.width
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
                        width: pageScroll.width
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
// Per-app profiles. Each card is one [profile <glob>] section in
                // hymos-profiles.conf. A control left on "inherit" writes no key
                // at all, which is what lets the global value come back through.
                Component {
                    id: profilesPage
                    Column {
                        width: pageScroll.width
                        spacing: Style.space(12)

                        Item {
                            width: parent.width
                            implicitHeight: cursorHeader.implicitHeight

                            PanelSectionHeader {
                                id: cursorHeader
                                anchors.left: parent.left
                                anchors.right: addHere.left
                                anchors.rightMargin: Style.space(8)
                                text: Strings.t("profilesUnderCursor")
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                            }

                            Button {
                                id: addHere
                                anchors.right: parent.right
                                anchors.verticalCenter: cursorHeader.verticalCenter
                                enabled: root.profileWindow !== "" && !root.profileExists(root.profileWindow)
                                text: root.profileExists(root.profileWindow)
                                      ? Strings.t("profilesExists")
                                      : Strings.t("profilesAddHere")
                                focusable: false
                                fontFamily: root.fontFamily
                                fontSize: Style.font.caption
                                onClicked: root.profileEdit(["add", root.profileWindow])
                            }
                        }

                        Text {
                            width: parent.width
                            visible: root.profileWindow === ""
                            textFormat: Text.PlainText
                            text: Strings.t("profilesNone")
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            wrapMode: Text.WordWrap
                        }

                        Text {
                            width: parent.width
                            visible: root.profileRows.length === 0
                            textFormat: Text.PlainText
                            text: Strings.t("profilesEmpty") + "\n" + Strings.t("profilesEmptyHint")
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.WordWrap
                        }

                        Repeater {
                            id: profileRepeater
                            model: root.profileRows

                            delegate: Rectangle {
                                id: profileCard
                                required property var modelData
                                required property int index

                                readonly property var row: modelData
                                property bool expanded: index === 0

                                // Knobs show the profile's value when it has one, and the
                                // global value otherwise, so a slider always sits at the
                                // value actually in force.
                                readonly property real stepValue: row.step === null ? root.step : row.step
                                readonly property real durationValue: row.duration === null ? root.duration : row.duration

                                // "inherit" for the keys the profile does not set.
                                readonly property string summary: {
                                    var bits = [];
                                    bits.push(row.enabled === null ? Strings.t("profilesInherit")
                                                               : (row.enabled ? Strings.t("profilesSummaryOn") : Strings.t("profilesSummaryOff")));
                                    if (row.step !== null) bits.push(Strings.t("intensity") + " " + Math.round(row.step));
                                    if (row.duration !== null) bits.push(Strings.t("glide") + " " + Math.round(row.duration) + "ms");
                                    if (row.curve !== "") bits.push(row.curve);
                                    if (row.dragScroll !== null)
                                        bits.push(Strings.t("dragEnable") + ": " + (row.dragScroll ? Strings.t("profilesSummaryOn") : Strings.t("profilesSummaryOff")));
                                    return bits.join("  ·  ");
                                }

                                width: pageScroll.width
                                implicitHeight: cardColumn.implicitHeight + Style.space(20)
                                radius: Style.cornerRadius > 0 ? Style.cornerRadius : 0
                                color: Style.selectedFillFor(root.foreground, Color.accent)
                                border.width: 1
                                border.color: root.dim

                                Column {
                                    id: cardColumn
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.top: parent.top
                                    anchors.margins: Style.space(10)
                                    spacing: Style.space(8)

                                    Item {
                                        width: parent.width
                                        implicitHeight: nameRow.implicitHeight

                                        PanelSectionHeader {
                                            id: nameRow
                                            anchors.left: parent.left
                                            anchors.right: profileActions.left
                                            anchors.rightMargin: Style.space(8)
                                            text: profileCard.row.glob
                                            foreground: root.foreground
                                            fontFamily: root.fontFamily
                                        }

                                        Row {
                                            id: profileActions
                                            anchors.right: parent.right
                                            anchors.verticalCenter: nameRow.verticalCenter
                                            spacing: Style.space(4)

                                            PanelActionButton {
                                                iconText: profileCard.expanded ? "-" : "+"
                                                tooltipText: profileCard.expanded ? Strings.t("profilesCollapse") : Strings.t("profilesExpand")
                                                size: Style.space(20)
                                                fontSize: Style.font.caption
                                                foreground: root.foreground
                                                onClicked: profileCard.expanded = !profileCard.expanded
                                            }

                                            PanelActionButton {
                                                iconText: "\u2715"
                                                tooltipText: Strings.t("profilesRemove")
                                                size: Style.space(20)
                                                fontSize: Style.font.caption
                                                foreground: root.foreground
                                                onClicked: root.profileEdit(["remove", profileCard.row.glob])
                                            }
                                        }
                                    }

                                    Text {
                                        width: parent.width
                                        visible: !profileCard.expanded
                                        textFormat: Text.PlainText
                                        text: profileCard.summary
                                        color: root.dim
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.caption
                                        elide: Text.ElideRight
                                        wrapMode: Text.WordWrap
                                    }

                                    Column {
                                        width: parent.width
                                        visible: profileCard.expanded
                                        spacing: Style.space(12)

                                        // Smooth scrolling for this app: inherit / on / off.
                                        // Three states, so a row of buttons rather than a
                                        // switch: a switch cannot express "inherit".
                                        Column {
                                            width: parent.width
                                            spacing: Style.space(6)

                                            PanelSectionHeader {
                                                width: parent.width
                                                text: Strings.t("profilesOn")
                                                foreground: root.foreground
                                                fontFamily: root.fontFamily
                                            }

                                            ButtonGroup {
                                                width: parent.width
                                                focusable: false
                                                options: [
                                                    { value: "inherit", label: Strings.t("profilesInherit") },
                                                    { value: "on", label: Strings.t("profilesSummaryOn") },
                                                    { value: "off", label: Strings.t("profilesSummaryOff") }
                                                ]
                                                value: profileCard.row.enabled === null ? "inherit"
                                                        : (profileCard.row.enabled ? "on" : "off")
                                                onChanged: function (v) {
                                                    root.setProfileField(profileCard.row, "enabled",
                                                        v === "inherit" ? null : (v === "on" ? 1 : 0));
                                                }
                                            }
                                        }

                                        // Step. Releasing the knob on the global value writes
                                        // nothing, so a profile cannot accidentally freeze the
                                        // global setting in place.
                                        SliderRow {
                                            width: parent.width
                                            dimmed: false
                                            title: Strings.t("intensity")
                                            hint: profileCard.row.step === null ? Strings.t("profilesInheritHint") : ""
                                            valueText: profileCard.row.step === null
                                                       ? Strings.t("profilesInherit")
                                                       : String(Math.round(profileCard.row.step))
                                            PanelSlider {
                                                bar: root.bar
                                                width: parent.width
                                                minimum: 1
                                                maximum: 12
                                                step: 1
                                                integer: true
                                                value: profileCard.stepValue
                                                onReleased: function (v) {
                                                    root.setProfileField(profileCard.row, "step",
                                                        Math.round(v) === Math.round(root.step) ? null : Math.round(v));
                                                }
                                            }
                                        }

                                        SliderRow {
                                            width: parent.width
                                            dimmed: false
                                            title: Strings.t("glide")
                                            hint: profileCard.row.duration === null ? Strings.t("profilesInheritHint") : ""
                                            valueText: profileCard.row.duration === null
                                                       ? Strings.t("profilesInherit")
                                                       : String(Math.round(profileCard.row.duration))
                                            PanelSlider {
                                                bar: root.bar
                                                width: parent.width
                                                minimum: 80
                                                maximum: 900
                                                step: 10
                                                integer: true
                                                value: profileCard.durationValue
                                                onReleased: function (v) {
                                                    root.setProfileField(profileCard.row, "duration",
                                                        Math.round(v) === Math.round(root.duration) ? null : Math.round(v));
                                                }
                                            }
                                        }

                                        // Curve: the three shapes, plus inherit.
                                        Column {
                                            width: parent.width
                                            spacing: Style.space(6)

                                            PanelSectionHeader {
                                                width: parent.width
                                                text: Strings.t("curve")
                                                foreground: root.foreground
                                                fontFamily: root.fontFamily
                                            }

                                            ButtonGroup {
                                                width: parent.width
                                                focusable: false
                                                options: [
                                                    { value: "inherit", label: Strings.t("profilesInherit") },
                                                    { value: "expo", label: Strings.t("curveExpo") },
                                                    { value: "linear", label: Strings.t("curveLinear") },
                                                    { value: "smooth", label: Strings.t("curveSmooth") }
                                                ]
                                                value: profileCard.row.curve === "" ? "inherit" : profileCard.row.curve
                                                onChanged: function (v) {
                                                    root.setProfileField(profileCard.row, "curve", v === "inherit" ? null : v);
                                                }
                                            }
                                        }

                                        // Drag-to-scroll for this app.
                                        Column {
                                            width: parent.width
                                            spacing: Style.space(6)

                                            PanelSectionHeader {
                                                width: parent.width
                                                text: Strings.t("dragEnable")
                                                foreground: root.foreground
                                                fontFamily: root.fontFamily
                                            }

                                            ButtonGroup {
                                                width: parent.width
                                                focusable: false
                                                options: [
                                                    { value: "inherit", label: Strings.t("profilesInherit") },
                                                    { value: "on", label: Strings.t("profilesSummaryOn") },
                                                    { value: "off", label: Strings.t("profilesSummaryOff") }
                                                ]
                                                value: profileCard.row.dragScroll === null ? "inherit"
                                                        : (profileCard.row.dragScroll ? "on" : "off")
                                                onChanged: function (v) {
                                                    root.setProfileField(profileCard.row, "drag_scroll",
                                                        v === "inherit" ? null : (v === "on" ? 1 : 0));
                                                }
                                            }
                                        }

                                        Text {
                                            width: parent.width
                                            visible: profileCard.row.enabled === false
                                            textFormat: Text.PlainText
                                            text: Strings.t("profilesDisabledHint")
                                            color: root.dim
                                            font.family: root.fontFamily
                                            font.pixelSize: Style.font.caption
                                            wrapMode: Text.WordWrap
                                        }
                                    }
                                }
                            }
                        }

                        Text {
                            width: parent.width
                            visible: root.profileError !== ""
                            textFormat: Text.PlainText
                            text: root.profileError
                            color: Color.urgent
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            wrapMode: Text.WordWrap
                        }
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
