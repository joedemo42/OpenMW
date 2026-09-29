// Placeholder app host until the OpenMW engine is linked (replaced by the SDL entry point).
#import <UIKit/UIKit.h>

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation AppDelegate
@end

@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow* window;
@end

@implementation SceneDelegate
- (void)scene:(UIScene*)scene
    willConnectToSession:(UISceneSession*)session
                 options:(UISceneConnectionOptions*)options
{
    UIViewController* root = [UIViewController new];
    root.view.backgroundColor = UIColor.blackColor;
    UILabel* label = [UILabel new];
    label.text = @"Morrowind";
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont systemFontOfSize:48];
    [label sizeToFit];
    label.center = root.view.center;
    label.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin
        | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [root.view addSubview:label];

    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];
    NSLog(@"Morrowind placeholder running, build %@", NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"]);
}
@end

int main(int argc, char* argv[])
{
    @autoreleasepool
    {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class));
    }
}
