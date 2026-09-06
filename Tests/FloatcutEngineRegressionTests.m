#import <Foundation/Foundation.h>
#import "FloatcutClipping.h"
#import "FloatcutStore.h"
#import "FloatcutOperator.h"

@interface FCNoopSaveTarget : NSObject
- (void)addPreferencesToDictionary:(NSMutableDictionary *)dictionary;
@end

@implementation FCNoopSaveTarget
- (void)addPreferencesToDictionary:(NSMutableDictionary *)dictionary
{
    (void)dictionary;
}
@end

@interface FCTrackingOperator : FloatcutOperator {
    int autosaveRequestCount;
}
@property (nonatomic, readonly) int autosaveRequestCount;
- (bool)saveFromStore:(FloatcutStore *)store atIndex:(int)index withPrefix:(NSString *)prefix;
@end

@implementation FCTrackingOperator
- (int)autosaveRequestCount
{
    return autosaveRequestCount;
}

- (bool)saveFromStore:(FloatcutStore *)store atIndex:(int)index withPrefix:(NSString *)prefix
{
    (void)store;
    (void)index;
    if ([prefix isEqualToString:@"Autosave "])
        autosaveRequestCount++;
    return YES;
}
@end

static void FCAssert(BOOL condition, NSString *message)
{
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static NSArray *activeStoreIdentifiers(FloatcutOperator *operator)
{
    NSMutableArray *identifiers = [NSMutableArray array];
    for (int index = 0; index < operator.jcListCount; index++) {
        NSString *identifier = [[operator getClippingFromIndex:index] identifier];
        if (identifier)
            [identifiers addObject:identifier];
    }
    return identifiers;
}

static FloatcutClipping *activeClippingWithIdentifier(FloatcutOperator *operator, NSString *identifier)
{
    for (int index = 0; index < operator.jcListCount; index++) {
        FloatcutClipping *clipping = [operator getClippingFromIndex:index];
        if ([[clipping identifier] isEqualToString:identifier])
            return clipping;
    }
    return nil;
}

static void testClippingIdentityAndImages(void)
{
    FloatcutClipping *first = [[FloatcutClipping alloc] initWithContents:@"same"
                                                           withType:@"public.utf8-plain-text"
                                                  withDisplayLength:40
                                               withAppLocalizedName:@"Tests"
                                                   withAppBundleURL:nil
                                                      withTimestamp:1];
    FloatcutClipping *second = [[FloatcutClipping alloc] initWithContents:@"same"
                                                            withType:@"public.utf8-plain-text"
                                                   withDisplayLength:40
                                                withAppLocalizedName:@"Tests"
                                                    withAppBundleURL:nil
                                                       withTimestamp:2];
    FCAssert(first.identifier.length > 0, @"Clippings need a stable identifier");
    FCAssert(![first.identifier isEqualToString:second.identifier], @"New clippings need unique identifiers");
    FCAssert([first isEqual:second], @"Text equality must remain content-based");

    NSData *imageData = [@"image-payload" dataUsingEncoding:NSUTF8StringEncoding];
    FloatcutClipping *image = [[FloatcutClipping alloc] initWithContents:@""
                                                            withType:@"public.png"
                                                       withImageData:imageData
                                                   withDisplayLength:40
                                                withAppLocalizedName:@"Tests"
                                                    withAppBundleURL:nil
                                                       withTimestamp:3];
    FCAssert(image.isImage, @"Image payloads must still be detected");
    FCAssert([image.displayString isEqualToString:@"Image"], @"Image display text changed");

    [first release];
    [second release];
    [image release];
}

static void testStoreOrderSearchAndDuplicates(void)
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id previousRemoveDuplicates = [[defaults objectForKey:@"removeDuplicates"] retain];
    [defaults setBool:NO forKey:@"removeDuplicates"];

    FloatcutStore *store = [[FloatcutStore alloc] initRemembering:3 displaying:3 withDisplayLength:40];
    [store addClipping:@"one" ofType:@"text" fromAppLocalizedName:@"Tests" fromAppBundleURL:nil atTimestamp:1];
    [store addClipping:@"two" ofType:@"text" fromAppLocalizedName:@"Tests" fromAppBundleURL:nil atTimestamp:2];
    [store addClipping:@"three" ofType:@"text" fromAppLocalizedName:@"Tests" fromAppBundleURL:nil atTimestamp:3];
    [store addClipping:@"four" ofType:@"text" fromAppLocalizedName:@"Tests" fromAppBundleURL:nil atTimestamp:4];

    FCAssert(store.jcListCount == 3, @"Remember limit changed");
    FCAssert([[store clippingContentsAtPosition:0] isEqualToString:@"four"], @"Newest clipping must remain first");
    FCAssert([[store clippingContentsAtPosition:2] isEqualToString:@"two"], @"Oldest clipping was trimmed incorrectly");
    FCAssert([store clippingAtPosition:-1] == nil, @"Negative indexes must be rejected");

    NSArray *indexes = [store previousIndexes:2 containing:@"T"];
    FCAssert([indexes isEqualToArray:@[@1, @2]], @"Case-insensitive search order changed");
    NSArray *displayStrings = [store previousDisplayStrings:2 containing:@"T"];
    FCAssert([displayStrings isEqualToArray:@[@"three", @"two"]], @"Display search order changed");

    [defaults setBool:YES forKey:@"removeDuplicates"];
    [store addClipping:@"three" ofType:@"text" fromAppLocalizedName:@"Tests" fromAppBundleURL:nil atTimestamp:5];
    FCAssert(store.jcListCount == 3, @"Moving a duplicate must not grow the store");
    FCAssert([[store clippingContentsAtPosition:0] isEqualToString:@"three"], @"Duplicate must move to the top");

    if (previousRemoveDuplicates)
        [defaults setObject:previousRemoveDuplicates forKey:@"removeDuplicates"];
    else
        [defaults removeObjectForKey:@"removeDuplicates"];
    [previousRemoveDuplicates release];
    [store release];
}

