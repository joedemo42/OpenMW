#include "platform.hpp"

#include <components/debug/debuglog.hpp>
#include <components/files/conversion.hpp>
#include <components/settings/values.hpp>

#include "../mwbase/environment.hpp"
#include "../mwbase/inputmanager.hpp"
#include "../mwbase/statemanager.hpp"
#include "../mwgui/windowmanagerimp.hpp"
#include "../mwinput/actions.hpp"
#include "../mwrender/pingpongcanvas.hpp"
#include "metalfx.hpp"

#include <MyGUI_Gui.h>
#include <SDL_events.h>
#include <SDL_gamecontroller.h>
#include <SDL_hints.h>
#include <SDL_joystick.h>
#include <SDL_syswm.h>

#import <AVFAudio/AVFAudio.h>
#import <GameController/GameController.h>
#import <UIKit/UIKit.h>

#include <mach/mach.h>
#include <os/proc.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

extern "C"
{
    /// ios/OpenMW/TouchControls.swift: Melo-Controller's on-screen controller over the game view of \a window (SDL's
    /// UIWindow) with the labels of \a style (LabelStyle), its left and right clusters above the HUD elements that
    /// reach \a hudLeft and \a hudRight points above the bottom edge. A press or release of a Melo button ("A",
    /// "leftTrigger", ...) goes to \a button, a stick position (right stick, x and y in -1...1, y down) to \a stick.
    void OMWShowTouchControls(void* window, int style, void (*button)(const char* id, bool pressed),
        void (*stick)(bool right, float x, float y), float hudLeft, float hudRight);
    void OMWHideTouchControls();
    /// Shows the controls' layout editor button or hides it
    void OMWSetTouchControlsEditable(bool editable);
}

namespace
{
    // decided once GameController has reported the devices connected at launch
    bool sDevicesReported = false;
    // SDL's game window, once it exists: the touch controls go over it
    Uint32 sGameWindowId = 0;

    // memory log while the app runs: a long session's trend
    dispatch_source_t sMemoryTimer = nil;

