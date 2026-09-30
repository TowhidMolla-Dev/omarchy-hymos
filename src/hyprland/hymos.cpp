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

#include <linux/input-event-codes.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cctype>
#include <cmath>
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <optional>
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

        // Drag to scroll: hold a button, move the mouse, content follows. The
        // press still reaches the app so an ordinary click keeps working; only
        // the motion past the threshold is taken over, and the release is
        // swallowed so the gesture never also counts as a click.
        bool     dragScroll      = false;
        uint32_t dragButton      = BTN_RIGHT;
        double   dragThreshold   = 4.0; // px of movement before it becomes a scroll
        // px scrolled per px of mouse movement, and the direction. Negative is
        // the default so a drag behaves like a finger: push the cursor up and the
        // page advances, exactly as it does on a touchscreen. Positive is the
        // grab-and-pull style, where the content follows the cursor instead.
        double   dragRatio       = -1.0;
        // When on, the drag button's press is held back from the app and only
        // replayed if the gesture turns out to be an ordinary click. That is
        // what keeps a drag from opening a context menu in GTK and Chromium,
        // which both pop one on button down.
        // How a wheel glide spends its distance over time. All three shapes
        // cover the same total, so this only changes the feel, never the range.
        //   expo   - front-loaded, big first move then a long tail (the default)
        //   linear - constant speed, then it stops
        //   smooth - slow start, fast middle, gentle landing
        enum class ECurve {
            EXPO,
            LINEAR,
            SMOOTH,
        };
        ECurve curve = ECurve::EXPO;
        // A diagonal drag splits its distance across both axes, which reads as a
        // stutter, so the first axis past the threshold claims the gesture.
        bool     axisLock         = true;
        bool     dragClickSuppress = true;
        bool     dragFling       = true;
        double   dragFlingFactor = 1.0; // multiplies the flick speed
        // Phone-like inertia. `dragFlingTau` is the decay time constant, so it
        // alone sets how far a flick travels (speed * tau) and how long it
        // lasts, independent of the wheel's `duration`. Speeds are clamped so a
        // violent flick cannot launch the page, and below the minimum there is
        // no coast at all.
        double dragFlingTau      = 380.0; // ms
        double dragFlingMinSpeed = 0.25;  // px/ms, release speed needed to coast
        double dragFlingMaxSpeed = 4.0;   // px/ms, ceiling on a flick
    };

    // Per-application overrides. A profile only lists what it changes; anything
    // it omits falls back to the global value. It lives in its own file next to
    // hymos.conf because that file is rewritten by hymos-apply.sh, which edits
    // it in place and would otherwise fight a hand-written section.
    struct SProfile {
        std::string              glob;
        std::optional<bool>      enabled;
        std::optional<double>    step;
        std::optional<double>    durationMs;
        std::optional<double>    dragRatio;
        std::optional<bool>      dragScroll;
        std::optional<SConfig::ECurve> curve;
    };

    struct SAxisState {
        double remaining = 0.0;
        bool   active    = false;
        bool   mouse     = true;
        wl_pointer_axis_relative_direction relative = WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL;
        // 0 means "use duration/4", the wheel's glide; a drag coast sets its own
        double tau = 0.0;
        // Peak magnitude of the gesture in flight, so a shaped curve can find
        // its phase (0 = nothing has been added yet)
        double total = 0.0;
        // Milliseconds this glide has been running, and how much of `total` a
        // shaped curve has handed out so far. Both only matter for `linear` and
        // `smooth`, which are driven by elapsed time rather than by decay.
        double elapsed   = 0.0;
        double easedDone = 0.0;
        // The profile's glide time, taken when this gesture started, so a
        // profile change or a window switch cannot retime a glide mid-flight.
        double durationMs = 0.0;
    };

    SConfig                   g_config;
    std::vector<SProfile>     g_profiles;
    // Which profile the last window resolved to. Kept at namespace scope (not as
    // a local static) so loadProfiles() can invalidate it: otherwise editing the
    // profiles and reloading would appear to do nothing until the cursor visited
    // a different window.
    struct {
        std::string     cls, initialClass;
        const SProfile* hit   = nullptr;
        bool            valid = false;
    } g_profileCache;
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
    // One drag gesture at a time. `armed` is "button down, still maybe a click",
    // `active` is "past the threshold, motion is being turned into scroll".
    struct {
        bool              armed = false, active = false;
        // The profile's px-per-px, pinned when the gesture activates
        double            ratio = -1.0;
        bool              suppressed = false; // press was withheld from the app
        // Which axis owns this gesture once it goes active (0 = vertical,
        // 1 = horizontal). -1 until the first threshold crossing picks one.
        int               axis = -1;
        uint32_t          button = 0;
        Vector2D          pressPos{};
        Vector2D          lastPos{};
        Vector2D          lastMovePx{};
        Clock::time_point pressAt{};
        Clock::time_point lastMove{};
        Vector2D          vel{}; // smoothed release speed, px/ms
        Clock::time_point velAt{};
    } g_drag;
    CHyprSignalListener g_buttonListener;
    CHyprSignalListener g_moveListener;

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
    constexpr double MIN_STEP = 0.1, MAX_STEP = 100.0;
    constexpr double MIN_DURATION = 10.0, MAX_DURATION = 10000.0;
    constexpr double MIN_DRAG_THRESHOLD = 0.0, MAX_DRAG_THRESHOLD = 1000.0;
    constexpr double MIN_DRAG_RATIO = -20.0, MAX_DRAG_RATIO = 20.0;
    constexpr double MAX_REMAINING = 100000.0; // px still to glide, per axis
    // A phone only coasts when the finger was still moving as it lifted. Wait
    // longer than this between the last motion and the release and the gesture
    // was parked, so it flings nothing.
    constexpr double FLING_FRESH_MS = 120.0;
    // The release speed is averaged over this window, so one jittery mouse
    // sample cannot set the coast on its own.
    constexpr double FLING_WINDOW_MS = 60.0;
    // Once the coast has slowed below this (px/ms) it is over; riding an
    // exponential tail reads as a stutter, and it would tick for seconds.
    constexpr double FLING_STOP_SPEED = 0.02;
    constexpr double MIN_DRAG_FLING_TAU = 20.0, MAX_DRAG_FLING_TAU = 5000.0;
    constexpr double MIN_DRAG_FLING_SPEED = 0.0, MAX_DRAG_FLING_SPEED = 50.0;
    // safety valve: a gesture armed longer than this is assumed to have lost its
    // release event and is dropped, so it can never keep cancelling motion
    constexpr double MAX_DRAG_SECONDS = 30.0;

    std::string configPath() {
        const char* xdg  = std::getenv("XDG_CONFIG_HOME");
        const char* home = std::getenv("HOME");
        std::string base = xdg && *xdg ? xdg : std::string(home ? home : "") + "/.config";
        return base + "/hypr/hymos.conf";
    }

    std::string profilesPath() {
        std::string main = configPath();
        const auto   pos  = main.rfind('/');
        return (pos == std::string::npos ? std::string() : main.substr(0, pos + 1)) + "hymos-profiles.conf";
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

    // a config file is hand-edited, so accept the usual spellings of a boolean
    bool parseBool(const std::string& val) {
        std::string v = val;
        std::transform(v.begin(), v.end(), v.begin(), [](unsigned char c) { return std::tolower(c); });
        if (v == "1" || v == "true" || v == "yes" || v == "on")
            return true;
        if (v == "0" || v == "false" || v == "no" || v == "off")
            return false;
        throw std::invalid_argument("boolean");
    }

    // Config file format: `key = value` lines, `#` comments. Missing file keeps defaults.
    // defined below; declared here because loadConfig() and the tick call them
    std::string     loadProfiles();
    double          effStep();
    double          effDuration();
    double          effDragRatio();
    SConfig::ECurve effCurve();

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
                    cfg.enabled = parseBool(val);
                else if (key == "step")
                    cfg.step = parseNumber(val, MIN_STEP, MAX_STEP);
                else if (key == "duration")
                    cfg.durationMs = parseNumber(val, MIN_DURATION, MAX_DURATION);
                else if (key == "drag_scroll")
                    cfg.dragScroll = parseBool(val);
                else if (key == "drag_button") {
                    if (val == "left")
                        cfg.dragButton = BTN_LEFT;
                    else if (val == "right")
                        cfg.dragButton = BTN_RIGHT;
                    else if (val == "middle")
                        cfg.dragButton = BTN_MIDDLE;
                    else
                        throw std::invalid_argument("button");
                } else if (key == "drag_threshold")
                    cfg.dragThreshold = parseNumber(val, MIN_DRAG_THRESHOLD, MAX_DRAG_THRESHOLD);
                else if (key == "drag_ratio")
                    cfg.dragRatio = parseNumber(val, MIN_DRAG_RATIO, MAX_DRAG_RATIO);
                else if (key == "curve") {
                    if (val == "expo")
                        cfg.curve = SConfig::ECurve::EXPO;
                    else if (val == "linear")
                        cfg.curve = SConfig::ECurve::LINEAR;
                    else if (val == "smooth")
                        cfg.curve = SConfig::ECurve::SMOOTH;
                    else
                        throw std::invalid_argument("curve");
                } else if (key == "axis_lock")
                    cfg.axisLock = parseBool(val);
                else if (key == "drag_click_suppress")
                    cfg.dragClickSuppress = parseBool(val);
                else if (key == "drag_fling")
                    cfg.dragFling = parseBool(val);
                else if (key == "drag_fling_factor")
                    cfg.dragFlingFactor = parseNumber(val, 0.0, 20.0);
                else if (key == "drag_fling_tau")
                    cfg.dragFlingTau = parseNumber(val, MIN_DRAG_FLING_TAU, MAX_DRAG_FLING_TAU);
                else if (key == "drag_fling_min_speed")
                    cfg.dragFlingMinSpeed = parseNumber(val, MIN_DRAG_FLING_SPEED, MAX_DRAG_FLING_SPEED);
                else if (key == "drag_fling_max_speed")
                    cfg.dragFlingMaxSpeed = parseNumber(val, MIN_DRAG_FLING_SPEED, MAX_DRAG_FLING_SPEED);
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
        g_drag               = {}; // a half-finished drag must not survive a reload
        errors += loadProfiles();
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
    void emitAxisRaw(size_t idx, double delta) {
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
    }

    // Replayed events defer the frame (normally sent by the device), so send it
    // here. Split out from the emit so a drag can put X and Y in a single frame
    // and the client sees one update per mouse event instead of two.
    void emitAxis(size_t idx, double delta) {
        emitAxisRaw(idx, delta);
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
                    g_axes[i].tau   = 0;
                    g_axes[i].total = 0;
                    g_axes[i].elapsed = 0;
                    g_axes[i].easedDone = 0;
                    endGestureWithoutMomentum(i);
                }
            }
            return;
        }

        bool any = false;

        for (size_t i = 0; i < g_axes.size(); ++i) {
            auto& ax = g_axes[i];
            if (!ax.active)
                continue;

            // A drag coast carries its own decay time so a flick can feel like
            // a flick instead of borrowing the wheel's `duration`; a wheel
            // glide keeps its ease-out, ~98% of the distance after `duration`.
            const double glideMs = ax.durationMs > 0.0 ? ax.durationMs : g_config.durationMs;
            const double tau     = ax.tau > 0.0 ? ax.tau : std::max(1.0, glideMs / 4.0);
            const double span    = std::max(1.0, glideMs);

            // Stop once the coast has slowed to a crawl instead of crawling out
            // the exponential tail for seconds.
            if (ax.tau > 0.0 && std::abs(ax.remaining / tau) < FLING_STOP_SPEED) {
                ax.remaining = 0;
                ax.active    = false;
                ax.tau       = 0;
                ax.total     = 0;
                ax.elapsed   = 0;
                ax.easedDone = 0;
                emitAxis(i, 0);
                continue;
            }

            // A drag coast always keeps its own exponential decay, so the curve
            // choice only shapes a wheel glide (tau == 0).
            const bool   isFling = ax.tau > 0.0;
            const double sign    = std::signbit(ax.remaining) ? -1.0 : 1.0;
            double       move    = 0.0;

            if (isFling) {
                move = ax.remaining * (1.0 - std::exp(-dt / tau));
            } else if (effCurve() == SConfig::ECurve::LINEAR) {
                // True constant speed: a fixed amount of distance per tick,
                // scaled by how big the queued gesture is. Scaling by `total`
                // rather than by what is left is what keeps it flat, and it
                // still drains within `duration` because total >= |remaining|.
                ax.elapsed += dt;
                move        = std::min(std::abs(ax.remaining), ax.total * dt / span);
            } else if (effCurve() == SConfig::ECurve::SMOOTH) {
                // Cosine ease-in-out over `duration`, driven by elapsed time so
                // the shape does not depend on the tick rate. The curve says how
                // much of `total` should be covered by now; this tick's share is
                // the difference from what it had already handed out.
                ax.elapsed += dt;
                const auto easeInOut = [](double t) { return 0.5 - 0.5 * std::cos(std::clamp(t, 0.0, 1.0) * M_PI); };
                if (ax.elapsed >= span) {
                    // Past `duration` the curve is finished and its output is
                    // pinned, so anything still queued has to be flushed here.
                    // Comparing against easedDone instead would leave a permanent
                    // stall the moment the user stopped scrolling.
                    move = std::abs(ax.remaining);
                } else {
                    const double reached = ax.total * easeInOut(ax.elapsed / span);
                    move                 = std::min(std::abs(ax.remaining), std::max(0.0, reached - ax.easedDone));
                    ax.easedDone         = reached;
                }
            } else {
                move = ax.remaining * (1.0 - std::exp(-dt / tau));
            }

            // Whichever shape produced it, a tick may never carry more than the
            // gesture has left, or `remaining` would flip sign and scroll back.
            move = std::copysign(std::min(std::abs(move), std::abs(ax.remaining)), sign);

            if (std::abs(ax.remaining - move) < 0.1)
                move = ax.remaining;

            ax.remaining -= move;
            if (move != 0)
                emitAxis(i, move);

            if (ax.remaining == 0) {
                ax.active = false;
                ax.tau    = 0;
                ax.total  = 0;
                ax.elapsed   = 0;
                ax.easedDone = 0;
                emitAxis(i, 0); // zero delta on a continuous source sends axis_stop
            } else
                any = true;
        }

        if (any)
            self->updateTimeout(TICK);
    }

    // true when the window under the cursor is on the exclude list
    bool isExcludedWindow() {
        if (g_config.excludeGlobs.empty())
            return false;

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
        return cache.excluded;
    }

    // Profiles are optional and hand-written, so a broken line must never take
    // the compositor down with it: it is reported and skipped.
    std::string loadProfiles() {
        std::vector<SProfile> profiles;
        std::string           errors, line;
        const auto            path = profilesPath();
        std::error_code       ec;
        if (!std::filesystem::exists(path, ec))
            return "";

        std::ifstream in(path);
        size_t        lineno = 0, current = SIZE_MAX;
        const auto    bad    = [&](const std::string& why) {
            if (errors.size() < 900)
                errors += std::string{errors.empty() ? "" : "; "} + path + ":" + std::to_string(lineno) + ": " + why;
        };

        while (std::getline(in, line)) {
            ++lineno;
            const auto text = trim(line);
            if (text.empty() || text[0] == '#')
                continue;

            // [profile <glob>] opens a section; anything else in brackets is a typo
            if (text.front() == '[') {
                // The glob itself may contain a character class such as
                // [Rr]etro[Aa]rch*, so the closing bracket has to be the LAST
                // one on the line, not the first.
                const auto body = text.substr(0, text.find('#'));
                const auto trimmedBody = trim(body);
                const auto close = trimmedBody.rfind(']');
                if (close == std::string::npos || close + 1 != trimmedBody.size()) {
                    bad("unterminated section header");
                    current = SIZE_MAX;
                    continue;
                }
                const auto head = trim(trimmedBody.substr(1, close - 1));
                if (head.rfind("profile", 0) != 0) {
                    bad("unknown section, expected [profile <window-class>]");
                    current = SIZE_MAX;
                    continue;
                }
                const auto glob = trim(head.substr(7));
                if (glob.empty()) {
                    bad("[profile] needs a window class glob");
                    current = SIZE_MAX;
                    continue;
                }
                profiles.push_back({.glob = glob});
                current = profiles.size() - 1;
                continue;
            }

            if (current == SIZE_MAX) {
                bad("setting outside any [profile] section");
                continue;
            }
            const auto eq = text.find('=');
            if (eq == std::string::npos) {
                bad("expected key = value");
                continue;
            }
            const auto key = trim(text.substr(0, eq));
            const auto val = trim(text.substr(eq + 1));
            auto&       pr  = profiles[current];

            const auto asBool = [](const std::string& v, bool& out) {
                if (v == "1" || v == "true" || v == "on")
                    out = true;
                else if (v == "0" || v == "false" || v == "off")
                    out = false;
                else
                    throw std::invalid_argument("boolean");
            };
            const auto asNum = [](const std::string& v, double& out) {
                size_t pos = 0;
                double d   = 0;
                try {
                    d = std::stod(v, &pos);
                } catch (...) { throw std::invalid_argument("number"); }
                if (pos != v.size())
                    throw std::invalid_argument("number");
                out = d;
            };

            try {
                bool   b = false;
                double n = 0;
                if (key == "enabled") { asBool(val, b); pr.enabled = b; }
                else if (key == "step") { asNum(val, n); pr.step = n; }
                else if (key == "duration") { asNum(val, n); pr.durationMs = n; }
                else if (key == "drag_ratio") { asNum(val, n); pr.dragRatio = n; }
                else if (key == "drag_scroll") { asBool(val, b); pr.dragScroll = b; }
                else if (key == "curve") {
                    if (val == "expo")
                        pr.curve = SConfig::ECurve::EXPO;
                    else if (val == "linear")
                        pr.curve = SConfig::ECurve::LINEAR;
                    else if (val == "smooth")
                        pr.curve = SConfig::ECurve::SMOOTH;
                    else
                        throw std::invalid_argument("curve");
                } else
                    bad("unknown key \"" + key + "\"");
            } catch (const std::exception& e) {
                bad(key + ": " + e.what());
            }
        }

        g_profiles          = std::move(profiles);
        g_profileCache.valid = false; // the globs just changed
        return errors;
    }

    // The window under the cursor, or nullptr. Every click of a scroll lands on
    // the same window, so callers cache the verdict per class.
    auto windowUnderCursor() {
        return Desktop::viewState()->hitTest().windowAt(g_pInputManager->getMouseCoordsInternal(),
                                                         Desktop::View::RESERVED_EXTENTS | Desktop::View::INPUT_EXTENTS | Desktop::View::ALLOW_FLOATING);
    }

    // First matching profile wins, and its result is cached against the window
    // class so the globs only run when the cursor moves to a different app.
    const SProfile* activeProfile() {
        if (g_profiles.empty())
            return nullptr;
        const auto PWINDOW = windowUnderCursor();
        if (!PWINDOW)
            return nullptr;
        const auto cls     = std::string_view(PWINDOW->m_class).substr(0, MAX_CLASS_CHARS);
        const auto initial = std::string_view(PWINDOW->m_initialClass).substr(0, MAX_CLASS_CHARS);
        if (g_profileCache.valid && g_profileCache.cls == cls && g_profileCache.initialClass == initial)
            return g_profileCache.hit;
        const SProfile* hit = nullptr;
        for (const auto& pr : g_profiles) {
            if (globMatch(pr.glob, cls) || globMatch(pr.glob, initial)) {
                hit = &pr;
                break;
            }
        }
        g_profileCache = {std::string(cls), std::string(initial), hit, true};
        return hit;
    }

    // Each getter re-resolves the window, but activeProfile() caches the verdict
    // against the class, so this is a couple of string compares on a hot path.
    double      effStep()     { const auto* pr = activeProfile(); return pr && pr->step ? *pr->step : g_config.step; }
    double      effDuration() { const auto* pr = activeProfile(); return pr && pr->durationMs ? *pr->durationMs : g_config.durationMs; }
    double      effDragRatio(){ const auto* pr = activeProfile(); return pr && pr->dragRatio ? *pr->dragRatio : g_config.dragRatio; }
    SConfig::ECurve effCurve(){ const auto* pr = activeProfile(); return pr && pr->curve ? *pr->curve : g_config.curve; }

    bool shouldPassThrough() {
        // A profile can switch scrolling off for one app without touching the
        // global setting, so this is the first thing asked.
        if (const auto* pr = activeProfile(); pr && pr->enabled && !*pr->enabled)
            return true;
        if (!g_config.enabled)
            return true;

        // modifier + wheel is used by binds (e.g. switching workspaces); keep it discrete
        if (g_pInputManager->getModsFromAllKBs() != 0)
            return true;

        return isExcludedWindow();
    }

    void onAxis(IPointer::SAxisEvent e, Event::SCallbackInfo& info) {
        // only intercept real wheels; our own replayed events (finger, plus the continuous marker) fall through
        if (e.source != WL_POINTER_AXIS_SOURCE_WHEEL || e.delta == 0 || shouldPassThrough())
            return;

        info.cancelled = true;

        const size_t idx = e.axis == WL_POINTER_AXIS_VERTICAL_SCROLL ? 0 : 1;
        auto&        ax  = g_axes[idx];
        const double add = e.delta * effStep();

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
        ax.total     = std::max(ax.total, std::abs(ax.remaining));
        ax.mouse    = e.mouse;
        ax.relative = e.relativeDirection;
        ax.tau       = 0; // a wheel glide decays over `duration`, not over the drag tau
        ax.durationMs = effDuration();

        if (!ax.active) {
            ax.active = true;
            if (!g_timer->armed()) {
                g_lastTick = Clock::now() - TICK; // move on the first tick right away
                g_timer->updateTimeout(std::chrono::microseconds(0));
            }
        }
    }

    // Hand the release speed to an exponential coast, the way a flick keeps
    // travelling on a touchscreen: the speed at release decays with a time
    // constant of its own, so the flick covers speed * tau and comes to rest
    // over a few tau, instead of borrowing the wheel's much shorter `duration`.
    void startFling(Vector2D vel) {
        if (!g_config.dragFling)
            return;

        // a gesture parked before lifting coasts nothing, like a finger that
        // came to rest before it left the glass
        if (std::chrono::duration<double, std::milli>(Clock::now() - g_drag.lastMove).count() > FLING_FRESH_MS)
            return;

        const double lo = g_config.dragFlingMinSpeed;
        const double hi = std::max(lo, g_config.dragFlingMaxSpeed);
        const auto   clampSpeed = [&](double v) {
            if (std::abs(v) < lo)
                return 0.0; // too slow to be a flick
            return std::clamp(v, -hi, hi);
        };

        // The glide has to carry on from the drag, so it needs the same signed
        // ratio the drag path applies at every motion step. Without it a mobile
        // drag (negative ratio) flung backwards, because the drag applied the
        // sign and this did not.
        const double vx = clampSpeed(vel.x) * g_config.dragFlingFactor * g_drag.ratio;
        const double vy = clampSpeed(vel.y) * g_config.dragFlingFactor * g_drag.ratio;
        if (vx == 0.0 && vy == 0.0)
            return;

        // the glide belongs to the surface the drag ended on
        g_glideOrigin  = g_pInputManager->getMouseCoordsInternal();
        g_glideSurface = g_pSeatManager->m_state.pointerFocus;

        const double tau = std::max(1.0, g_config.dragFlingTau);
        const auto   arm = [&](size_t idx, double v) {
            auto& ax = g_axes[idx];
            if (v == 0)
                return;
            ax.remaining = std::clamp(ax.remaining + v * tau, -MAX_REMAINING, MAX_REMAINING);
            ax.mouse     = true;
            ax.tau       = tau;
            if (!ax.active) {
                ax.active = true;
                if (!g_timer->armed()) {
                    g_lastTick = Clock::now() - TICK; // move on the first tick right away
                    g_timer->updateTimeout(std::chrono::microseconds(0));
                }
            }
        };
        arm(0, vy);
        arm(1, vx);
    }

    void endDrag() {
        g_drag = {};
    }

    void onButton(IPointer::SButtonEvent e, Event::SCallbackInfo& info) {
        // A stuck gesture must never be able to eat clicks, so any button that
        // is not the drag button clears it before doing anything else.
        if (e.state == WL_POINTER_BUTTON_STATE_PRESSED && g_drag.armed && e.button != g_drag.button)
            endDrag();

        // A profile may switch drag off for one app (a game, a video player)
        // without disturbing the global setting.
        const bool dragAllowed = [] {
            const auto* pr = activeProfile();
            return pr && pr->dragScroll ? *pr->dragScroll : g_config.dragScroll;
        }();
        if (!g_config.enabled || !dragAllowed)
            return;

        if (e.state == WL_POINTER_BUTTON_STATE_PRESSED) {
            // a real mouse button only, never a second one, and not on a window
            // the exclude list claims
            if (!e.mouse || e.button != g_config.dragButton || g_drag.armed || g_drag.active)
                return;
            // modifiers are binds, not a drag
            if (g_pInputManager->getModsFromAllKBs() != 0 || isExcludedWindow())
                return;

            const auto pos = g_pInputManager->getMouseCoordsInternal();
            const auto now = Clock::now();
            g_drag       = {};
            g_drag.armed    = true;
            g_drag.button   = e.button;
            g_drag.pressPos = pos;
            g_drag.lastPos  = pos;
            g_drag.pressAt  = now;
            g_drag.lastMove = now;
            // Withhold the press so the app never sees a button-down it could
            // turn into a menu. It is replayed on release if this turns out to
            // be a plain click; see the release branch below.
            if (g_config.dragClickSuppress) {
                info.cancelled = true;
                g_drag.suppressed = true;
            }
            return;
        }

        if (!g_drag.armed || e.button != g_drag.button)
            return;

        if (g_drag.active) {
            startFling(g_drag.vel);
            // A real drag is not a click, so the app gets nothing. Because the
            // press was withheld there is no half-open button to unwind, but
            // releasing the compositor's own state is the cheap safety floor
            // that keeps Hyprland's button bookkeeping from drifting.
            if (g_drag.suppressed)
                g_pInputManager->releaseAllMouseButtons();
        } else if (g_drag.suppressed) {
            // It never crossed the threshold, so this was an ordinary click all
            // along. Replay press then release, since the app saw neither.
            const auto t = nowMs();
            g_pSeatManager->sendPointerButton(t, g_drag.button, WL_POINTER_BUTTON_STATE_PRESSED);
            g_pSeatManager->sendPointerButton(t, g_drag.button, WL_POINTER_BUTTON_STATE_RELEASED);
            g_pSeatManager->sendPointerFrame();
        }
        endDrag();
    }

    void onMove(Vector2D delta, Event::SCallbackInfo& info) {
        if (!g_drag.armed)
            return;

        const auto pos = g_pInputManager->getMouseCoordsInternal();

        if (!g_drag.active) {
            // A release we somehow never saw must not leave the gesture armed,
            // or it would go on cancelling motion and eat every later click.
            if (std::chrono::duration<double>(Clock::now() - g_drag.pressAt).count() > MAX_DRAG_SECONDS) {
                endDrag();
                return;
            }
            if (pos.distance(g_drag.pressPos) < g_config.dragThreshold)
                return; // still a click; leave the app alone
            // landing in an excluded window mid-drag ends the gesture
            if (isExcludedWindow()) {
                endDrag();
                return;
            }
            g_drag.active = true;
            g_drag.vel    = {};
            g_drag.velAt  = Clock::now();
            // Pinned for the gesture, so crossing into another window mid-drag
            // cannot change the ratio halfway through.
            g_drag.ratio = effDragRatio();

            // Claim the axis the gesture mostly moved along, so a slightly
            // diagonal drag does not smear itself across both axes and read as
            // a stutter. Measured once, at the moment the drag becomes real;
            // later drift cannot steal the gesture.
            if (g_config.axisLock) {
                const auto travelled = pos - g_drag.pressPos;
                g_drag.axis          = std::abs(travelled.y) >= std::abs(travelled.x) ? 0 : 1;
            }
            // A wheel glide still in flight would fight the drag for the same
            // axis. Settle it once here rather than on every motion event.
            for (size_t i = 0; i < g_axes.size(); ++i) {
                if (g_axes[i].active) {
                    g_axes[i].remaining = 0;
                    g_axes[i].total     = 0;
                    g_axes[i].active    = false;
                    g_axes[i].tau       = 0;
                    endGestureWithoutMomentum(i);
                }
            }
        }

        // Take the motion away from the app so it cannot start a text selection,
        // move a slider or drag a window. The cursor itself still moves, because
        // that position comes from the device and not from this event.
        info.cancelled = true;

        auto d        = pos - g_drag.lastPos;
        g_drag.lastPos = pos;
        if (d.x == 0 && d.y == 0)
            return;

        // With the gesture owned by one axis, the other component is dropped so
        // it cannot leak a little sideways drift into every event.
        if (g_drag.axis >= 0) {
            if (g_drag.axis == 0)
                d.x = 0;
            else
                d.y = 0;
            if (d.x == 0 && d.y == 0)
                return;
        }

        g_drag.lastMovePx = d;
        g_drag.lastMove    = Clock::now();

        // Release speed, smoothed over a short window the way a phone tracks
        // how fast the finger was moving just before it lifted. A single mouse
        // sample is too noisy to set a coast on its own.
        const auto   vnow = Clock::now();
        const double vdt  = std::chrono::duration<double, std::milli>(vnow - g_drag.velAt).count();
        if (vdt > 0.0) {
            // measure over a sane span: a long gap means the pointer was parked,
            // and one short sample means a very fast flick that would divide by
            // almost nothing
            const double w = std::clamp(vdt, 1.0, 100.0);
            const double a = 1.0 - std::exp(-vdt / FLING_WINDOW_MS);
            g_drag.vel.x = g_drag.vel.x + (d.x / w - g_drag.vel.x) * a;
            g_drag.vel.y = g_drag.vel.y + (d.y / w - g_drag.vel.y) * a;
        }
        g_drag.velAt = vnow;

        // Negative (the default) is touchscreen-like: the cursor drags the page
        // with it, so moving up scrolls forward. Positive flips to grab-and-pull,
        // where the page sticks to the cursor and trails behind it.
        const double ratio = g_drag.ratio;
        bool         any   = false;
        if (d.y != 0) {
            emitAxisRaw(0, d.y * ratio);
            any = true;
        }
        if (d.x != 0) {
            emitAxisRaw(1, d.x * ratio);
            any = true;
        }
        if (any)
            g_pSeatManager->sendPointerFrame();
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
        // Which profile the window under the cursor resolves to, and what it
        // changes. Without this there is no way to tell a typo in the glob from
        // a profile that simply is not matching.
        if (sub == "profile") {
            const auto* pr    = activeProfile();
            const auto  curve = [](SConfig::ECurve c) { return c == SConfig::ECurve::EXPO ? "expo" : c == SConfig::ECurve::LINEAR ? "linear" : "smooth"; };
            std::string out   = std::string{"matched: "} + (pr ? pr->glob : std::string{"<none, using globals>"}) + "\n";
            out += std::string{"loaded: "} + std::to_string(g_profiles.size()) + "\n";
            out += "effective: step=" + std::to_string(effStep()) + " duration=" + std::to_string(effDuration()) + " drag_ratio=" + std::to_string(effDragRatio()) + " curve=" + curve(effCurve()) + "\n";
            const auto PWINDOW = windowUnderCursor();
            out += "window: " + (PWINDOW ? std::string{PWINDOW->m_class} : std::string{"<none>"}) + "\n";
            return out;
        }

        // One named curve, spelled as it is in the config file.
        if (sub == "curve") {
            auto name = [](SConfig::ECurve c) { return c == SConfig::ECurve::EXPO ? "expo" : c == SConfig::ECurve::LINEAR ? "linear" : "smooth"; };
            std::string what;
            in >> what;
            if (what.empty())
                return std::string{"curve: "} + name(g_config.curve) + "\n";
            if (what == "expo" || what == "linear" || what == "smooth")
                g_config.curve = what == "expo" ? SConfig::ECurve::EXPO : what == "linear" ? SConfig::ECurve::LINEAR : SConfig::ECurve::SMOOTH;
            else if (what == "toggle")
                g_config.curve = g_config.curve == SConfig::ECurve::EXPO ? SConfig::ECurve::LINEAR : g_config.curve == SConfig::ECurve::LINEAR ? SConfig::ECurve::SMOOTH : SConfig::ECurve::EXPO;
            else
                return "usage: hyprctl hymos curve expo|linear|smooth|toggle\n";
            return std::string{"curve: "} + name(g_config.curve) + "\n";
        }

        if (sub == "axislock") {
            std::string what;
            in >> what;
            if (what.empty() || what == "toggle")
                g_config.axisLock = what.empty() ? !g_config.axisLock : !g_config.axisLock;
            else if (what == "on" || what == "off")
                g_config.axisLock = what == "on";
            else
                return "usage: hyprctl hymos axislock on|off|toggle\n";
            return std::string{"axis_lock: "} + (g_config.axisLock ? "on" : "off") + "\n";
        }

        if (sub == "clicksuppress") {
            std::string what;
            in >> what;
            if (what == "on" || what == "off" || what == "toggle") {
                g_config.dragClickSuppress = what == "on" || (what == "toggle" && !g_config.dragClickSuppress);
                return g_config.dragClickSuppress ? "clicksuppress on\n" : "clicksuppress off\n";
            }
            if (what.empty())
                return g_config.dragClickSuppress ? "on\n" : "off\n";
            return "usage: hyprctl hymos clicksuppress on|off|toggle\n";
        }
        if (sub == "drag") {
            std::string what;
            in >> what;
            if (what == "on" || what == "off" || what == "toggle") {
                g_config.dragScroll = what == "on" || (what == "toggle" && !g_config.dragScroll);
                g_drag              = {};
                return g_config.dragScroll ? "drag on\n" : "drag off\n";
            }
            if (what.empty())
                return g_config.dragScroll ? "on\n" : "off\n";
            return "usage: hyprctl hymos drag on|off|toggle\n";
        }

        return std::format("enabled: {}\nstep: {}\nduration: {}\ndrag_scroll: {}\ndrag_button: {}\ndrag_threshold: {}\ndrag_ratio: {}\ncurve: {}\naxis_lock: {}\ndrag_click_suppress: {}\ndrag_fling: {}\ndrag_fling_tau: {}\ndrag_fling_min_speed: {}\ndrag_fling_max_speed: {}\nexclude: {}\nconfig: {}\nprofiles: {}\n",
                           g_config.enabled, g_config.step, g_config.durationMs, g_config.dragScroll,
                           g_config.dragButton == BTN_LEFT ? "left" : g_config.dragButton == BTN_RIGHT ? "right" : "middle",
                           g_config.dragThreshold, g_config.dragRatio,
                           g_config.curve == SConfig::ECurve::EXPO ? "expo" : g_config.curve == SConfig::ECurve::LINEAR ? "linear" : "smooth",
                           g_config.axisLock, g_config.dragClickSuppress, g_config.dragFling,
                           g_config.dragFlingTau,
                           g_config.dragFlingMinSpeed, g_config.dragFlingMaxSpeed, g_config.exclude, configPath(),
                           std::to_string(g_profiles.size()) + " from " + profilesPath());
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

    g_axisListener    = Event::bus()->m_events.input.mouse.axis.listen([](IPointer::SAxisEvent e, Event::SCallbackInfo& info) { onAxis(e, info); });
    g_buttonListener  = Event::bus()->m_events.input.mouse.button.listen([](IPointer::SButtonEvent e, Event::SCallbackInfo& info) { onButton(e, info); });
    g_moveListener    = Event::bus()->m_events.input.mouse.move.listen([](Vector2D d, Event::SCallbackInfo& info) { onMove(d, info); });
    g_ctlCommand      = HyprlandAPI::registerHyprCtlCommand(PHANDLE, SHyprCtlCommand{.name = "hymos", .exact = false, .fn = ctl});

    return {"hymos", "Mos-style smooth scrolling for mouse wheels, plus phone-like grab-and-drag", "diogocezar", "1.3.1"};
}

APICALL EXPORT void PLUGIN_EXIT() {
    g_axisListener.reset();
    g_moveListener.reset();
    g_buttonListener.reset();
    g_drag = {};
    if (g_ctlCommand)
        HyprlandAPI::unregisterHyprCtlCommand(PHANDLE, g_ctlCommand);
    if (g_timer) {
        g_timer->cancel();
        g_pEventLoopManager->removeTimer(g_timer);
        g_timer.reset();
    }
}