static void testTextMergeSkipsImages(void)
{
    FloatcutStore *store = [[FloatcutStore alloc] initRemembering:10 displaying:10 withDisplayLength:80];
    [store addClipping:@"oldest text" ofType:@"text" fromAppLocalizedName:@"Tests" fromAppBundleURL:nil atTimestamp:1];

    NSData *imageData = [@"image-payload" dataUsingEncoding:NSUTF8StringEncoding];
    FloatcutClipping *image = [[FloatcutClipping alloc] initWithContents:@""
                                                            withType:@"public.png"
                                                       withImageData:imageData
                                                   withDisplayLength:80
                                                withAppLocalizedName:@"Tests"
                                                    withAppBundleURL:nil
                                                       withTimestamp:2];
    [store addClipping:image];
    [image release];
    [store addClipping:@"newest text" ofType:@"text" fromAppLocalizedName:@"Tests" fromAppBundleURL:nil atTimestamp:3];

    [store mergeList];
    FCAssert(store.jcListCount == 4, @"Text merge should add one clipping without removing source items");
    FCAssert([[store clippingContentsAtPosition:0] isEqualToString:@"oldest text\nnewest text"], @"Text merge must preserve chronological text order and skip images");
    FCAssert([[store clippingContentsAtPosition:0] rangeOfString:@"\n\n"].location == NSNotFound, @"Images must not create blank lines in merged text");

    FloatcutStore *imagesOnly = [[FloatcutStore alloc] initRemembering:10 displaying:10 withDisplayLength:80];
    image = [[FloatcutClipping alloc] initWithContents:@""
                                           withType:@"public.png"
                                      withImageData:imageData
                                  withDisplayLength:80
                               withAppLocalizedName:@"Tests"
                                   withAppBundleURL:nil
                                      withTimestamp:4];
    [imagesOnly addClipping:image];
    [image release];
    [imagesOnly mergeList];
    FCAssert(imagesOnly.jcListCount == 1, @"Merging an image-only store must be a no-op");

    [imagesOnly release];
    [store release];
}

