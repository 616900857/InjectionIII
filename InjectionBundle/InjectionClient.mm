//
//  InjectionClient.mm
//  InjectionBundle
//
//  Created by John Holdsworth on 06/11/2017.
//  Copyright © 2017 John Holdsworth. All rights reserved.
//
//  $Id: //depot/ResidentEval/InjectionBundle/InjectionClient.mm#100 $
//

#import "InjectionClient.h"
#import "SwiftTrace.h"

#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
#if __has_include("tvOSInjection10-Swift.h")
#import "tvOSInjection10-Swift.h"
#elif __has_include("tvOSInjection-Swift.h")
#import "tvOSInjection-Swift.h"
#elif __has_include("iOSInjection10-Swift.h")
#import "iOSInjection10-Swift.h"
#else
#import "iOSInjection-Swift.h"
#endif
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@implementation NSObject (Remapper)

static struct {
    NSMutableDictionary *inputIndexes;
    NSMutableArray *output, *order;
    int orderIndex;
} remapper;

+ (void)my_addMappingFromIdentifier:(NSString *)identifier toObject:(id)object forCoder:(id)coder {
    //NSLog(@"Map %@ = %@", identifier, object);
    if(remapper.output && [identifier hasPrefix:@"UpstreamPlaceholder-"]) {
        if (remapper.inputIndexes)
            remapper.inputIndexes[identifier] = @([remapper.inputIndexes count]);
        else
            [remapper.output addObject:object];
    }
    [self my_addMappingFromIdentifier:identifier toObject:object forCoder:coder];
}

+ (id)my_mappedObjectForCoder:(id)decoder withIdentifier:(NSString *)identifier {
    //NSLog(@"Mapped? %@", identifier);
    if(remapper.output && [identifier hasPrefix:@"UpstreamPlaceholder-"]) {
        if (remapper.inputIndexes)
            [remapper.order addObject:remapper.inputIndexes[identifier] ?: @""];
        else
            return remapper.output[[remapper.order[remapper.orderIndex++] intValue]];
    }
    return [self my_mappedObjectForCoder:decoder withIdentifier:identifier];
}

@end

@interface UIViewController (StoryboardInjection)
- (void)_loadViewFromNibNamed:(NSString *)a0 bundle:(NSBundle *)a1;
@end
@implementation UIViewController (iOS14StoryboardInjection)
- (void)iOS14LoadViewFromNibNamed:(NSString *)nibName bundle:(NSBundle *)bundle {
    if ([self respondsToSelector:@selector(_loadViewFromNibNamed:bundle:)])
        [self _loadViewFromNibNamed:nibName bundle:bundle];
    else {
        size_t vcSize = class_getInstanceSize([UIViewController class]);
        size_t mySize = class_getInstanceSize([self class]);
        char *extra = (char *)(__bridge void *)self + vcSize;
        NSData *save = [NSData dataWithBytes:extra length:mySize-vcSize];
        (void)[self initWithNibName:nibName bundle:bundle];
        memcpy(extra, save.bytes, save.length);
        [self loadView];
    }
}
@end
#else
#if __has_include("macOSInjection10-Swift.h")
#import "macOSInjection10-Swift.h"
#else
#import "macOSInjection-Swift.h"
#endif
#endif

#ifdef XPROBE_PORT
#import "../XprobePlugin/Classes/Xtrace.mm"
#import "../XprobePlugin/Classes/Xprobe.mm"
#import "../XprobePlugin/Classes/Xprobe+Service.mm"

@interface BundleInjection: NSObject
@end
@implementation BundleInjection
+ (const char *)connectedAddress {
    return "127.0.0.1";
}
@end

@implementation Xprobe(Seeding)
#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
+ (NSArray *)xprobeSeeds {
    UIApplication *app = [UIApplication sharedApplication];
    NSMutableArray *seeds = [[app windows] mutableCopy];
    [seeds insertObject:app atIndex:0];
    return seeds;
}
#else
+ (NSArray *)xprobeSeeds {
    NSApplication *app = [NSApplication sharedApplication];
    NSMutableArray *seeds = [[app windows] mutableCopy];
    if ( app.delegate )
        [seeds insertObject:app.delegate atIndex:0];
    return seeds;
}
#endif
@end
#endif

@interface SwiftUISupport
+ (void)setupWithPointer:(void *)ptr;
@end

@interface InjectionClient () {
    BOOL tracing;
}
@end

@implementation InjectionClient

+ (void)load {
    // connect to InjectionIII.app using socket
    if (InjectionClient *client = [self connectTo:INJECTION_ADDRESS])
        [client run];
    else {
        printf("💉 Injection loaded but could not connect. Is InjectionIII.app running?\n");
#ifndef __IPHONE_OS_VERSION_MIN_REQUIRED
        printf("⚠️ For a macOS app you need to turn off the sandbox to connect. ⚠️\n");
#endif
    }
}

