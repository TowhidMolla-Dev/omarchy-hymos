// Hymos: Mos-style smooth scrolling for mouse wheels in Hyprland.
//
// Wheel events (discrete clicks) are cancelled and replayed as a stream of
// small "continuous" axis events with an exponential ease-out, so clients
// scroll pixel by pixel instead of jumping a few lines per click.

#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/managers/SeatManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopTimer.hpp>
#include <hyprland/src/desktop/state/ViewState.hpp>
#include <hyprland/src/desktop/state/ViewHitTester.hpp>
#include <hyprland/src/desktop/view/Window.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <regex>
#include <sstream>

inline HANDLE PHANDLE = nullptr;

namespace {
    using Clock = std::chrono::steady_clock;

    struct SConfig {
        bool        enabled    = true;
        double      step       = 4.0;   // pixels per wheel unit (libinput sends 15 units per click)
        double      durationMs = 320.0; // time for a scroll to settle (~98% of the distance)
        std::string exclude    = R"(^(steam_app_.*|gamescope|.*[Rr]etro[Aa]rch.*)$)";
        std::regex  excludeRe{exclude};
    };

    struct SAxisState {
        double remaining = 0.0;
        bool   active    = false;
        bool   mouse     = true;
    };

    SConfig                   g_config;
    std::array<SAxisState, 2> g_axes; // vertical, horizontal
    SP<CEventLoopTimer>       g_timer;
    Clock::time_point         g_lastTick;
    CHyprSignalListener       g_axisListener;
    SP<SHyprCtlCommand>       g_ctlCommand;

    constexpr auto TICK = std::chrono::microseconds(4000); // ~250Hz

    // This code runs inside the compositor, so every input is bounded: the
    // config file, the values it holds, the exclude pattern and the window
    // class it is matched against (which any client can set).
    constexpr std::uintmax_t MAX_CONFIG_BYTES  = 64 * 1024;
    constexpr size_t         MAX_EXCLUDE_CHARS = 512;
    constexpr size_t         MAX_CLASS_CHARS   = 256;
    constexpr size_t         MAX_ERROR_CHARS   = 64;
    constexpr double         MIN_STEP = 0.1, MAX_STEP = 100.0;
    constexpr double         MIN_DURATION = 10.0, MAX_DURATION = 10000.0;
    constexpr double         MAX_REMAINING = 100000.0; // px still to glide, per axis

    std::string configPath() {
        const char* xdg  = std::getenv("XDG_CONFIG_HOME");
        const char* home = std::getenv("HOME");
        std::string base = xdg && *xdg ? xdg : std::string(home ? home : "") + "/.config";
        return base + "/hypr/hymos.conf";
    }

    std::string trim(const std::string& s) {
        const auto b = s.find_first_not_of(" \t\r\n");
        if (b == std::string::npos)
            return "";
        const auto e = s.find_last_not_of(" \t\r\n");
        return s.substr(b, e - b + 1);
    }

    std::string clip(const std::string& s, size_t max) {
        return s.size() <= max ? s : s.substr(0, max) + "...";
    }

    // finite and within [lo, hi], or throws like std::stod does on bad input
    double parseNumber(const std::string& val, double lo, double hi) {
        const double v = std::stod(val);
        if (!std::isfinite(v) || v < lo || v > hi)
            throw std::out_of_range("range");
        return v;
    }

    // Config file format: `key = value` lines, `#` comments. Missing file keeps defaults.
    std::string loadConfig() {
        SConfig     cfg;
        std::string line, errors;

        // only a small regular file: a FIFO or device here would block the compositor
        const auto      path = configPath();
        std::error_code ec;
        if (!std::filesystem::exists(path, ec)) {
            g_config = std::move(cfg);
            return "";
        }
        if (!std::filesystem::is_regular_file(path, ec) || std::filesystem::file_size(path, ec) > MAX_CONFIG_BYTES || ec)
            return "config is not a regular file under 64 KiB, keeping the current settings\n";

        std::ifstream file(path);
        while (std::getline(file, line)) {
            line = trim(line.substr(0, line.find('#')));
            const auto eq = line.find('=');
            if (line.empty() || eq == std::string::npos)
                continue;

            const auto key = trim(line.substr(0, eq));
            const auto val = trim(line.substr(eq + 1));
            try {
                if (key == "enabled")
                    cfg.enabled = val == "1" || val == "true" || val == "yes";
                else if (key == "step")
                    cfg.step = parseNumber(val, MIN_STEP, MAX_STEP);
                else if (key == "duration")
                    cfg.durationMs = parseNumber(val, MIN_DURATION, MAX_DURATION);
                else if (key == "exclude") {
                    if (val.size() > MAX_EXCLUDE_CHARS)
                        throw std::length_error("exclude");
                    cfg.excludeRe = std::regex(val);
                    cfg.exclude   = val;
                } else
                    errors += "unknown key: " + clip(key, MAX_ERROR_CHARS) + "\n";
            } catch (const std::exception& e) { errors += "bad value for " + clip(key, MAX_ERROR_CHARS) + ": " + clip(val, MAX_ERROR_CHARS) + "\n"; }
        }

        g_config = std::move(cfg);
        return errors;
    }