static void testFavoriteStoreSwitchingAndTargetedClearing(void)
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id previousSavePreference = [[defaults objectForKey:@"savePreference"] retain];
    [defaults setInteger:0 forKey:@"savePreference"];

    FCNoopSaveTarget *saveTarget = [[FCNoopSaveTarget alloc] init];
    FloatcutOperator *operator = [[FloatcutOperator alloc] init];
    [operator awakeFromNibDisplaying:10
                   withDisplayLength:80
                    withSaveSelector:@selector(addPreferencesToDictionary:)
                            forTarget:saveTarget];

    [operator addClipping:@"standard survives"
                   ofType:@"text"
                   fromApp:@"Tests"
          withAppBundleURL:nil
                    target:nil
     clippingAddedSelector:NULL];
    NSString *standardIdentifier = [[[operator getClippingFromIndex:0] identifier] copy];

    [operator setFavoritesStoreSelected:YES];
    [operator addClipping:@"favorite survives"
                   ofType:@"text"
                   fromApp:@"Tests"
          withAppBundleURL:nil
                    target:nil
     clippingAddedSelector:NULL];
    NSString *favoriteIdentifier = [[[operator getClippingFromIndex:0] identifier] copy];

    [operator setFavoritesStoreSelected:NO];
    FCAssert(!operator.favoritesStoreIsSelected, @"Clipboard store selection failed");
    FCAssert(operator.jcListCount == 1, @"Switching stores changed the clipboard store");
    FCAssert([[[operator getClippingFromIndex:0] identifier] isEqualToString:standardIdentifier], @"Switching stores changed clipboard contents");

    [operator setFavoritesStoreSelected:YES];
    FCAssert(operator.favoritesStoreIsSelected, @"Favorite store selection failed");
    FCAssert(operator.jcListCount == 1, @"Switching stores changed the favorites store");
    FCAssert([[[operator getClippingFromIndex:0] identifier] isEqualToString:favoriteIdentifier], @"Switching stores changed favorite contents");

    [operator clearPrimaryList];
    FCAssert(operator.favoritesStoreIsSelected, @"Clearing the clipboard store must not switch the active store");
    FCAssert(operator.jcListCount == 1, @"Clearing the clipboard store must preserve favorites");
    FCAssert([[[operator getClippingFromIndex:0] identifier] isEqualToString:favoriteIdentifier], @"Clearing the clipboard store changed favorites");

    [operator setFavoritesStoreSelected:NO];
    FCAssert(operator.jcListCount == 0, @"Targeted clipboard clearing did not clear the clipboard store");
    [operator addClipping:@"new standard"
                   ofType:@"text"
                   fromApp:@"Tests"
          withAppBundleURL:nil
                    target:nil
     clippingAddedSelector:NULL];

    [operator clearFavoritesList];
    FCAssert(!operator.favoritesStoreIsSelected, @"Clearing favorites must not switch the active store");
    FCAssert(operator.jcListCount == 1, @"Clearing favorites must preserve the clipboard store");
    FCAssert([[[operator getClippingFromIndex:0] contents] isEqualToString:@"new standard"], @"Clearing favorites changed clipboard contents");
    [operator setFavoritesStoreSelected:YES];
    FCAssert(operator.jcListCount == 0, @"Targeted favorites clearing did not clear favorites");

    if (previousSavePreference)
        [defaults setObject:previousSavePreference forKey:@"savePreference"];
    else
        [defaults removeObjectForKey:@"savePreference"];

    [favoriteIdentifier release];
    [standardIdentifier release];
    [operator release];
    [saveTarget release];
    [previousSavePreference release];
}