- (void)runInBackground {
    NSString *tmpDir = [self readString];
    [SwiftEval sharedInstance].tmpDir = tmpDir;

    if (![@"/tmp" isEqualToString:tmpDir])
        [self writeInt:INJECTION_SALT];
    [self writeString:INJECTION_KEY];
    [self writeString:[NSBundle
                       mainBundle].privateFrameworksPath];

    [self writeString:[SwiftEval sharedInstance].arch];
    [self writeString:[NSBundle mainBundle].executablePath];

    int codesignStatusPipe[2];
    pipe(codesignStatusPipe);
    SimpleSocket *reader = [[SimpleSocket alloc] initSocket:codesignStatusPipe[0]];
    SimpleSocket *writer = [[SimpleSocket alloc] initSocket:codesignStatusPipe[1]];

    // make available implementation of signing delegated to macOS app
    [SwiftEval sharedInstance].signer = ^BOOL(NSString *_Nonnull dylib) {
        [self writeCommand:InjectionSign withString:dylib];
        return [reader readString].boolValue;
    };

    // As tmp file names come in, inject them
    InjectionCommand command;
    while ((command = (InjectionCommand)[self readInt]) != InjectionEOF) {
        switch (command) {
        case InjectionVaccineSettingChanged: {
            NSString *string = [self readString];
            NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];

            NSDictionary *dictionary = (NSDictionary *)json;
            if (dictionary != nil) {
                NSNumber *vaccineEnabled = [dictionary valueForKey:@"Enabled Vaccine"];
                [SwiftEval sharedInstance].vaccineEnabled = [vaccineEnabled boolValue];
            }
            break;
        }
        case InjectionConnected: {
            NSString *projectFile = [self readString];
            [SwiftEval sharedInstance].projectFile = projectFile;
            [SwiftEval sharedInstance].derivedLogs = nil;
            printf("💉 Injection connected 👍\n");
            NSString *pbxFile = [projectFile
                 stringByAppendingPathComponent:@"project.pbxproj"];
            NSString *pbxContents = [NSString
                 stringWithContentsOfFile:pbxFile
                 encoding:NSUTF8StringEncoding error:NULL];
            if (![pbxContents containsString:@"-interposable"])
                printf("💉 Have you remembered to add \"-Xlinker -interposable\" to your project's \"Other Linker Flags\"?\n");
            break;
        }
        case InjectionWatching: {
            NSString *directory = [self readString];
            printf("💉 Watching %s/**\n", directory.UTF8String);
            break;
        }
        case InjectionLog:
            printf("%s\n", [self readString].UTF8String);
            break;
        case InjectionSigned:
            [writer writeString:[self readString]];
            break;
        case InjectionTrace:
            tracing = TRUE;
            [SwiftTrace swiftTraceMainBundle];
            printf("💉 Added trace to non-final methods of classes in app bundle\n");
            [self filteringChanged];
            break;
        case InjectionUntrace:
            tracing = FALSE;
            [SwiftTrace swiftTraceRemoveAllTraces];
            break;
        case InjectionTraceUI:
            tracing = TRUE;
            static char classInSwiftUIMangled[] = "$s7SwiftUI14AnyTextStorageCN";
            if (Class AnyText = (__bridge Class)
                dlsym(RTLD_DEFAULT, classInSwiftUIMangled)) {
                NSString *swiftUIBundlePath = [[[NSBundle
                    bundleForClass:[self class]] bundlePath]
                    stringByReplacingOccurrencesOfString:@"Injection.bundle"
                                         withString:@"SwiftUISupport.bundle"];
                if (Class swiftUISupport = [[NSBundle
                                             bundleWithPath:swiftUIBundlePath]
                                            classNamed:@"SwiftUISupport"])
                    [swiftUISupport
                     setupWithPointer:SwiftTrace.swiftTypeHandlers];
                else
                    printf("💉 Could not find SwiftUISupport at path: %s\n",
                           swiftUIBundlePath.UTF8String);
                [SwiftTrace swiftTraceMethodsInFrameworkContaining:AnyText];
            }
            [SwiftTrace swiftTraceMainBundleMethods];
            printf("💉 Added trace to methods in main bundle\n");
            [self filteringChanged];
            break;
        case InjectionInclude:
            [SwiftTrace setSwiftTraceFilterInclude:[self readString]];
            [self filteringChanged];
            break;
        case InjectionExclude:
            [SwiftTrace setSwiftTraceFilterExclude:[self readString]];
            [self filteringChanged];
            break;
        case InjectionInvalid:
            printf("💉 ⚠️ Connection rejected. Are you running the correct version of InjectionIII.app from /Applications? ⚠️\n");
            break;
        case InjectionIdeProcPath: {
            [SwiftEval sharedInstance].lastIdeProcPath = [self readString];
            break;
        }
        default: {
            NSString *changed = [self readString];
            dispatch_async(dispatch_get_main_queue(), ^{
                NSError *err = nil;
                switch (command) {
                case InjectionLoad:
                    [SwiftInjection injectWithTmpfile:changed error:&err];
                    break;
                case InjectionInject: {
#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
                    if ([changed hasSuffix:@"storyboard"] || [changed hasSuffix:@"xib"]) {
                        if (![self injectUI:changed])
                            return;
                    }
                    else
#endif
                        [SwiftInjection injectWithOldClass:nil classNameOrFile:changed];
                    break;
                }
#ifdef XPROBE_PORT
                case InjectionXprobe:
                    [Xprobe connectTo:NULL retainObjects:YES];
                    [Xprobe search:@""];
                    break;
                case InjectionEval: {
                    NSArray<NSString *> *parts = [changed componentsSeparatedByString:@"^"];
                    int pathID = parts[0].intValue;
                    [self writeCommand:InjectionPause withString:@"5"];
                    if ([xprobePaths[pathID].object respondsToSelector:@selector(evalSwift:)])
                        [xprobePaths[pathID].object evalSwift:parts[3].stringByRemovingPercentEncoding];
                    else
                        printf("Eval only works on NSObject subclasses\n");
                    [Xprobe writeString:[NSString stringWithFormat:@"$('BUSY%d').hidden = true; ", pathID]];
                    break;
                }
#endif
                default:
                    [self writeCommand:InjectionError withString:[NSString
                          stringWithFormat:@"Invalid command #%d", command]];
                    break;
                }

                [self writeCommand:err ? InjectionError : InjectionComplete
                        withString:err ? err.localizedDescription : nil];
            });
        }
        }
    }
}

