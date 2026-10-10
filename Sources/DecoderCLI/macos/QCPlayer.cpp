// Copyright (c) 2026 B00kerLouis. SPDX-License-Identifier: LGPL-2.1-or-later
#include "QCPlayer.hpp"
#include "QCEngine.hpp"
#include <CoreGraphics/CoreGraphics.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdio>
#include <filesystem>
#include <iostream>
#include <stdexcept>

extern "C" {
extern id NSFontAttributeName, NSForegroundColorAttributeName;
extern id NSRunLoopCommonModes, NSAppearanceNameDarkAqua;
}
namespace {
volatile std::sig_atomic_t interrupted = 0;
void cancelSignal(int) { interrupted = 1; }
// C++ owns the application. Only this translation unit crosses AppKit's
// Objective-C runtime boundary; widths follow the macOS SDK ABI on both CPUs.
template<class R = id, class... A> R msg(id object, const char *selector, A... args) {
    return reinterpret_cast<R (*)(id, SEL, A...)>(objc_msgSend)(object, sel_registerName(selector), args...);
}
id cls(const char *name) { return reinterpret_cast<id>(objc_getClass(name)); }
id str(const std::string &value) { return msg(cls("NSString"), "stringWithUTF8String:", value.c_str()); }
std::string utf8(id value) {
    const char *p = value ? msg<const char *>(value, "UTF8String") : nullptr;
    return p ? p : "";
}
struct Pool {
    id value = msg(cls("NSAutoreleasePool"), "new");
    ~Pool() { msg<void>(value, "drain"); }
};
id ink(double r, double g, double b) {
    struct Cached { double r = 0, g = 0, b = 0; id value = nullptr; };
    static std::array<Cached, 12> colors{};
    for (auto &c : colors) {
        if (c.value && c.r == r && c.g == g && c.b == b) return c.value;
        if (!c.value) {
            c = {r, g, b, msg(cls("NSColor"), "colorWithCalibratedRed:green:blue:alpha:", CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(1))};
            msg<void>(c.value, "retain"); return c.value;
        }
    }
    throw std::runtime_error("QC color cache capacity exceeded");
}
id font(double size, bool mono = false) {
    return mono ? msg(cls("NSFont"), "monospacedDigitSystemFontOfSize:weight:", CGFloat(size), CGFloat(0)) :
                  msg(cls("NSFont"), "systemFontOfSize:", CGFloat(size));
}
id icon(const char *name, double size) {
    auto image = msg(cls("NSImage"), "imageWithSystemSymbolName:accessibilityDescription:", str(name), str(name));
    auto config = msg(cls("NSImageSymbolConfiguration"), "configurationWithPointSize:weight:", CGFloat(size), CGFloat(0));
    return msg(image, "imageWithSymbolConfiguration:", config);
}
void drawText(const std::string &value, double x, double y, double size, id color, bool mono = false) {
    // Fixed main-thread style cache: fonts/attribute dictionaries are reused
    // across 30 Hz meter paints rather than rebuilt for every channel label.
    struct Style { double size = 0; bool mono = false; id color = nullptr, attributes = nullptr; };
    static std::array<Style, 12> styles{};
    id attributes = nullptr;
    for (auto &style : styles) {
        if (style.attributes && style.size == size && style.mono == mono && style.color == color) { attributes = style.attributes; break; }
        if (!style.attributes) {
            attributes = msg(cls("NSMutableDictionary"), "new");
            msg<void>(attributes, "setObject:forKey:", font(size, mono), NSFontAttributeName);
            msg<void>(attributes, "setObject:forKey:", color, NSForegroundColorAttributeName);
            style = {size, mono, color, attributes}; break;
        }
    }
    if (!attributes) throw std::runtime_error("QC text style cache capacity exceeded");
    msg<void>(str(value), "drawAtPoint:withAttributes:", CGPointMake(x, y), attributes);
}
std::string timecode(uint64_t samples) {
    auto seconds = samples / 48000;
    char buffer[40];
    std::snprintf(buffer, sizeof(buffer), "%02llu:%02llu:%02llu", (unsigned long long)(seconds / 3600),
                  (unsigned long long)(seconds / 60 % 60), (unsigned long long)(seconds % 60));
    return buffer;
}
const char *layouts[] = {"2.0", "5.1", "7.1", "5.1.2", "5.1.4", "7.1.2", "7.1.4", "7.1.6", "9.1.6"};
const char *label(STHDSpeaker speaker) {
    const char *names[] = {"L", "R", "C", "LFE", "Lrs", "Rrs", "Ls", "Rs", "Ltf", "Rtf", "Ltr", "Rtr", "Ltm", "Rtm", "Lw", "Rw"};
    return unsigned(speaker) < 16 ? names[unsigned(speaker)] : "?";
}
struct App {
    sthd_qc::Engine engine;
    id application = nullptr, window = nullptr, canvas = nullptr, controller = nullptr, timer = nullptr;
    id title = nullptr, transport = nullptr, elapsed = nullptr, total = nullptr, seek = nullptr;
    id volume = nullptr, status = nullptr, layout = nullptr, monitor = nullptr, exportButton = nullptr;
    id exportLayout = nullptr, exportFormat = nullptr, levelMode = nullptr;
    sthd_qc::Snapshot current;
    std::array<float, 16> peakDB{}, holdDB{};
    std::array<std::chrono::steady_clock::time_point, 16> holdUntil{};
    std::array<CGRect, 16> meterRects{};
    std::atomic<bool> exporting{false}, cancelExport{false};
    std::atomic<uint64_t> exported{0};
    std::thread exportWorker;
    std::mutex exportMutex;
    std::string exportMessage;
    std::string initialPath, initialLayout = "7.1.4";
    bool autoplay = true, scrubActive = false;
    std::string shownPath, shownElapsed, shownTotal, shownStatus, shownDevice;
    bool shownLoaded = true, shownPlaying = true, shownExporting = true;
    App() { peakDB.fill(-60); holdDB.fill(-60); }
    ~App() {
        cancelExport = true;
        if (exportWorker.joinable()) exportWorker.join();
        engine.shutdown();
    }
};
App *owner(id object) {
    void *p = nullptr; object_getInstanceVariable(object, "_qcContext", &p); return static_cast<App *>(p);
}
void bind(id object, App *app) { object_setInstanceVariable(object, "_qcContext", app); }
void error(App *app, const std::string &message) {
    auto alert = msg(cls("NSAlert"), "new");
    msg<void>(alert, "setMessageText:", str("truehdec QC"));
    msg<void>(alert, "setInformativeText:", str(message));
    msg<long>(alert, "runModal"); msg<void>(alert, "release");
    (void)app;
}
template<class F> void action(id object, F function) {
    auto app = owner(object);
    try { function(*app); } catch (const std::exception &e) { error(app, e.what()); }
}
BOOL flipped(id, SEL) { return YES; }
void paint(id object, SEL, CGRect) {
    Pool pool;
    auto &app = *owner(object); const auto &s = app.current;
    auto context = msg<CGContextRef>(msg(cls("NSGraphicsContext"), "currentContext"), "CGContext");
    if (!context) return;
    CGContextSetRGBFillColor(context, .13, .135, .145, 1);
    CGContextFillRect(context, CGRectMake(0, 0, 900, 600));
    auto grey = ink(.60, .62, .65), white = ink(.91, .92, .94);
    drawText("QC LAYOUT", 26, 181, 10, grey);
    drawText("MONITORING", 326, 181, 10, grey);
    drawText("MONITOR VOLUME", 665, 181, 10, grey);
    drawText("Peak / RMS · click a channel to Solo", 60, 251, 12, grey);
    drawText("dBFS", 16, 278, 10, grey);
    for (int dB : {0, -6, -12, -24, -36, -48, -60}) {
        double y = 304 + (-dB) * 2.4;
        CGContextSetRGBFillColor(context, .23, .24, .26, 1);
        CGContextFillRect(context, CGRectMake(56, y, 818, .5));
        drawText(std::to_string(dB), 24, y - 7, 10, grey, true);
    }
    unsigned count = s.layout.channels;
    double step = count ? 816.0 / count : 0;
    for (unsigned c = 0; c < count; ++c) {
        double x = 58 + step * c, barWidth = std::min(34.0, step - 16), middle = x + step / 2;
        auto rectangle = CGRectMake(x, 280, step, 214); app.meterRects[c] = rectangle;
        if (s.solo == int(c)) {
            CGContextSetRGBFillColor(context, .12, .23, .37, 1); CGContextFillRect(context, rectangle);
        }
        if (!s.coordinatesAvailable) {
            drawText(label(s.layout.speakers[c]), middle - 13, 462, 11, white, true);
            drawText("--", middle - 12, 483, 10, grey, true);
            continue;
        }
        double p = std::clamp(double(app.peakDB[c]), -60.0, 0.0);
        double r = s.rms[c] > 0 ? std::clamp(20.0 * std::log10(s.rms[c]), -60.0, 0.0) : -60;
        CGContextSetRGBFillColor(context, .13, .35, .24, 1);
        CGContextFillRect(context, CGRectMake(middle - barWidth / 2, 304 - p * 2.4, barWidth, (60 + p) * 2.4));
        CGContextSetRGBFillColor(context, p >= 0 ? .98 : .23, p >= 0 ? .26 : .79, .38, 1);
        CGContextFillRect(context, CGRectMake(middle - barWidth / 2, 304 - r * 2.4, barWidth, (60 + r) * 2.4));
        CGContextSetRGBFillColor(context, .94, .82, .35, 1);
        CGContextFillRect(context, CGRectMake(middle - barWidth / 2, 304 - std::clamp(double(app.holdDB[c]), -60.0, 0.0) * 2.4, barWidth, 2));
        drawText(label(s.layout.speakers[c]), middle - 13, 462, 11, white, true);
        char peak[16]; std::snprintf(peak, sizeof(peak), "%.1f", app.peakDB[c]);
        drawText(peak, middle - 16, 483, 10, grey, true);
    }
    drawText("PCM EXPORT", 26, 533, 10, grey);
    drawText(s.loaded ? (s.immersive ? "Dolby TrueHD · Atmos" : "Dolby TrueHD · 7.1") : "Dolby TrueHD",
             28, 148, 11, grey);
    drawText("48 kHz / 24 bit · DRC disabled", 646, 148, 11, grey);
}
void meterClick(id object, SEL, id event) {
    auto app = owner(object);
    auto point = msg<CGPoint>(event, "locationInWindow");
    point = msg<CGPoint>(object, "convertPoint:fromView:", point, id(nullptr));
    for (unsigned c = 0; c < app->current.layout.channels; ++c)
        if (CGRectContainsPoint(app->meterRects[c], point)) { app->engine.solo(int(c)); break; }
}
void openFile(id object, SEL, id) {
    action(object, [](App &app) {
        auto panel = msg(cls("NSOpenPanel"), "openPanel");
        msg<void>(panel, "setCanChooseDirectories:", BOOL(0));
        msg<void>(panel, "setAllowsMultipleSelection:", BOOL(0));
        msg<void>(panel, "setTitle:", str("Open TrueHD elementary stream"));
        if (msg<long>(panel, "runModal") == 1) {
            auto path = utf8(msg(msg(panel, "URL"), "path")); app.engine.load(path);
        }
    });
}
BOOL openDocument(id object, SEL, id, id filename) {
    action(object, [&](App &app) { app.engine.load(utf8(filename)); }); return YES;
}
void toggle(id object, SEL, id) { action(object, [](App &a) { a.engine.toggle(); }); }
void stop(id object, SEL, id) { action(object, [](App &a) { a.engine.stop(); }); }
void back(id object, SEL, id) { action(object, [](App &a) { a.engine.skip(-10); }); }
void forward(id object, SEL, id) { action(object, [](App &a) { a.engine.skip(10); }); }
void seek(id object, SEL, id sender) {
    action(object, [&](App &a) {
        auto position = uint64_t(msg<double>(sender, "doubleValue") * double(a.current.total));
        if (a.scrubActive) a.engine.previewScrub(position); else a.engine.seek(position);
    });
}
void scrubMouseDown(id object, SEL selector, id event) {
    auto app = owner(object); app->scrubActive = true; app->engine.beginScrub();
    objc_super parent{object, class_getSuperclass(object_getClass(object))};
    reinterpret_cast<void (*)(objc_super *, SEL, id)>(objc_msgSendSuper)(&parent, selector, event);
    app->scrubActive = false;
    app->engine.endScrub(uint64_t(msg<double>(object, "doubleValue") * double(app->current.total)));
}
Class seekSliderClass() {
    if (auto c = objc_getClass("B00kerTrueHDQCSeekSlider")) return c;
    auto c = objc_allocateClassPair(objc_getClass("NSSlider"), "B00kerTrueHDQCSeekSlider", 0);
    if (!c || !class_addIvar(c, "_qcContext", sizeof(void *), 3, "^v") ||
        !class_addMethod(c, sel_registerName("mouseDown:"), reinterpret_cast<IMP>(scrubMouseDown), "v@:@"))
        throw std::runtime_error("QC seek slider creation failed");
    objc_registerClassPair(c); return c;
}
void levelMode(id object, SEL, id sender) {
    action(object, [&](App &a) {
        a.engine.levels(msg<long>(sender, "indexOfSelectedItem") == 0 ? sthd_qc::LevelMode::playback : sthd_qc::LevelMode::encoded);
        a.peakDB.fill(-60); a.holdDB.fill(-60);
    });
}
void volume(id object, SEL, id sender) {
    action(object, [&](App &a) { a.engine.volume(float(msg<double>(sender, "doubleValue"))); });
}
void layout(id object, SEL, id sender) {
    action(object, [&](App &a) { a.engine.layout(utf8(msg(sender, "titleOfSelectedItem"))); a.peakDB.fill(-60); a.holdDB.fill(-60); });
}
void monitor(id object, SEL, id sender) {
    action(object, [&](App &a) { a.engine.monitor(sthd_qc::Monitor(msg<long>(sender, "indexOfSelectedItem"))); });
}
void exportPCM(id object, SEL, id) {
    action(object, [](App &app) {
        if (app.exporting) { app.cancelExport = true; return; }
        auto snapshot = app.engine.snapshot(); if (!snapshot.loaded) return;
        if (app.exportWorker.joinable()) app.exportWorker.join();
        const long selection = msg<long>(app.exportFormat, "indexOfSelectedItem");
        const bool elements = msg<long>(app.exportLayout, "indexOfSelectedItem") == 0;
        auto panel = msg(cls("NSSavePanel"), "savePanel");
        msg<void>(panel, "setTitle:", str("Export PCM (existing files are preserved)"));
        auto stem = std::filesystem::u8path(snapshot.path).stem().u8string();
        msg<void>(panel, "setNameFieldStringValue:", str(stem + (selection == 0 ? ".wav" : ".pcm")));
        if (msg<long>(panel, "runModal") != 1) return;
        auto output = utf8(msg(msg(panel, "URL"), "path"));
        auto source = snapshot.path, name = elements ? "elements" : snapshot.layoutName;
        app.cancelExport = false; app.exported = 0; app.exporting = true;
        { std::lock_guard<std::mutex> lock(app.exportMutex); app.exportMessage.clear(); }
        auto levelMode = snapshot.levelMode;
        app.exportWorker = std::thread([&app, source, output, name, selection, levelMode] {
            std::string message;
            try {
                auto result = sthd_qc::exportPCM(source, output, name, sthd_qc::Format(selection), app.cancelExport,
                                               [&](uint64_t n) { app.exported = n; }, levelMode);
                message = "Export complete · clips " + std::to_string(result.clips) +
                          " · over-range " + std::to_string(result.overRange) +
                          " · PCM checks " + std::to_string(result.checksumMismatches);
            } catch (const std::exception &e) { message = e.what(); }
            { std::lock_guard<std::mutex> lock(app.exportMutex); app.exportMessage = message; }
            app.exporting = false;
        });
    });
}
void tick(id object, SEL, id) {
    Pool pool;
    if (interrupted) {
        msg<void>(owner(object)->window, "performClose:", id(nullptr));
        return;
    }
    action(object, [](App &a) {
        a.current = a.engine.snapshot(); auto &s = a.current;
        auto filename = s.path.empty() ? "truehdec QC" : std::filesystem::u8path(s.path).filename().u8string();
        if (filename != a.shownPath) {
            a.shownPath = filename; msg<void>(a.title, "setStringValue:", str(filename));
            msg<void>(a.window, "setTitle:", str(filename));
        }
        auto elapsed = timecode(s.position), total = s.loaded ? timecode(s.total) : "--:--:--";
        if (elapsed != a.shownElapsed) { a.shownElapsed = elapsed; msg<void>(a.elapsed, "setStringValue:", str(elapsed)); }
        if (total != a.shownTotal) { a.shownTotal = total; msg<void>(a.total, "setStringValue:", str(total)); }
        bool playing = s.playing && !s.seeking;
        if (playing != a.shownPlaying) { a.shownPlaying = playing; msg<void>(a.transport, "setImage:", icon(playing ? "pause.fill" : "play.fill", 34)); }
        if (s.loaded != a.shownLoaded) {
            a.shownLoaded = s.loaded; msg<void>(a.transport, "setEnabled:", BOOL(s.loaded)); msg<void>(a.seek, "setEnabled:", BOOL(s.loaded));
        }
        if (!a.scrubActive && !msg<BOOL>(msg(a.seek, "cell"), "isHighlighted"))
            msg<void>(a.seek, "setDoubleValue:", s.total ? double(s.position) / double(s.total) : 0.0);
        std::string detail = s.status + " · QC clips " + std::to_string(s.clips) +
            " · monitor clips " + std::to_string(s.monitorClips) + " · PCM checks " + std::to_string(s.checksumMismatches);
        detail += " · DN " + std::to_string(int(s.presentationGainDB)) + " dB";
        if (s.unavailableSamples) detail += " · unpositioned " + std::to_string(s.unavailableSamples);
        if (s.solo >= 0) detail += " · Solo " + std::string(label(s.layout.speakers[unsigned(s.solo)]));
        if (a.exporting) detail += " · Export " + std::to_string(s.total ? std::min<uint64_t>(100, a.exported * 100 / s.total) : 0) + "%";
        else { std::lock_guard<std::mutex> lock(a.exportMutex); if (!a.exportMessage.empty()) detail += " · " + a.exportMessage; }
        if (detail != a.shownStatus) { a.shownStatus = detail; msg<void>(a.status, "setStringValue:", str(detail)); msg<void>(a.status, "setToolTip:", str(detail)); }
        if (bool(a.exporting) != a.shownExporting) { a.shownExporting = a.exporting; msg<void>(a.exportButton, "setTitle:", str(a.exporting ? "Cancel Export" : "Export PCM…")); }
        msg<void>(a.exportButton, "setEnabled:", BOOL(s.loaded || a.exporting));
        if (s.device != a.shownDevice) { a.shownDevice = s.device; msg<void>(a.monitor, "setToolTip:", str(s.device)); }
        auto now = std::chrono::steady_clock::now();
        for (unsigned c = 0; c < s.layout.channels; ++c) {
            float dB = s.peak[c] > 0 ? 20 * std::log10(s.peak[c]) : -60;
            a.peakDB[c] = std::max(dB, a.peakDB[c] - .9f);
            if (dB >= a.holdDB[c]) { a.holdDB[c] = dB; a.holdUntil[c] = now + std::chrono::seconds(1); }
            else if (now > a.holdUntil[c]) a.holdDB[c] = std::max(dB, a.holdDB[c] - .35f);
        }
        msg<void>(a.canvas, "setNeedsDisplay:", BOOL(1));
    });
}
BOOL closeWindow(id object, SEL, id) {
    auto a = owner(object); a->cancelExport = true;
    msg<void>(a->application, "stop:", id(nullptr)); return YES;
}
void quit(id object, SEL, id) { msg<void>(owner(object)->window, "performClose:", id(nullptr)); }
Class subclass(const char *name, const char *parent, bool view) {
    if (auto existing = objc_getClass(name)) return existing;
    auto result = objc_allocateClassPair(objc_getClass(parent), name, 0);
    if (!result || !class_addIvar(result, "_qcContext", sizeof(void *), 3, "^v"))
        throw std::runtime_error("AppKit class creation failed");
    auto add = [&](const char *name, auto function, const char *encoding) {
        if (!class_addMethod(result, sel_registerName(name), reinterpret_cast<IMP>(function), encoding))
            throw std::runtime_error("AppKit callback registration failed");
    };
    if (view) {
        add("isFlipped", flipped, "B@:"); add("drawRect:", paint, "v@:{CGRect={CGPoint=dd}{CGSize=dd}}");
        add("mouseDown:", meterClick, "v@:@");
    } else {
        add("open:", openFile, "v@:@"); add("toggle:", toggle, "v@:@"); add("stop:", stop, "v@:@");
        add("back:", back, "v@:@"); add("forward:", forward, "v@:@"); add("seek:", seek, "v@:@");
        add("levels:", levelMode, "v@:@"); add("volume:", volume, "v@:@"); add("layout:", layout, "v@:@"); add("monitor:", monitor, "v@:@");
        add("export:", exportPCM, "v@:@"); add("tick:", tick, "v@:@"); add("quit:", quit, "v@:@");
        add("windowShouldClose:", closeWindow, "B@:@"); add("application:openFile:", openDocument, "B@:@@");
    }
    objc_registerClassPair(result); return result;
}
id control(App &app, const char *type, CGRect rectangle) {
    auto result = msg(msg(cls(type), "alloc"), "initWithFrame:", rectangle);
    msg<void>(app.canvas, "addSubview:", result); msg<void>(result, "release"); return result;
}
id textField(App &app, const std::string &text, CGRect rectangle, double size = 12) {
    auto result = control(app, "NSTextField", rectangle);
    msg<void>(result, "setEditable:", BOOL(0)); msg<void>(result, "setSelectable:", BOOL(0));
    msg<void>(result, "setBezeled:", BOOL(0)); msg<void>(result, "setDrawsBackground:", BOOL(0));
    msg<void>(result, "setFont:", font(size)); msg<void>(result, "setTextColor:", ink(.84, .85, .88));
    msg<void>(result, "setStringValue:", str(text)); return result;
}
void target(App &app, id control, const char *selector) {
    msg<void>(control, "setTarget:", app.controller);
    msg<void>(control, "setAction:", sel_registerName(selector));
}
id button(App &app, const char *title, const char *selector, CGRect rectangle, const char *image = nullptr, double size = 20) {
    auto result = control(app, "NSButton", rectangle);
    msg<void>(result, "setTitle:", str(title)); msg<void>(result, "setBezelStyle:", uintptr_t(1));
    if (image) { msg<void>(result, "setImage:", icon(image, size)); msg<void>(result, "setBordered:", BOOL(0)); }
    msg<void>(result, "setAccessibilityLabel:", str(title)); target(app, result, selector); return result;
}
id popup(App &app, CGRect rectangle, const std::vector<std::string> &items, const char *selector) {
    auto result = control(app, "NSPopUpButton", rectangle);
    for (auto &item : items) msg<void>(result, "addItemWithTitle:", str(item));
    if (selector) target(app, result, selector); return result;
}
id slider(App &app, CGRect rectangle, const char *selector, double value) {
    id result;
    if (std::string(selector) == "seek:") {
        result = msg(msg(reinterpret_cast<id>(seekSliderClass()), "alloc"), "initWithFrame:", rectangle);
        bind(result, &app); msg<void>(app.canvas, "addSubview:", result); msg<void>(result, "release");
        msg<void>(result, "setContinuous:", BOOL(1));
    } else result = control(app, "NSSlider", rectangle);
    msg<void>(result, "setMinValue:", 0.0); msg<void>(result, "setMaxValue:", 1.0);
    msg<void>(result, "setDoubleValue:", value); target(app, result, selector); return result;
}
void build(App &a) {
    a.application = msg(cls("NSApplication"), "sharedApplication");
    msg<BOOL>(a.application, "setActivationPolicy:", long(0));
    a.controller = msg(reinterpret_cast<id>(subclass("B00kerTrueHDQCController", "NSObject", false)), "new");
    bind(a.controller, &a); msg<void>(a.application, "setDelegate:", a.controller);
    a.window = msg(msg(cls("NSWindow"), "alloc"), "initWithContentRect:styleMask:backing:defer:",
                   CGRectMake(0, 0, 900, 600), uintptr_t(1 | 2 | 4 | 32768), uintptr_t(2), BOOL(0));
    msg<void>(a.window, "setReleasedWhenClosed:", BOOL(0)); msg<void>(a.window, "setTitlebarAppearsTransparent:", BOOL(1));
    msg<void>(a.window, "setTitleVisibility:", long(1)); msg<void>(a.window, "setDelegate:", a.controller);
    msg<void>(a.window, "setAppearance:", msg(cls("NSAppearance"), "appearanceNamed:", NSAppearanceNameDarkAqua));
    a.canvas = msg(msg(reinterpret_cast<id>(subclass("B00kerTrueHDQCView", "NSView", true)), "alloc"), "initWithFrame:", CGRectMake(0, 0, 900, 600));
    bind(a.canvas, &a); msg<void>(a.window, "setContentView:", a.canvas); msg<void>(a.canvas, "release");
    a.title = textField(a, "truehdec QC", CGRectMake(180, 16, 540, 30), 20);
    msg<void>(a.title, "setAlignment:", long(1));
    button(a, "Open…", "open:", CGRectMake(26, 50, 96, 30));
    button(a, "Skip back 10 seconds", "back:", CGRectMake(354, 55, 46, 46), "gobackward.10");
    a.transport = button(a, "Play / Pause", "toggle:", CGRectMake(412, 48, 76, 62), "play.fill", 34);
    button(a, "Skip forward 10 seconds", "forward:", CGRectMake(504, 55, 46, 46), "goforward.10");
    button(a, "Stop", "stop:", CGRectMake(776, 53, 90, 30));
    a.elapsed = textField(a, "00:00:00", CGRectMake(26, 116, 88, 22));
    a.total = textField(a, "--:--:--", CGRectMake(788, 116, 88, 22));
    a.seek = slider(a, CGRectMake(120, 114, 660, 24), "seek:", 0);
    a.levelMode = popup(a, CGRectMake(292, 140, 328, 27), {"Playback Levels (Dialnorm)", "Encoded PCM (Unity Gain)"}, "levels:");
    a.layout = popup(a, CGRectMake(24, 199, 268, 28), std::vector<std::string>(layouts, layouts + 9), "layout:");
    msg<void>(a.layout, "selectItemWithTitle:", str(a.initialLayout));
    a.monitor = popup(a, CGRectMake(324, 199, 310, 28), {"Direct Channels (No Downmix)", "Downmix to Device", "QC Meters Only"}, "monitor:");
    a.volume = slider(a, CGRectMake(664, 199, 208, 28), "volume:", .5);
    a.status = textField(a, "Open TrueHD audio", CGRectMake(26, 510, 848, 22), 11);
    a.exportLayout = popup(a, CGRectMake(136, 549, 234, 28), {"Native PCM / Atmos Elements", "Current QC Layout"}, nullptr);
    a.exportFormat = popup(a, CGRectMake(380, 549, 252, 28), {"WAV / RF64 · 24 bit", "Raw S24LE", "Raw S32LE · 24 bit left aligned", "Raw Float32LE"}, nullptr);
    a.exportButton = button(a, "Export PCM…", "export:", CGRectMake(656, 548, 218, 30));
    auto menu = msg(cls("NSMenu"), "new"), item = msg(cls("NSMenuItem"), "new"), submenu = msg(cls("NSMenu"), "new");
    msg<void>(menu, "addItem:", item); msg<void>(item, "setSubmenu:", submenu);
    auto open = msg(msg(cls("NSMenuItem"), "alloc"), "initWithTitle:action:keyEquivalent:", str("Open…"), sel_registerName("open:"), str("o"));
    msg<void>(open, "setTarget:", a.controller); msg<void>(submenu, "addItem:", open);
    auto quit = msg(msg(cls("NSMenuItem"), "alloc"), "initWithTitle:action:keyEquivalent:", str("Quit truehdec QC"), sel_registerName("quit:"), str("q"));
    msg<void>(quit, "setTarget:", a.controller); msg<void>(submenu, "addItem:", quit);
    msg<void>(a.application, "setMainMenu:", menu);
    for (id object : {menu, item, submenu, open, quit}) msg<void>(object, "release");
    a.timer = msg(cls("NSTimer"), "timerWithTimeInterval:target:selector:userInfo:repeats:",
                  1.0 / 30, a.controller, sel_registerName("tick:"), id(nullptr), BOOL(1));
    msg<void>(a.timer, "retain");
    msg<void>(msg(cls("NSRunLoop"), "mainRunLoop"), "addTimer:forMode:", a.timer, NSRunLoopCommonModes);
    msg<void>(a.window, "center"); msg<void>(a.window, "makeKeyAndOrderFront:", id(nullptr));
    msg<void>(a.application, "activateIgnoringOtherApps:", BOOL(1));
}
} // namespace