    uint32_t nowMs() {
        return std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now().time_since_epoch()).count();
    }

    void emitAxis(size_t idx, double delta) {
        IPointer::SAxisEvent ev;
        ev.timeMs        = nowMs();
        ev.source        = WL_POINTER_AXIS_SOURCE_CONTINUOUS;
        ev.axis          = idx == 0 ? WL_POINTER_AXIS_VERTICAL_SCROLL : WL_POINTER_AXIS_HORIZONTAL_SCROLL;
        ev.delta         = delta;
        ev.deltaDiscrete = 0;
        ev.mouse         = g_axes[idx].mouse;
        g_pInputManager->onMouseWheel(ev);
        // continuous events defer the frame (normally sent by the device), so send it ourselves
        g_pSeatManager->sendPointerFrame();
    }

    void onTick(SP<CEventLoopTimer> self, void*) {
        const auto now = Clock::now();
        const auto dt  = std::chrono::duration<double, std::milli>(now - g_lastTick).count();
        g_lastTick     = now;

        // exponential ease-out: tau chosen so ~98% of the distance is covered after `duration`
        const double frac = 1.0 - std::exp(-dt / (g_config.durationMs / 4.0));
        bool         any  = false;

        for (size_t i = 0; i < g_axes.size(); ++i) {
            auto& ax = g_axes[i];
            if (!ax.active)
                continue;

            double move = ax.remaining * frac;
            if (std::abs(ax.remaining - move) < 0.1)
                move = ax.remaining;

            ax.remaining -= move;
            if (move != 0)
                emitAxis(i, move);

            if (ax.remaining == 0) {
                ax.active = false;
                emitAxis(i, 0); // zero delta on a continuous source sends axis_stop
            } else
                any = true;
        }

        if (any)
            self->updateTimeout(TICK);
    }

    bool shouldPassThrough() {
        if (!g_config.enabled)
            return true;

        // modifier + wheel is used by binds (e.g. switching workspaces); keep it discrete
        if (g_pInputManager->getModsFromAllKBs() != 0)
            return true;

        if (!g_config.exclude.empty()) {
            const auto PWINDOW = Desktop::viewState()->hitTest().windowAt(g_pInputManager->getMouseCoordsInternal(),
                                                                          Desktop::View::RESERVED_EXTENTS | Desktop::View::INPUT_EXTENTS | Desktop::View::ALLOW_FLOATING);
            // std::regex recurses per character, so a huge class from a client could overflow the stack
            const auto excluded = [](const std::string& cls) {
                return std::regex_search(cls.size() <= MAX_CLASS_CHARS ? cls : cls.substr(0, MAX_CLASS_CHARS), g_config.excludeRe);
            };
            if (PWINDOW && (excluded(PWINDOW->m_class) || excluded(PWINDOW->m_initialClass)))
                return true;
        }

        return false;
    }

    void onAxis(IPointer::SAxisEvent e, Event::SCallbackInfo& info) {
        // only intercept real wheels; our own replayed events are CONTINUOUS and fall through
        if (e.source != WL_POINTER_AXIS_SOURCE_WHEEL || e.delta == 0 || shouldPassThrough())
            return;

        info.cancelled = true;

        const size_t idx = e.axis == WL_POINTER_AXIS_VERTICAL_SCROLL ? 0 : 1;
        auto&        ax  = g_axes[idx];
        const double add = e.delta * g_config.step;

        // reversing direction drops whatever was still gliding the other way
        if (ax.active && std::signbit(ax.remaining) != std::signbit(add))
            ax.remaining = 0;

        ax.remaining = std::clamp(ax.remaining + add, -MAX_REMAINING, MAX_REMAINING);
        ax.mouse = e.mouse;

        if (!ax.active) {
            ax.active = true;
            if (!g_timer->armed()) {
                g_lastTick = Clock::now() - TICK; // move on the first tick right away
                g_timer->updateTimeout(std::chrono::microseconds(0));
            }
        }
    }

    std::string ctl(eHyprCtlOutputFormat, std::string args) {
        std::istringstream in(args);
        std::string        cmd, sub;
        in >> cmd >> sub;

        if (sub == "reload") {
            const auto errors = loadConfig();
            return errors.empty() ? "ok\n" : errors;
        }
        if (sub == "on" || sub == "off" || sub == "toggle") {
            g_config.enabled = sub == "on" || (sub == "toggle" && !g_config.enabled);
            return g_config.enabled ? "enabled\n" : "disabled\n";
        }

        return std::format("enabled: {}\nstep: {}\nduration: {}\nexclude: {}\nconfig: {}\n", g_config.enabled, g_config.step, g_config.durationMs, g_config.exclude,
                           configPath());
    }
}

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    PHANDLE = handle;

    if (__hyprland_api_get_hash() != std::string(__hyprland_api_get_client_hash())) {
        HyprlandAPI::addNotification(PHANDLE, "[hymos] Built for a different Hyprland version, rebuild it", CHyprColor{1.0, 0.2, 0.2, 1.0}, 5000);
        throw std::runtime_error("[hymos] version mismatch");
    }

    const auto errors = loadConfig();
    if (!errors.empty())
        HyprlandAPI::addNotification(PHANDLE, "[hymos] " + errors, CHyprColor{1.0, 0.6, 0.2, 1.0}, 5000);

    g_timer = makeShared<CEventLoopTimer>(std::nullopt, onTick, nullptr);
    g_pEventLoopManager->addTimer(g_timer);

    g_axisListener = Event::bus()->m_events.input.mouse.axis.listen([](IPointer::SAxisEvent e, Event::SCallbackInfo& info) { onAxis(e, info); });
    g_ctlCommand   = HyprlandAPI::registerHyprCtlCommand(PHANDLE, SHyprCtlCommand{.name = "hymos", .exact = false, .fn = ctl});

    return {"hymos", "Mos-style smooth scrolling for mouse wheels", "diogocezar", "1.0.0"};
}

APICALL EXPORT void PLUGIN_EXIT() {
    g_axisListener.reset();
    if (g_ctlCommand)
        HyprlandAPI::unregisterHyprCtlCommand(PHANDLE, g_ctlCommand);
    if (g_timer) {
        g_timer->cancel();
        g_pEventLoopManager->removeTimer(g_timer);
        g_timer.reset();
    }
}