static void testPerItemFavoriteActions(void)
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray *keys = @[@"store", @"savePreference", @"removeDuplicates", @"saveForgottenFavorites", @"rememberNum", @"favoritesRememberNum"];
    NSMutableDictionary *previousValues = [NSMutableDictionary dictionary];
    for (NSString *key in keys) {
        id value = [defaults objectForKey:key];
        if (value)
            [previousValues setObject:value forKey:key];
    }

    [defaults setObject:@{} forKey:@"store"];
    [defaults setInteger:0 forKey:@"savePreference"];
    [defaults setBool:NO forKey:@"removeDuplicates"];
    [defaults setBool:YES forKey:@"saveForgottenFavorites"];
    [defaults setInteger:20 forKey:@"rememberNum"];
    [defaults setInteger:20 forKey:@"favoritesRememberNum"];

    FCNoopSaveTarget *saveTarget = [[FCNoopSaveTarget alloc] init];
    FCTrackingOperator *operator = [[FCTrackingOperator alloc] init];
    [operator awakeFromNibDisplaying:20
                   withDisplayLength:80
                    withSaveSelector:@selector(addPreferencesToDictionary:)
                            forTarget:saveTarget];

    [operator addClipping:@"same text"
                   ofType:@"public.utf8-plain-text"
                   fromApp:@"First App"
          withAppBundleURL:@"file:///Applications/First.app"
                    target:nil
     clippingAddedSelector:NULL];
    NSString *firstIdentifier = [[[operator getClippingFromIndex:0] identifier] copy];
    [operator addClipping:@"separator"
                   ofType:@"public.utf8-plain-text"
                   fromApp:@"Tests"
          withAppBundleURL:nil
                    target:nil
     clippingAddedSelector:NULL];
    [operator addClipping:@"same text"
                   ofType:@"public.utf8-plain-text"
                   fromApp:@"Second App"
          withAppBundleURL:@"file:///Applications/Second.app"
                    target:nil
     clippingAddedSelector:NULL];
    NSString *secondIdentifier = [[[operator getClippingFromIndex:0] identifier] copy];
    NSArray *originalPrimaryOrder = [[activeStoreIdentifiers(operator) copy] autorelease];
	[defaults setBool:YES forKey:@"removeDuplicates"];

    FCAssert([operator toggleFavoriteForClippingWithIdentifier:firstIdentifier], @"A clipboard clipping should be favoritable by stable ID");
    FCAssert(!operator.favoritesStoreIsSelected, @"Favoriting must not switch the active store");
    FCAssert([activeStoreIdentifiers(operator) isEqualToArray:originalPrimaryOrder], @"Favoriting must not change clipboard count or order");
    FCAssert([operator isClippingFavoriteWithIdentifier:firstIdentifier], @"Favorited clipping was not found by stable ID");
    FCAssert(![operator isClippingFavoriteWithIdentifier:secondIdentifier], @"Equal text with a different stable ID must not be highlighted");

    FCAssert([operator toggleFavoriteForClippingWithIdentifier:secondIdentifier], @"Equal text with a distinct ID should be independently favoritable");
    FCAssert([[operator favoriteClippingIdentifiers] count] == 2, @"Identity-preserving favorites must not collapse equal text when duplicate removal is enabled");
    FCAssert([activeStoreIdentifiers(operator) isEqualToArray:originalPrimaryOrder], @"Adding a second favorite changed the clipboard list");

    FCAssert([operator toggleFavoriteForClippingWithIdentifier:firstIdentifier], @"A second action should remove only the matching favorite");
    FCAssert(![operator isClippingFavoriteWithIdentifier:firstIdentifier], @"The matching favorite was not removed");
    FCAssert([operator isClippingFavoriteWithIdentifier:secondIdentifier], @"Removing one favorite changed another equal-text favorite");
    FCAssert([activeStoreIdentifiers(operator) isEqualToArray:originalPrimaryOrder], @"Removing a favorite changed the clipboard list");
    FCAssert(operator.autosaveRequestCount == 0, @"Explicit favorite removal must not autosave a forgotten clipping");

    NSArray *primaryBeforeInvalidAction = [[activeStoreIdentifiers(operator) copy] autorelease];
    NSSet *favoritesBeforeInvalidAction = [[[operator favoriteClippingIdentifiers] copy] autorelease];
    FCAssert(![operator toggleFavoriteForClippingWithIdentifier:@"missing-id"], @"An unknown clipboard ID should be rejected");
    FCAssert(![operator moveFavoriteToPrimaryStoreWithIdentifier:@"missing-id"], @"An unknown favorite ID should be rejected");
    FCAssert([activeStoreIdentifiers(operator) isEqualToArray:primaryBeforeInvalidAction], @"A rejected action partially changed the clipboard store");
    FCAssert([[operator favoriteClippingIdentifiers] isEqualToSet:favoritesBeforeInvalidAction], @"A rejected action partially changed favorites");

    NSData *imageData = [@"favorite-image-payload" dataUsingEncoding:NSUTF8StringEncoding];
    FCAssert([operator addImageClippingData:imageData
                                    ofType:@"public.png"
                                   fromApp:@"Image App"
                          withAppBundleURL:@"file:///Applications/Image.app"
                                    target:nil
                     clippingAddedSelector:NULL], @"Image fixture could not be added");
    FloatcutClipping *imageClipping = [[operator getClippingFromIndex:0] retain];
    NSString *imageIdentifier = [[imageClipping identifier] copy];
    int primaryCountWithImage = operator.jcListCount;
    FCAssert([operator toggleFavoriteForClippingWithIdentifier:imageIdentifier], @"Image clipping should be favoritable");
    FCAssert(operator.jcListCount == primaryCountWithImage, @"Favoriting an image changed the clipboard count");

    [operator setFavoritesStoreSelected:YES];
    FCAssert(operator.favoritesStoreIsSelected, @"Favorite inspection unexpectedly changed the selected store");
    FloatcutClipping *favoriteImage = activeClippingWithIdentifier(operator, imageIdentifier);
    FCAssert(favoriteImage != nil, @"Favorited image is missing");
    FCAssert([[favoriteImage imageData] isEqualToData:[imageClipping imageData]], @"Favoriting changed image data");
    FCAssert([[favoriteImage type] isEqualToString:[imageClipping type]], @"Favoriting changed the pasteboard type");
    FCAssert([[favoriteImage appLocalizedName] isEqualToString:[imageClipping appLocalizedName]], @"Favoriting changed the source app");
    FCAssert([[favoriteImage appBundleURL] isEqualToString:[imageClipping appBundleURL]], @"Favoriting changed the source URL");
    FCAssert([favoriteImage timestamp] == [imageClipping timestamp], @"Favoriting changed the timestamp");
    FCAssert([[favoriteImage identifier] isEqualToString:imageIdentifier], @"Favoriting changed the stable ID");

    FCAssert([operator moveFavoriteToPrimaryStoreWithIdentifier:secondIdentifier], @"Trash action should remove a favorite and retain it in the clipboard store");
    FCAssert(operator.favoritesStoreIsSelected, @"Trash action must not switch away from favorites");
    FCAssert(![operator isClippingFavoriteWithIdentifier:secondIdentifier], @"Trash action did not remove the favorite");
    FCAssert(operator.autosaveRequestCount == 0, @"Trash action must not autosave the explicitly removed favorite");
    [operator setFavoritesStoreSelected:NO];
    FCAssert(operator.jcListCount == primaryCountWithImage, @"Restoring an existing clipboard clipping created a duplicate");
    FCAssert([[[operator getClippingFromIndex:0] identifier] isEqualToString:secondIdentifier], @"Existing clipboard clipping was not moved to the top");

    [operator setFavoritesStoreSelected:YES];
    [operator addClipping:@"favorite only"
                   ofType:@"public.utf8-plain-text"
                   fromApp:@"Favorite App"
          withAppBundleURL:@"file:///Applications/Favorite.app"
                    target:nil
     clippingAddedSelector:NULL];
    FloatcutClipping *favoriteOnly = [[operator getClippingFromIndex:0] retain];
    NSString *favoriteOnlyIdentifier = [[favoriteOnly identifier] copy];
    int favoritesBeforeMove = operator.jcListCount;
    FCAssert([operator moveFavoriteToPrimaryStoreWithIdentifier:favoriteOnlyIdentifier], @"Favorite-only clipping should move to the clipboard store");
    FCAssert(operator.favoritesStoreIsSelected, @"Moving a favorite must preserve the active store");
    FCAssert(operator.jcListCount == favoritesBeforeMove - 1, @"Moved favorite was not removed from favorites");
    [operator setFavoritesStoreSelected:NO];
    FloatcutClipping *restored = [operator getClippingFromIndex:0];
    FCAssert([[restored identifier] isEqualToString:favoriteOnlyIdentifier], @"Moved clipping did not keep its stable ID");
    FCAssert([[restored contents] isEqualToString:[favoriteOnly contents]], @"Moved clipping changed its text");
    FCAssert([[restored type] isEqualToString:[favoriteOnly type]], @"Moved clipping changed its type");
    FCAssert([[restored appLocalizedName] isEqualToString:[favoriteOnly appLocalizedName]], @"Moved clipping changed its source app");
    FCAssert([[restored appBundleURL] isEqualToString:[favoriteOnly appBundleURL]], @"Moved clipping changed its source URL");
    FCAssert([restored timestamp] == [favoriteOnly timestamp], @"Moved clipping changed its timestamp");

    FCAssert([operator isClippingFavoriteWithIdentifier:imageIdentifier], @"Image favorite should remain available for persistence");
    [operator saveEngine];
    NSDictionary *savedStore = [defaults dictionaryForKey:@"store"];
    NSArray *savedPrimary = [savedStore objectForKey:@"jcList"];
    NSArray *savedFavorites = [savedStore objectForKey:@"favoritesList"];
    NSPredicate *imageIDPredicate = [NSPredicate predicateWithFormat:@"Identifier == %@", imageIdentifier];
    FCAssert([[savedPrimary filteredArrayUsingPredicate:imageIDPredicate] count] == 1, @"Persistence lost the clipboard side of a favorited image");
    FCAssert([[savedFavorites filteredArrayUsingPredicate:imageIDPredicate] count] == 1, @"Persistence lost the favorite side of a favorited image");

    [defaults setInteger:1 forKey:@"savePreference"];
    FloatcutOperator *reader = [[FloatcutOperator alloc] init];
    [reader awakeFromNibDisplaying:20
                withDisplayLength:80
                 withSaveSelector:@selector(addPreferencesToDictionary:)
                         forTarget:saveTarget];
    FCAssert([activeClippingWithIdentifier(reader, imageIdentifier) isImage], @"Persistence round-trip lost clipboard image data");
    FCAssert([reader isClippingFavoriteWithIdentifier:imageIdentifier], @"Persistence round-trip lost stable favorite association");

    for (NSString *key in keys) {
        id previousValue = [previousValues objectForKey:key];
        if (previousValue)
            [defaults setObject:previousValue forKey:key];
        else
            [defaults removeObjectForKey:key];
    }

    [reader release];
    [favoriteOnlyIdentifier release];
    [favoriteOnly release];
    [imageIdentifier release];
    [imageClipping release];
    [secondIdentifier release];
    [firstIdentifier release];
    [operator release];
    [saveTarget release];
}

