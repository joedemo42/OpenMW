#include "platform.hpp"

#include <components/debug/debuglog.hpp>
#include <components/settings/values.hpp>

#include "../mwgui/windowmanagerimp.hpp"

#include <SDL_events.h>
#include <SDL_hints.h>
#include <SDL_syswm.h>

#import <AVFAudio/AVFAudio.h>
#import <CoreText/CoreText.h>
#import <GameController/GameController.h>
#import <UIKit/UIKit.h>

#include <mach/mach.h>
#include <os/proc.h>

#include <cstdint>
#include <cstdlib>
#include <iterator>
#include <string>

// target of the two-finger tap on the game view
@interface OMWTwoFingerTap : NSObject
- (void)tapped:(UITapGestureRecognizer*)recognizer;
@end

namespace
{
    // on-screen controls (system-drawn GCVirtualController) while no keyboard, mouse or game controller is connected
    GCVirtualController* sTouchController = nil;
    // decided once GameController has reported the devices connected at launch
    bool sDevicesReported = false;

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

    // Xcode's CoreDevice adds a virtual mouse ("CoreDevice touchscreenGesture") while a Mac drives the device
    bool hasUserMouse()
    {
        for (GCMouse* mouse in GCMouse.mice)
            if (![mouse.vendorName hasPrefix:@"CoreDevice"])
                return true;
        return false;
    }

    // the touch controller is a GCController too, but never counts as one
    bool hasGameController()
    {
        for (GCController* controller in GCController.controllers)
            if (sTouchController == nil || controller != sTouchController.controller)
                return true;
        return false;
    }

    // console-style menus unless a keyboard or mouse is connected without a game controller
    bool wantsControllerMenus()
    {
        const bool keyboardOrMouse = GCKeyboard.coalescedKeyboard != nil || hasUserMouse();
        return hasGameController() || !keyboardOrMouse;
    }

    // A button face like the system's A/B/X/Y: a disc with the label cut out. The touch controller draws an element's
    // path as its face, centered on the origin (y up) and scaled to the button.
    UIBezierPath* labeledFace(NSString* label)
    {
        CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, 24, nullptr);
        CGMutablePathRef glyphs = CGPathCreateMutable();
        CGFloat x = 0;
        for (NSUInteger i = 0; i < label.length; ++i)
        {
            const UniChar character = [label characterAtIndex:i];
            CGGlyph glyph;
            CTFontGetGlyphsForCharacters(font, &character, &glyph, 1);
            if (CGPathRef path = CTFontCreatePathForGlyph(font, glyph, nullptr))
            {
                const CGAffineTransform advance = CGAffineTransformMakeTranslation(x, 0);
                CGPathAddPath(glyphs, &advance, path);
                CGPathRelease(path);
            }
            x += CTFontGetAdvancesForGlyphs(font, kCTFontOrientationDefault, &glyph, nullptr, 1);
        }
        CFRelease(font);

        const CGRect bounds = CGPathGetPathBoundingBox(glyphs);
        const CGAffineTransform center
            = CGAffineTransformMakeTranslation(-CGRectGetMidX(bounds), -CGRectGetMidY(bounds));
        CGPathRef centered = CGPathCreateCopyByTransformingPath(glyphs, &center);
        CGPathRelease(glyphs);