    // footprint = what iOS counts against the app's memory limit; footprint + available = that limit
    void logMemory(const char* when)
    {
        constexpr std::uint64_t mb = 1024 * 1024;
        constexpr const char* thermalStates[] = { "nominal", "fair", "serious", "critical" };
        task_vm_info_data_t info{};
        mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
        const bool ok
            = task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count) == KERN_SUCCESS;
        const NSUInteger thermal = static_cast<NSUInteger>(NSProcessInfo.processInfo.thermalState);
        Log(Debug::Info) << "Memory (" << when << "): footprint " << (ok ? info.phys_footprint / mb : 0) << " MB, peak "
                         << (ok ? info.ledger_phys_footprint_peak / mb : 0) << " MB, available "
                         << os_proc_available_memory() / mb << " MB, thermal state "
                         << (thermal < std::size(thermalStates) ? thermalStates[thermal] : "unknown");
    }

    // the Settings app's "Log contents of Datafiles to file", off again before the listing (as the setup assistant's
    // switch). No exceptions: it also runs in a notification block.
    void logDataFilesIfRequested()
    {
        const CFStringRef key = CFSTR("LogDataFiles");
        // the Settings app may have changed it while the app was in the background
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
        if (!CFPreferencesGetAppBooleanValue(key, kCFPreferencesCurrentApplication, nullptr))
            return;
        CFPreferencesSetAppValue(key, nullptr, kCFPreferencesCurrentApplication);
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);

        const auto start = std::chrono::steady_clock::now();
        const std::filesystem::path documents
            = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)
                  .firstObject.fileSystemRepresentation;
        // as find lists them: hidden entries too, links not followed; folders it may not read are left out
        std::vector<std::pair<std::filesystem::path, std::optional<std::uintmax_t>>> entries;
        std::error_code ec;
        for (std::filesystem::recursive_directory_iterator
                 it(documents, std::filesystem::directory_options::skip_permission_denied, ec),
             end;
             !ec && it != end; it.increment(ec))
        {
            std::optional<std::uintmax_t> size;
            std::error_code entryEc;
            if (it->symlink_status(entryEc).type() == std::filesystem::file_type::regular)
                if (const std::uintmax_t bytes = it->file_size(entryEc); !entryEc)
                    size = bytes;
            entries.emplace_back(it->path().lexically_relative(documents), size);
        }
        // path element order: a folder's entries right after it, also next to "Data Files"
        std::sort(entries.begin(), entries.end(), [](const auto& a, const auto& b) { return a.first < b.first; });

        char date[32];
        const std::time_t now = std::time(nullptr);
        std::tm local{};
        localtime_r(&now, &local);
        std::strftime(date, sizeof(date), "%Y-%m-%d-%H%M%S", &local);
        const std::string name = std::string("Datafiles-") + date + ".log";
        std::ofstream file(documents / name);
        for (const auto& [path, size] : entries)
        {
            file << "./" << Files::pathToUnicodeString(path);
            if (size)
                file << '\t' << *size;
            file << '\n';
        }
        if (ec)
            file << "# incomplete: " << ec.message() << '\n';
        file.close();
        if (!file)
        {
            Log(Debug::Warning) << "Failed to write Documents/" << name;
            return;
        }
        Log(Debug::Info) << "Listed " << entries.size() << " entries of Documents/ into " << name << " in "
                         << std::chrono::duration_cast<std::chrono::milliseconds>(
                                std::chrono::steady_clock::now() - start)
                                .count()
                         << " ms" << (ec ? " (incomplete: " + ec.message() + ")" : "");
    }

    // Xcode's CoreDevice adds a virtual mouse ("CoreDevice touchscreenGesture") while a Mac drives the device
    bool hasUserMouse()
    {
        for (GCMouse* mouse in GCMouse.mice)
            if (![mouse.vendorName hasPrefix:@"CoreDevice"])
                return true;
        return false;
    }

    bool hasGameController()
    {
        return GCController.controllers.count > 0;
    }

    // console-style menus unless a keyboard or mouse is connected without a game controller
    bool wantsControllerMenus()
    {
        const bool keyboardOrMouse = GCKeyboard.coalescedKeyboard != nil || hasUserMouse();
        return hasGameController() || !keyboardOrMouse;
    }

    // the Settings app's "Button Labels" (ios/OpenMW/Settings.bundle), in TouchControls.swift's order
    enum class LabelStyle
    {
        Xbox,
        PlayStation,
        Nintendo
    };

    // the controller SDL reports for the touch controls, so that OpenMW's button hints show their labels: Xbox One S,
    // PS4, Switch Pro (vendor and product as in SDL's controller list)
    struct LabelStyleInfo
    {
        const char* mValue;
        const char* mName;
        Uint16 mVendor;
        Uint16 mProduct;
    };
    constexpr LabelStyleInfo labelStyles[] = { { "xbox", "Xbox", 0x045e, 0x02ea },
        { "playstation", "PlayStation", 0x054c, 0x09cc }, { "nintendo", "Nintendo", 0x057e, 0x2009 } };

    // a value the Settings app stored; nil until the user changed it there
    NSString* stringPreference(CFStringRef key)
    {
        NSString* value = [(id)CFPreferencesCopyAppValue(key, kCFPreferencesCurrentApplication) autorelease];
        return [value isKindOfClass:[NSString class]] ? value : nil;
    }

    LabelStyle readLabelStyle()
    {
        NSString* value = stringPreference(CFSTR("TouchControlsLabels"));
        for (std::size_t i = 0; i < std::size(labelStyles); ++i)
            if ([value isEqualToString:@(labelStyles[i].mValue)])
                return static_cast<LabelStyle>(i);
        return LabelStyle::Xbox;
    }

    // the Settings app's "Taps outside the controls"
    enum class TapAction
    {
        Off,
        Attack,
        Interact
    };
    TapAction sTapAction = TapAction::Off;

    TapAction readTapAction()
    {
        NSString* value = stringPreference(CFSTR("TouchTapAction"));
        if ([value isEqualToString:@"attack"])
            return TapAction::Attack;
        if ([value isEqualToString:@"interact"])
            return TapAction::Interact;
        return TapAction::Off;
    }

    // Playing: a game is loaded, no menu is open and the controls are on. Videos (the intro too) and loading screens
    // run their own loops with the controls off and no GUI mode. The state comes first: the engine creates its window
    // (and with it filterTouchClicks) before the window and input managers.
    bool inGame()
    {
        const MWBase::Environment& env = MWBase::Environment::get();
        return env.getStateManager()->getState() == MWBase::StateManager::State_Running
            && !env.getWindowManager()->isGuiMode() && !env.getInputManager()->controlsDisabled();
    }

    // a left click that is not SDL's touch mouse, so it passes filterTouchClicks
    void pushLeftClick(bool pressed)
    {
        SDL_Event event;
        SDL_zero(event);
        event.type = pressed ? SDL_MOUSEBUTTONDOWN : SDL_MOUSEBUTTONUP;
        event.button.windowID = sGameWindowId;
        event.button.button = SDL_BUTTON_LEFT;
        event.button.state = pressed ? SDL_PRESSED : SDL_RELEASED;
        event.button.clicks = 1;
        SDL_PushEvent(&event);
    }

    void doTapAction(TapAction action)
    {
        if (action == TapAction::Interact)
            MWBase::Environment::get().getInputManager()->executeAction(MWInput::A_Activate);
        else if (action == TapAction::Attack)
        {
            // OpenMW's default Use binding, held across several frames: OpenMW reads Use once per frame.
            // ponytail: follows a rebinding of Use away from the left mouse button (upgrade path: an engine hook)
            pushLeftClick(true);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 15 / 100), dispatch_get_main_queue(),
                ^{ pushLeftClick(false); });
        }
    }

    // A touch outside the touch controls reaches OpenMW as SDL's touch mouse: motion and the left button. In the game
    // (not in a menu) its button is dropped, so dragging only looks around; a tap (short, hardly moved) does the
    // Settings app's tap action. Menus keep their clicks.
    struct TouchPress
    {
        bool mInGame = false;
        Uint32 mTime = 0;
        // movement since the press; SDL's relative mouse mode in the game makes the click positions useless
        int mMovedX = 0;
        int mMovedY = 0;
    };
    TouchPress sTouchPress;

    int filterTouchClicks(void*, SDL_Event* event)
    {
        if (event->type == SDL_MOUSEMOTION && event->motion.which == SDL_TOUCH_MOUSEID)
        {
            sTouchPress.mMovedX += event->motion.xrel;
            sTouchPress.mMovedY += event->motion.yrel;
            return 1;
        }
        if ((event->type != SDL_MOUSEBUTTONDOWN && event->type != SDL_MOUSEBUTTONUP)
            || event->button.which != SDL_TOUCH_MOUSEID || event->button.button != SDL_BUTTON_LEFT)
            return 1;
        if (event->button.state == SDL_PRESSED)
        {
            sTouchPress = { inGame(), event->button.timestamp, 0, 0 };
            return sTouchPress.mInGame ? 0 : 1;
        }
        if (!sTouchPress.mInGame)
            return 1;
        sTouchPress.mInGame = false;
        constexpr Uint32 tapMaxMs = 300;
        constexpr int tapMaxMove = 12; // points (SDL's window coordinates)
        const TapAction action = sTapAction;
        if (action != TapAction::Off && event->button.timestamp - sTouchPress.mTime <= tapMaxMs
            && std::abs(sTouchPress.mMovedX) <= tapMaxMove && std::abs(sTouchPress.mMovedY) <= tapMaxMove)
            // not inside SDL's event queue: the actions send events themselves
            dispatch_async(dispatch_get_main_queue(), ^{
                if (inGame())
                    doTapAction(action);
            });
        return 0;
    }

    // on-screen controls (Melo-Controller) while no keyboard, mouse or game controller is connected, as an SDL virtual
    // game controller
    SDL_Joystick* sTouchJoystick = nullptr;
    LabelStyle sTouchStyle = LabelStyle::Xbox;

    // Melo's face buttons are named by their Nintendo positions: X top, Y left, A right, B bottom. Xbox and
    // PlayStation labels follow SDL's positions (A bottom), Nintendo labels name SDL's buttons (A right), as SDL maps
    // Nintendo controllers.
    SDL_GameControllerButton toSdlButton(std::string_view id, LabelStyle style)
    {
        const bool nintendo = style == LabelStyle::Nintendo;
        if (id == "A")
            return nintendo ? SDL_CONTROLLER_BUTTON_A : SDL_CONTROLLER_BUTTON_B;
        if (id == "B")
            return nintendo ? SDL_CONTROLLER_BUTTON_B : SDL_CONTROLLER_BUTTON_A;
        if (id == "X")
            return nintendo ? SDL_CONTROLLER_BUTTON_X : SDL_CONTROLLER_BUTTON_Y;
        if (id == "Y")
            return nintendo ? SDL_CONTROLLER_BUTTON_Y : SDL_CONTROLLER_BUTTON_X;
        constexpr std::pair<std::string_view, SDL_GameControllerButton> buttons[] = {
            { "back", SDL_CONTROLLER_BUTTON_BACK }, { "guide", SDL_CONTROLLER_BUTTON_GUIDE },
            { "start", SDL_CONTROLLER_BUTTON_START }, { "leftStick", SDL_CONTROLLER_BUTTON_LEFTSTICK },
            { "rightStick", SDL_CONTROLLER_BUTTON_RIGHTSTICK }, { "leftShoulder", SDL_CONTROLLER_BUTTON_LEFTSHOULDER },
            { "rightShoulder", SDL_CONTROLLER_BUTTON_RIGHTSHOULDER }, { "dPadUp", SDL_CONTROLLER_BUTTON_DPAD_UP },
            { "dPadDown", SDL_CONTROLLER_BUTTON_DPAD_DOWN }, { "dPadLeft", SDL_CONTROLLER_BUTTON_DPAD_LEFT },
            { "dPadRight", SDL_CONTROLLER_BUTTON_DPAD_RIGHT } };
        for (const auto& [name, button] : buttons)
            if (name == id)
                return button;
        return SDL_CONTROLLER_BUTTON_INVALID;
    }

    // SDL reads the virtual controller's state once per frame
    void touchButton(const char* id, bool pressed)
    {
        if (sTouchJoystick == nullptr)
            return;
        const std::string_view name(id);
        if (name == "leftTrigger" || name == "rightTrigger")
            SDL_JoystickSetVirtualAxis(sTouchJoystick,
                name == "leftTrigger" ? SDL_CONTROLLER_AXIS_TRIGGERLEFT : SDL_CONTROLLER_AXIS_TRIGGERRIGHT,
                pressed ? SDL_JOYSTICK_AXIS_MAX : SDL_JOYSTICK_AXIS_MIN);
        else if (const SDL_GameControllerButton button = toSdlButton(name, sTouchStyle);
                 button != SDL_CONTROLLER_BUTTON_INVALID)
            SDL_JoystickSetVirtualButton(sTouchJoystick, button, pressed ? SDL_PRESSED : SDL_RELEASED);
    }

    void touchStick(bool right, float x, float y)
    {
        if (sTouchJoystick == nullptr)
            return;
        const auto axis = [](float value) {
            return static_cast<Sint16>(std::clamp(value, -1.f, 1.f) * SDL_JOYSTICK_AXIS_MAX);
        };
        SDL_JoystickSetVirtualAxis(
            sTouchJoystick, right ? SDL_CONTROLLER_AXIS_RIGHTX : SDL_CONTROLLER_AXIS_LEFTX, axis(x));
        SDL_JoystickSetVirtualAxis(
            sTouchJoystick, right ? SDL_CONTROLLER_AXIS_RIGHTY : SDL_CONTROLLER_AXIS_LEFTY, axis(y));
    }

    // The touch controls' layout editor is offered while the game menu is the top screen (the game is paused). The
    // window manager exists only once the engine created it: its constructor sets up MyGUI first and runs no frame
    // before the engine stores it.
    dispatch_source_t sMenuTimer = nil;
    bool sEditable = false;

    void updateEditable()
    {
        const bool editable = MyGUI::Gui::getInstancePtr() != nullptr
            && MWBase::Environment::get().getWindowManager()->getMode() == MWGui::GM_MainMenu;
        if (editable == sEditable)
            return;
        sEditable = editable;
        OMWSetTouchControlsEditable(editable);
    }

    void hideTouchControls()
    {
        if (sTouchJoystick == nullptr)
            return;
        dispatch_source_cancel(sMenuTimer);
        dispatch_release(sMenuTimer);
        sMenuTimer = nil;
        OMWHideTouchControls();
        const SDL_JoystickID id = SDL_JoystickInstanceID(sTouchJoystick);
        SDL_JoystickClose(sTouchJoystick);
        sTouchJoystick = nullptr;
        for (int i = 0; i < SDL_NumJoysticks(); ++i)
            if (SDL_JoystickGetDeviceInstanceID(i) == id)
            {
                SDL_JoystickDetachVirtual(i);
                break;
            }
        Log(Debug::Info) << "Touch controls off";
    }

    void showTouchControls(SDL_Window* window, LabelStyle style)
    {
        SDL_SysWMinfo info;
        SDL_VERSION(&info.version);
        if (!SDL_GetWindowWMInfo(window, &info))
        {
            Log(Debug::Warning) << "Failed to show the touch controls: " << SDL_GetError();
            return;
        }
        const LabelStyleInfo& labels = labelStyles[static_cast<std::size_t>(style)];
        SDL_VirtualJoystickDesc desc;
        SDL_zero(desc);
        desc.version = SDL_VIRTUAL_JOYSTICK_DESC_VERSION;
        desc.type = SDL_JOYSTICK_TYPE_GAMECONTROLLER;
        // all axes and the buttons up to the D-pad: the joystick's axis/button i is SDL's controller axis/button i
        desc.naxes = SDL_CONTROLLER_AXIS_MAX;
        desc.nbuttons = SDL_CONTROLLER_BUTTON_DPAD_RIGHT + 1;
        desc.vendor_id = labels.mVendor;
        desc.product_id = labels.mProduct;
        desc.name = "Touch Controls";
        const int index = SDL_JoystickAttachVirtualEx(&desc);
        sTouchJoystick = index < 0 ? nullptr : SDL_JoystickOpen(index);
        if (sTouchJoystick == nullptr)
        {
            Log(Debug::Warning) << "Failed to show the touch controls: " << SDL_GetError();
            if (index >= 0)
                SDL_JoystickDetachVirtual(index);
            return;
        }
        sTouchStyle = style;
        // files/data/mygui/openmw_hud.layout, GUI units above the bottom edge: bars and weapon/spell/sneak boxes bottom
        // left, minimap bottom right; a GUI unit is [GUI] scaling factor points. ponytail: the layout file's numbers
        // (upgrade path: the HUD widgets' rectangles once the HUD exists)
        const float guiScale = Settings::gui().mScalingFactor;
        OMWShowTouchControls(info.info.uikit.window, static_cast<int>(style), touchButton, touchStick, 53 * guiScale,
            76 * guiScale);
        sEditable = false;
        sMenuTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(sMenuTimer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 4, NSEC_PER_SEC / 20);
        dispatch_source_set_event_handler(sMenuTimer, ^{ updateEditable(); });
        dispatch_resume(sMenuTimer);
        Log(Debug::Info) << "Touch controls on (" << labels.mName << " labels)";
    }

    // Melo-Controller's controls draw all of OpenMW's default controller bindings but quicksave (Save in the game
    // menu). Shown over SDL's game window; a changed label style shows them anew.
    void updateTouchController()
    {
        SDL_Window* window = sGameWindowId != 0 ? SDL_GetWindowFromID(sGameWindowId) : nullptr;
        const bool wanted = sDevicesReported && window != nullptr && GCKeyboard.coalescedKeyboard == nil
            && !hasUserMouse() && !hasGameController();
        // the Settings app may have changed them while the app was in the background
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
        sTapAction = readTapAction();
        const LabelStyle style = readLabelStyle();
        if (sTouchJoystick != nullptr && (!wanted || style != sTouchStyle))
            hideTouchControls();
        if (wanted && sTouchJoystick == nullptr)
            showTouchControls(window, style);
    }

    // SDL's game window once it exists (SDL's joystick subsystem is initialized before it)
    int onWindowEvent(void*, SDL_Event* event)
    {
        if (event->type != SDL_WINDOWEVENT)
            return 0;
        sGameWindowId = event->window.windowID;
        SDL_DelEventWatch(onWindowEvent, nullptr);
        // not inside SDL's event dispatch: attaching the virtual controller sends events itself
        dispatch_async(dispatch_get_main_queue(), ^{
            SDL_SetEventFilter(filterTouchClicks, nullptr);
            updateTouchController();
        });
        return 0;
    }

    // Gamepad-style menus follow the connected devices. ponytail: the window manager saves the switched value to
    // settings.cfg like any setting; it is decided anew at every launch, so editing [GUI] controller menus there has no
    // effect on iOS (upgrade path: a runtime override that is not saved).
    std::string describe(NSArray<id<GCDevice>>* devices)
    {
        std::string result;
        for (id<GCDevice> device in devices)
            result += std::string(result.empty() ? "" : ", ") + device.productCategory.UTF8String + " ("
                + (device.vendorName != nil ? device.vendorName.UTF8String : "?") + ")";
        return result;
    }

    void updateInputDevices(NSString* when)
    {
        GCKeyboard* keyboard = GCKeyboard.coalescedKeyboard;
        Log(Debug::Info) << "Input devices (" << when.UTF8String << "): keyboard ["
                         << describe(keyboard ? @[ keyboard ] : @[]) << "], mice [" << describe(GCMouse.mice)
                         << "], controllers [" << describe(GCController.controllers) << "] -> controller menus "
                         << (wantsControllerMenus() ? "on" : "off");
        MWGui::WindowManager::requestControllerMenus(wantsControllerMenus());
        updateTouchController();
    }
}