static void runSearchBenchmark(void)
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id previousRemoveDuplicates = [[defaults objectForKey:@"removeDuplicates"] retain];
    [defaults setBool:NO forKey:@"removeDuplicates"];

    const int itemCount = 2000;
    FloatcutStore *store = [[FloatcutStore alloc] initRemembering:itemCount displaying:20 withDisplayLength:80];
    for (int index = 0; index < itemCount; index++) {
        NSString *contents = [NSString stringWithFormat:@"benchmark item %d %@", index, index % 197 == 0 ? @"needle" : @"haystack"];
        [store addClipping:contents ofType:@"text" fromAppLocalizedName:@"Benchmark" fromAppBundleURL:nil atTimestamp:index];
    }

    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    NSArray *results = [store previousIndexes:20 containing:@"needle"];
    CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - start;
    FCAssert(results.count > 0, @"Benchmark search returned no results");
    NSLog(@"Search benchmark: %d items in %.3f ms", itemCount, elapsed * 1000.0);

    if (previousRemoveDuplicates)
        [defaults setObject:previousRemoveDuplicates forKey:@"removeDuplicates"];
    else
        [defaults removeObjectForKey:@"removeDuplicates"];
    [previousRemoveDuplicates release];
    [store release];
}

static void testPersistenceRoundTrip(void)
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id previousStore = [[defaults objectForKey:@"store"] retain];
    id previousSavePreference = [[defaults objectForKey:@"savePreference"] retain];
    [defaults setObject:@{} forKey:@"store"];
    [defaults setInteger:0 forKey:@"savePreference"];

    FCNoopSaveTarget *saveTarget = [[FCNoopSaveTarget alloc] init];
    FloatcutOperator *writer = [[FloatcutOperator alloc] init];
    [writer awakeFromNibDisplaying:10
                withDisplayLength:40
                 withSaveSelector:@selector(addPreferencesToDictionary:)
                         forTarget:saveTarget];
    [writer addClipping:@"persisted text"
                 ofType:@"text"
                 fromApp:@"Tests"
        withAppBundleURL:nil
                  target:nil
   clippingAddedSelector:NULL];
    NSString *originalIdentifier = [[[writer getClippingFromIndex:0] identifier] copy];
    [writer saveEngine];

    NSDictionary *savedStore = [defaults dictionaryForKey:@"store"];
    NSString *savedIdentifier = [[savedStore[@"jcList"] firstObject] objectForKey:@"Identifier"];
    FCAssert([savedIdentifier isEqualToString:originalIdentifier], @"Persistence must include the stable clipping identifier");

    [defaults setInteger:1 forKey:@"savePreference"];
    FloatcutOperator *reader = [[FloatcutOperator alloc] init];
    [reader awakeFromNibDisplaying:10
                withDisplayLength:40
                 withSaveSelector:@selector(addPreferencesToDictionary:)
                         forTarget:saveTarget];
    FCAssert([[[reader getClippingFromIndex:0] identifier] isEqualToString:originalIdentifier], @"Persistence must restore the clipping identifier");
    FCAssert([[[reader getClippingFromIndex:0] contents] isEqualToString:@"persisted text"], @"Persistence changed clipping contents");

    if (previousStore)
        [defaults setObject:previousStore forKey:@"store"];
    else
        [defaults removeObjectForKey:@"store"];
    if (previousSavePreference)
        [defaults setObject:previousSavePreference forKey:@"savePreference"];
    else
        [defaults removeObjectForKey:@"savePreference"];
    [defaults synchronize];

    [originalIdentifier release];
    [reader release];
    [writer release];
    [saveTarget release];
    [previousStore release];
    [previousSavePreference release];
}

int main(void)
{
    @autoreleasepool {
        testClippingIdentityAndImages();
        testStoreOrderSearchAndDuplicates();
        testTextMergeSkipsImages();
        testFavoriteStoreSwitchingAndTargetedClearing();
        testPerItemFavoriteActions();
        testPersistenceRoundTrip();
        runSearchBenchmark();
        NSLog(@"All Floatcut engine regression tests passed");
    }
    return 0;
}
