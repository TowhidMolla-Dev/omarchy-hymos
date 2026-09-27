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
#include <hyprland/src/config/ConfigValue.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string_view>
#include <vector>

inline HANDLE PHANDLE = nullptr;

namespace {
    using Clock = std::chrono::steady_clock;

    struct SConfig {
        bool        enabled    = true;
        double      step       = 4.0;   // pixels per wheel unit (libinput sends 15 units per click)
        double      durationMs = 320.0; // time for a scroll to settle (~98% of the distance)
        std::string exclude    = "steam_app_*, gamescope, *[Rr]etro[Aa]rch*";
        std::vector<std::string> excludeGlobs = {"steam_app_*", "gamescope", "*[Rr]etro[Aa]rch*"};
    };

    struct SAxisState {
        double remaining = 0.0;
        bool   active    = false;
        bool   mouse     = true;
        wl_pointer_axis_relative_direction relative = WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL;
    };

    SConfig                   g_config;
    // the exclude verdict for the last window scrolled over: every click of a
    // scroll lands on the same window, so the globs only run when it changes
    struct {
        std::string cls, initialClass;
        bool        excluded = false, valid = false;
    } g_excludeCache;
    std::array<SAxisState, 2> g_axes; // vertical, horizontal
    SP<CEventLoopTimer>       g_timer;
    Clock::time_point         g_lastTick;
    Vector2D                  g_glideOrigin;  // cursor position at the last wheel click
    WP<CWLSurfaceResource>    g_glideSurface; // surface under the cursor at the last wheel click
    CHyprSignalListener       g_axisListener;
    SP<SHyprCtlCommand>       g_ctlCommand;

    constexpr auto TICK = std::chrono::microseconds(4000); // ~250Hz
    // a wheel click this far (px) from the previous one ends the gesture that
    // is still gliding and starts a new one, so the new scroll goes to the pane
    // now under the cursor; just moving the cursor keeps the glide going
    constexpr double GLIDE_SLOP = 10.0;

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

    // `exclude` is a comma-separated list of globs matched against the whole
    // window class: `*` any run, `?` any character, `[abc]` / `[a-z]` one of a
    // set. It used to be a std::regex, but that backtracks: a crafted pattern
    // can take exponential time on a window class, and this runs on every
    // wheel event inside the compositor. The glob matcher below only ever
    // returns to the last `*`, so a match costs at most O(class * pattern).
    struct SRegexExclude : std::invalid_argument {
        SRegexExclude() : std::invalid_argument("regex") {}
    };

    std::vector<std::string> parseGlobs(const std::string& val) {
        // an old regex value would silently mean something else as a glob
        if (val.find_first_of("^$()|{}\\+") != std::string::npos || val.find(".*") != std::string::npos)
            throw SRegexExclude();
        std::vector<std::string> globs;
        std::istringstream       in(val);
        for (std::string item; std::getline(in, item, ',');) {
            item = trim(item);
            for (size_t i = 0; i < item.size(); ++i) {
                if (item[i] == ']')
                    throw std::invalid_argument("glob");
                if (item[i] == '[') {
                    const auto close = item.find(']', i + 1);
                    if (close == std::string::npos || close == i + 1 || item.find('[', i + 1) < close)
                        throw std::invalid_argument("glob");
                    i = close;
                }
            }
            if (!item.empty())
                globs.push_back(std::move(item));
        }
        return globs;
    }

    // length of the glob element at `g` (a `[...]` set or a single character)
    size_t elemLen(std::string_view glob, size_t g) {
        return glob[g] == '[' ? glob.find(']', g) - g + 1 : 1;
    }

    bool elemMatches(std::string_view glob, size_t g, char c) {
        if (glob[g] == '?')
            return true;
        if (glob[g] != '[')
            return glob[g] == c;
        const auto close = glob.find(']', g);
        for (size_t i = g + 1; i < close; ++i) {
            if (i + 2 < close && glob[i + 1] == '-') {
                if (c >= glob[i] && c <= glob[i + 2])
                    return true;
                i += 2;
            } else if (glob[i] == c)
                return true;
        }
        return false;
    }