void OMW::initIosPlatform()
{
    @autoreleasepool
    {
        // a swipe from the bottom edge first shows the home indicator, the second one leaves the game
        SDL_SetHint(SDL_HINT_IOS_HIDE_HOME_INDICATOR, "2");

        // Mesa's shader cache in Library/Caches (its default, $HOME/.cache, is the container root); before the engine
        // creates the GL context. No overwrite: a launch environment can move or disable it
        NSString* caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        setenv("MESA_SHADER_CACHE_DIR", caches.fileSystemRepresentation, 0);

        // render scale: MetalFX scales the 3D world up
        MWRender::PingPongCanvas::setUpscaler(OMW::metalFxUpscale);

        // mixes with other apps' audio, muted by the silent switch
        NSError* error = nil;
        if (![[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient error:&error])
            Log(Debug::Warning) << "Failed to set the audio session category: "
                                << error.localizedDescription.UTF8String;

        logMemory("launch");
        NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                            object:nil
                             queue:nil
                        usingBlock:^(NSNotification*) { logMemory("memory warning"); }];
        [center addObserverForName:UIApplicationDidEnterBackgroundNotification
                            object:nil
                             queue:nil
                        usingBlock:^(NSNotification*) { logMemory("background"); }];
        [center addObserverForName:NSProcessInfoThermalStateDidChangeNotification
                            object:nil
                             queue:nil
                        usingBlock:^(NSNotification*) { logMemory("thermal state change"); }];
        sMemoryTimer = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(
            sMemoryTimer, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), 60 * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(sMemoryTimer, ^{ logMemory("every 60 s"); });
        dispatch_resume(sMemoryTimer);

        // GameController reports connected devices shortly after launch, as connect notifications
        updateInputDevices(@"launch");
        // without connected devices there is no notification
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            sDevicesReported = true;
            updateTouchController();
        });
        // before SDL_Init: SDL keeps event watches added before its event loop starts
        SDL_AddEventWatch(onWindowEvent, nullptr);
        // the Settings app's "Button Labels" is changed while the app is in the background
        for (NSString* name in @[ GCKeyboardDidConnectNotification, GCKeyboardDidDisconnectNotification,
                 GCMouseDidConnectNotification, GCMouseDidDisconnectNotification, GCControllerDidConnectNotification,
                 GCControllerDidDisconnectNotification, UIApplicationWillEnterForegroundNotification ])
            [center addObserverForName:name
                                object:nil
                                 queue:NSOperationQueue.mainQueue
                            usingBlock:^(NSNotification* notification) { updateInputDevices(notification.name); }];
    }
}

void OMW::initDataFilesLog()
{
    @autoreleasepool
    {
        logDataFilesIfRequested();
        // the Settings app is used while this app is in the background
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillEnterForegroundNotification
                                                        object:nil
                                                         queue:nil
                                                    usingBlock:^(NSNotification*) { logDataFilesIfRequested(); }];
    }
}

void OMW::configureMetalHud()
{
    // Off sets nothing; no overwrite: a launch environment can switch the HUD on or off
    const int mode = Settings::video().mMetalHud;
    if (mode == 0)
        return;
    const char* detailed = mode == 2 ? "1" : "0";
    setenv("MTL_HUD_ENABLED", "1", 0);
    setenv("MTL_HUD_ENCODER_TIMING_ENABLED", detailed, 0);
    setenv("MTL_HUD_SHOW_METRICS_RANGE", detailed, 0);
    setenv("MTL_HUD_INSIGHTS_ENABLED", detailed, 0);
    setenv("MTL_HUD_LOG_ENABLED", "0", 0);
    setenv("MTL_HUD_LOG_SHADER_ENABLED", "0", 0);
    Log(Debug::Info) << "Metal Performance HUD: " << (mode == 2 ? "detailed" : "standard");
}