int sthd_qc_main(const std::vector<std::string> &arguments) {
    try {
        std::signal(SIGINT, cancelSignal);
        std::signal(SIGTERM, cancelSignal);
        Pool pool; App app;
        for (size_t i = 0; i < arguments.size(); ++i) {
            auto value = [&]() {
                if (++i == arguments.size()) throw std::runtime_error("Missing option value"); return arguments[i];
            };
            const auto option = arguments[i];
            if (option == "--play") continue;
            if (option == "--help" || option == "-h") {
                std::cout << "macOS QC: truehdec --play [INPUT.mlp | -i INPUT.mlp] [--layout NAME]\n"
                             "Headless playback: truehdec play -i INPUT.mlp\n"
                             "Layouts: 2.0, 5.1, 7.1, 5.1.2, 5.1.4, 7.1.2, 7.1.4, 7.1.6, 9.1.6\n"; return 0;
            }
            if (option == "-i" || option == "--input") app.initialPath = value();
            else if (option == "--layout") { app.initialLayout = value(); app.engine.layout(app.initialLayout); }
            else if (option == "--paused") app.autoplay = false;
            else if (option == "--meters-only") app.engine.monitor(sthd_qc::Monitor::meters);
            else if (!option.empty() && option[0] != '-' && app.initialPath.empty()) app.initialPath = option;
            else throw std::runtime_error("Unsupported QC option: " + option);
        }
        build(app);
        if (std::find(arguments.begin(), arguments.end(), "--meters-only") != arguments.end())
            msg<void>(app.monitor, "selectItemAtIndex:", long(2));
        if (!app.initialPath.empty()) app.engine.load(app.initialPath, app.autoplay);
        msg<void>(app.application, "run");
        msg<void>(app.timer, "invalidate"); msg<void>(app.timer, "release");
        app.cancelExport = true; app.engine.shutdown();
        msg<void>(app.application, "setDelegate:", id(nullptr));
        msg<void>(app.window, "setDelegate:", id(nullptr)); msg<void>(app.window, "release");
        msg<void>(app.controller, "release");
        return 0;
    } catch (const std::exception &e) { std::cerr << "QC error: " << e.what() << '\n'; return 1; }
}