    bool globMatch(std::string_view glob, std::string_view str) {
        size_t g = 0, s = 0, star = std::string::npos, mark = 0;
        while (s < str.size()) {
            if (g < glob.size() && glob[g] == '*') {
                star = g++;
                mark = s;
            } else if (g < glob.size() && elemMatches(glob, g, str[s])) {
                g += elemLen(glob, g);
                ++s;
            } else if (star != std::string::npos) {
                g = star + 1;
                s = ++mark;
            } else
                return false;
        }
        while (g < glob.size() && glob[g] == '*')
            ++g;
        return g == glob.size();
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
                    cfg.excludeGlobs = parseGlobs(val);
                    cfg.exclude      = val;
                } else
                    errors += "unknown key: " + clip(key, MAX_ERROR_CHARS) + "\n";
            } catch (const SRegexExclude&) {
                errors += "exclude is a list of globs now, not a regex (e.g. steam_app_*, gamescope, *[Rr]etro[Aa]rch*); keeping the default\n";
            } catch (const std::exception& e) { errors += "bad value for " + clip(key, MAX_ERROR_CHARS) + ": " + clip(val, MAX_ERROR_CHARS) + "\n"; }
        }

        g_config             = std::move(cfg);
        g_excludeCache.valid = false;
        return errors;
    }

    uint32_t nowMs() {
        return std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now().time_since_epoch()).count();
    }

    // The glide is replayed as a touchpad (finger) scroll: pixel deltas, and
    // an axis_stop when it settles. Apps handle that best: each gesture has an
    // explicit start and end, stays on the pane where it began while it glides,
    // and the next one picks the pane under the cursor. (A continuous source
    // left Chromium latched to the old pane, a high-resolution wheel made
    // terminals scroll line by line.)
    void emitAxis(size_t idx, double delta) {
        IPointer::SAxisEvent ev;
        ev.timeMs            = nowMs();
        ev.source            = WL_POINTER_AXIS_SOURCE_FINGER;
        ev.axis              = idx == 0 ? WL_POINTER_AXIS_VERTICAL_SCROLL : WL_POINTER_AXIS_HORIZONTAL_SCROLL;
        ev.relativeDirection = g_axes[idx].relative;
        ev.delta             = delta;
        ev.deltaDiscrete     = 0;
        ev.mouse             = g_axes[idx].mouse;
        // Hyprland scales finger scrolls by the touchpad factor; undo it so the
        // wheel keeps its own speed
        static auto PTOUCHPADSCROLLFACTOR = CConfigValue<Config::FLOAT>("input:touchpad:scroll_factor");
        if (*PTOUCHPADSCROLLFACTOR > 0.f)
            ev.delta /= std::clamp<double>(*PTOUCHPADSCROLLFACTOR, 0.1, 10.0);
        g_pInputManager->onMouseWheel(ev);
        // replayed events defer the frame (normally sent by the device), so send it ourselves
        g_pSeatManager->sendPointerFrame();
    }

    // Ends the gesture on `idx` without leaving momentum behind. Chromium turns
    // a finger axis_stop into a fling, and a new same-direction scroll within
    // 50ms "boosts" that fling, i.e. keeps scrolling the old pane. Its fling
    // velocity only counts the finger frames right before the stop, so one
    // invisible continuous frame (1/256 px, the smallest wl_fixed) first makes
    // the fling start at zero and the next scroll pick the pane under the cursor.
    void endGestureWithoutMomentum(size_t idx) {
        const auto axis = idx == 0 ? WL_POINTER_AXIS_VERTICAL_SCROLL : WL_POINTER_AXIS_HORIZONTAL_SCROLL;
        g_pSeatManager->sendPointerAxis(nowMs(), axis, 1.0 / 256.0, 0, 0, WL_POINTER_AXIS_SOURCE_CONTINUOUS, g_axes[idx].relative);
        g_pSeatManager->sendPointerFrame();
        emitAxis(idx, 0);
    }

    void onTick(SP<CEventLoopTimer> self, void*) {
        const auto now = Clock::now();
        const auto dt  = std::chrono::duration<double, std::milli>(now - g_lastTick).count();
        g_lastTick     = now;

        // just moving the cursor keeps the glide, but not into another window
        if (g_pSeatManager->m_state.pointerFocus != g_glideSurface) {
            for (size_t i = 0; i < g_axes.size(); ++i) {
                if (g_axes[i].active) {
                    g_axes[i] = {.remaining = 0, .active = false, .mouse = g_axes[i].mouse, .relative = g_axes[i].relative};
                    endGestureWithoutMomentum(i);
                }
            }
            return;
        }

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

        if (!g_config.excludeGlobs.empty()) {
            const auto PWINDOW = Desktop::viewState()->hitTest().windowAt(g_pInputManager->getMouseCoordsInternal(),
                                                                          Desktop::View::RESERVED_EXTENTS | Desktop::View::INPUT_EXTENTS | Desktop::View::ALLOW_FLOATING);
            if (!PWINDOW)
                return false;
            // any client sets its own class, so only its first MAX_CLASS_CHARS are matched (and cached)
            const auto cls     = std::string_view(PWINDOW->m_class).substr(0, MAX_CLASS_CHARS);
            const auto initial = std::string_view(PWINDOW->m_initialClass).substr(0, MAX_CLASS_CHARS);
            auto&      cache   = g_excludeCache;
            if (!cache.valid || cache.cls != cls || cache.initialClass != initial) {
                const auto excluded = [](std::string_view c) {
                    return std::ranges::any_of(g_config.excludeGlobs, [&](const auto& glob) { return globMatch(glob, c); });
                };
                cache = {std::string(cls), std::string(initial), excluded(cls) || excluded(initial), true};
            }
            if (cache.excluded)
                return true;
        }

        return false;
    }

    void onAxis(IPointer::SAxisEvent e, Event::SCallbackInfo& info) {
        // only intercept real wheels; our own replayed events (finger, plus the continuous marker) fall through
        if (e.source != WL_POINTER_AXIS_SOURCE_WHEEL || e.delta == 0 || shouldPassThrough())
            return;

        info.cancelled = true;

        const size_t idx = e.axis == WL_POINTER_AXIS_VERTICAL_SCROLL ? 0 : 1;
        auto&        ax  = g_axes[idx];
        const double add = e.delta * g_config.step;

        // reversing direction drops what was still gliding the other way
        const auto pos = g_pInputManager->getMouseCoordsInternal();
        if (ax.active && std::signbit(ax.remaining) != std::signbit(add))
            ax.remaining = 0;
        // a click somewhere else ends the old gesture (axis_stop) before this one
        // starts, so the app picks the pane under the cursor for the new scroll
        // instead of keeping it latched to the old one
        if (ax.active && (pos.distance(g_glideOrigin) > GLIDE_SLOP || g_pSeatManager->m_state.pointerFocus != g_glideSurface)) {
            ax.remaining = 0;
            ax.active    = false;
            endGestureWithoutMomentum(idx);
        }
        g_glideOrigin  = pos;
        g_glideSurface = g_pSeatManager->m_state.pointerFocus;

        ax.remaining = std::clamp(ax.remaining + add, -MAX_REMAINING, MAX_REMAINING);
        ax.mouse    = e.mouse;
        ax.relative = e.relativeDirection;

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

    return {"hymos", "Mos-style smooth scrolling for mouse wheels", "diogocezar", "1.0.2"};
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
