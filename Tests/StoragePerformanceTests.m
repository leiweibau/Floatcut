#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import "FloatcutOperator.h"

// Redirect standard defaults ONLY in this test executable to a disposable suite.
// This measures the actual engine save path without touching user app defaults.
static NSUserDefaults *testDefaults;
static id benchmarkDefaults(id self, SEL selector) { return testDefaults; }
@interface FCPerformanceSaveTarget : NSObject
- (void)addPreferences:(NSMutableDictionary *)dictionary;
@end
@implementation FCPerformanceSaveTarget
- (void)addPreferences:(NSMutableDictionary *)dictionary { }
@end

int main(void) {
    @autoreleasepool {
        NSString *suite = [@"de.meierkarsten.floatcut.performance-test." stringByAppendingString:NSUUID.UUID.UUIDString];
        testDefaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        Method method = class_getClassMethod([NSUserDefaults class], @selector(standardUserDefaults));
        IMP original = method_setImplementation(method, (IMP)benchmarkDefaults);
        [testDefaults setInteger:0 forKey:@"savePreference"];
        [testDefaults setInteger:200 forKey:@"rememberNum"];
        [testDefaults setBool:NO forKey:@"saveForgottenClippings"];
        FCPerformanceSaveTarget *target = [FCPerformanceSaveTarget new];
        for (NSNumber *imageCount in @[@0, @10, @50]) {
            @autoreleasepool {
                FloatcutOperator *engine = [FloatcutOperator new];
                [engine awakeFromNibDisplaying:20 withDisplayLength:40 withSaveSelector:@selector(addPreferences:) forTarget:target];
                for (int index = 0; index < imageCount.intValue; index++) {
                    NSMutableData *data = [NSMutableData dataWithLength:1024 * 1024];
                    // Synthetic payload, not an actual image: persistence does
                    // not decode image bytes. Unique values prevent deduplication.
                    memset(data.mutableBytes, index + 1, data.length);
                    [engine addImageClippingData:data ofType:@"public.png" fromApp:@"Benchmark" withAppBundleURL:nil target:nil clippingAddedSelector:NULL];
                }
                NSLog(@"Scenario: %d images of 1 MiB; 7 changed-store saves", imageCount.intValue);
                for (int sample = 0; sample < 7; sample++) {
                    [engine addClipping:[NSString stringWithFormat:@"sample-%d", sample] ofType:@"text" fromApp:@"Benchmark" withAppBundleURL:nil target:nil clippingAddedSelector:NULL];
                    [engine saveEngine];
                }
                [engine release];
                [testDefaults removeObjectForKey:@"store"];
                [testDefaults synchronize];
            }
        }
        [testDefaults removePersistentDomainForName:suite];
        [testDefaults synchronize];
        method_setImplementation(method, original);
        [testDefaults release];
        [target release];
    }
    return 0;
}