-(void)filteringChanged {
    if (!tracing) return;
    NSString *exclude = SwiftTrace.swiftTraceFilterExclude;
    if (NSString *include = SwiftTrace.swiftTraceFilterInclude)
        printf(exclude ?
           "💉 Filtering trace to include methods matching '%s' but not '%s'.\n" :
           "💉 Filtering trace to include methods matching '%s'.\n",
            include.UTF8String, exclude.UTF8String);
    else if (exclude)
        printf(
           "💉 Filtering trace to exclude methods matching '%s'.\n", exclude.UTF8String);
}

#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
- (BOOL)injectUI:(NSString *)changed {
    static NSMutableDictionary *allOrder;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        Class proxyClass = objc_getClass("UIProxyObject");
        method_exchangeImplementations(
           class_getClassMethod(proxyClass,
                                @selector(my_addMappingFromIdentifier:toObject:forCoder:)),
           class_getClassMethod(proxyClass,
                                @selector(addMappingFromIdentifier:toObject:forCoder:)));
        method_exchangeImplementations(
           class_getClassMethod(proxyClass,
                                @selector(my_mappedObjectForCoder:withIdentifier:)),
           class_getClassMethod(proxyClass,
                                @selector(mappedObjectForCoder:withIdentifier:)));
        allOrder = [NSMutableDictionary new];
    });

    @try {
        UIViewController *rootViewController = [UIApplication sharedApplication].windows.firstObject.rootViewController;
        UINavigationController *navigationController = (UINavigationController*)rootViewController;
        UIViewController *visibleVC = rootViewController;

        if (UIViewController *child =
            visibleVC.childViewControllers.firstObject)
            visibleVC = child;
        if ([visibleVC respondsToSelector:@selector(viewControllers)])
            visibleVC = [(UISplitViewController *)visibleVC
                         viewControllers].lastObject;

        if ([visibleVC respondsToSelector:@selector(visibleViewController)])
            visibleVC = [(UINavigationController *)visibleVC
                         visibleViewController];
        if (!visibleVC.nibName && [navigationController respondsToSelector:@selector(topViewController)]) {
          visibleVC = [navigationController topViewController];
        }

        NSString *nibName = visibleVC.nibName;

        if (!(remapper.order = allOrder[nibName])) {
            remapper.inputIndexes = [NSMutableDictionary new];
            remapper.output = [NSMutableArray new];
            allOrder[nibName] = remapper.order = [NSMutableArray new];

            [visibleVC iOS14LoadViewFromNibNamed:visibleVC.nibName
                                          bundle:visibleVC.nibBundle];

            remapper.inputIndexes = nil;
            remapper.output = nil;
        }

        NSError *err = nil;
        [[SwiftEval sharedInstance] rebuildWithStoryboard:changed error:&err];
        if (err)
            return FALSE;
    
        void (^resetRemapper)(void) = ^{
            remapper.output = [NSMutableArray new];
            remapper.orderIndex = 0;
        };
        
        resetRemapper();

        [visibleVC iOS14LoadViewFromNibNamed:visibleVC.nibName
                                      bundle:visibleVC.nibBundle];

        if ([SwiftEval sharedInstance].vaccineEnabled == YES) {
            resetRemapper();
            [SwiftInjection vaccine:visibleVC];
        } else {
            [visibleVC viewDidLoad];
            [visibleVC viewWillAppear:NO];
            [visibleVC viewDidAppear:NO];

#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
            [SwiftInjection flash:visibleVC];
#endif
        }
    }
    @catch(NSException *e) {
        printf("Problem reloading nib: %s\n", e.reason.UTF8String);
    }

    remapper.output = nil;
    return true;
}
#endif

@end