        UIBezierPath* face = [UIBezierPath bezierPathWithArcCenter:CGPointZero
                                                            radius:20
                                                        startAngle:0
                                                          endAngle:2 * M_PI
                                                         clockwise:YES];
        [face appendPath:[UIBezierPath bezierPathWithCGPath:centered]];
        CGPathRelease(centered);
        face.usesEvenOddFillRule = YES;
        return face;
    }

    // The touch controller has all elements of OpenMW's default controller bindings but sneak, view, game menu and
    // quicksave (it cannot draw L3, R3, Menu or Home). A two-finger tap opens the game menu, quicksave is Save there.
    // ponytail: no touch input for sneak and view (upgrade path: more gestures, or app-drawn controls via the hidden
    // configuration).
    void updateTouchController()
    {
        const bool wanted
            = sDevicesReported && GCKeyboard.coalescedKeyboard == nil && !hasUserMouse() && !hasGameController();
        if (wanted == (sTouchController != nil))
            return;

        if (!wanted)
        {
            [sTouchController disconnect];
            [sTouchController release];
            sTouchController = nil;
            Log(Debug::Info) << "Touch controls off";
            return;
        }

        GCVirtualControllerConfiguration* configuration = [[GCVirtualControllerConfiguration alloc] init];
        configuration.elements = [NSSet setWithArray:@[ GCInputLeftThumbstick, GCInputRightThumbstick, GCInputButtonA,
            GCInputButtonB, GCInputButtonX, GCInputButtonY, GCInputLeftShoulder, GCInputRightShoulder,
            GCInputLeftTrigger, GCInputRightTrigger ]];
        GCVirtualController* controller = [[GCVirtualController alloc] initWithConfiguration:configuration];
        [configuration release];
        sTouchController = controller;
        Log(Debug::Info) << "Touch controls requested";
        [controller connectWithReplyHandler:^(NSError* error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (controller != sTouchController)
                    return; // disconnected meanwhile
                if (error != nil)
                {
                    Log(Debug::Warning) << "Failed to show the touch controls: " << error.description.UTF8String;
                    [sTouchController release];
                    sTouchController = nil;
                    return;
                }
                // the names OpenMW's controller menus show in their hints for this controller type
                NSDictionary<NSString*, NSString*>* labels = @{ GCInputLeftShoulder : @"L1",
                    GCInputRightShoulder : @"R1", GCInputLeftTrigger : @"L2", GCInputRightTrigger : @"R2" };
                for (NSString* element in labels)
                    [controller updateConfigurationForElement:element
                                                configuration:^GCVirtualControllerElementConfiguration*(
                                                    GCVirtualControllerElementConfiguration* elementConfiguration) {
                                                    elementConfiguration.path = labeledFace(labels[element]);
                                                    return elementConfiguration;
                                                }];
                Log(Debug::Info) << "Touch controls on";
            });
        }];
    }

    // the touch controller's undrawn Menu button is SDL's Start button (OpenMW: game menu)
    void pressStart()
    {
        GCVirtualController* controller = sTouchController;
        if (controller == nil)
            return;
        [controller setValue:1 forButtonElement:GCInputButtonMenu];
        // held across several frames: SDL reads the button state once per frame
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5), dispatch_get_main_queue(),
            ^{ [controller setValue:0 forButtonElement:GCInputButtonMenu]; });
    }

    // adds the two-finger tap recognizer to SDL's window once it exists
    int addTwoFingerTap(void*, SDL_Event* event)
    {
        if (event->type != SDL_WINDOWEVENT)
            return 0;
        SDL_SysWMinfo info;
        SDL_VERSION(&info.version);
        SDL_Window* window = SDL_GetWindowFromID(event->window.windowID);
        if (window == nullptr || !SDL_GetWindowWMInfo(window, &info))
            return 0;

        static OMWTwoFingerTap* target = [[OMWTwoFingerTap alloc] init]; // recognizers do not retain their target
        UITapGestureRecognizer* tap = [[UITapGestureRecognizer alloc] initWithTarget:target action:@selector(tapped:)];
        tap.numberOfTouchesRequired = 2;
        // SDL still gets every touch, without delay
        tap.cancelsTouchesInView = NO;
        tap.delaysTouchesEnded = NO;
        [info.info.uikit.window addGestureRecognizer:tap];
        [tap release];
        SDL_DelEventWatch(addTwoFingerTap, nullptr);
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

@implementation OMWTwoFingerTap
- (void)tapped:(UITapGestureRecognizer*)recognizer
{
    pressStart();
}
@end

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
        SDL_AddEventWatch(addTwoFingerTap, nullptr);
        for (NSString* name in @[ GCKeyboardDidConnectNotification, GCKeyboardDidDisconnectNotification,
                 GCMouseDidConnectNotification, GCMouseDidDisconnectNotification, GCControllerDidConnectNotification,
                 GCControllerDidDisconnectNotification ])
            [center addObserverForName:name
                                object:nil
                                 queue:NSOperationQueue.mainQueue
                            usingBlock:^(NSNotification* notification) { updateInputDevices(notification.name); }];
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
