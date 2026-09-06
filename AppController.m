//
//  AppController.m
//  Floatcut
//
//  Flycut by Gennadiy Potapov and contributors. Based on Jumpcut by Steve Cook.
//  Copyright 2011 General Arcade. All rights reserved.
//
//  This code is open-source software subject to the MIT License; see the homepage
//  at <https://github.com/TermiT/Flycut> for details.
//

// AppController owns and interacts with the FloatcutOperator, providing a user
// interface and platform-specific mechanisms.

#import "AppController.h"
#import "FloatcutLocalization.h"
#import "SGHotKey.h"
#import "SGHotKeyCenter.h"
#import "SRRecorderCell.h"
#import "NSWindow+TrueCenter.h"
#import "NSWindow+ULIZoomEffect.h"
#import <ApplicationServices/ApplicationServices.h>
#import <CoreFoundation/CoreFoundation.h>
#import <ServiceManagement/ServiceManagement.h>
#import "Floatcut-Swift.h"

// Custom search window that handles Cmd-W properly
@interface SearchWindow : NSWindow
@property (weak) AppController *appController;
@end

@implementation SearchWindow

- (void)performClose:(id)sender {
    if (self.appController) {
        [self.appController hideSearchWindow];
    }
}

- (BOOL)performKeyEquivalent:(NSEvent *)theEvent {
    // Handle Cmd-W specifically
    if ([theEvent type] == NSEventTypeKeyDown) {
        NSString *characters = [theEvent charactersIgnoringModifiers];
        NSUInteger modifierFlags = [theEvent modifierFlags];
        
        if ([characters isEqualToString:@"w"] && (modifierFlags & NSEventModifierFlagCommand)) {
            [self performClose:nil];
            return YES;
        }
    }
    
    return [super performKeyEquivalent:theEvent];
}

@end

@interface AppController () <FloatcutSearchWindowControllerDelegate, FloatcutPreferencesWindowControllerDelegate, FloatcutStatusPopoverControllerDelegate, FloatcutSyncClipboardDelegate>

- (void)applyLocalization;
- (void)localizeMenu:(NSMenu *)menu;
- (void)localizeMenuItem:(NSMenuItem *)item;
- (void)localizeView:(NSView *)view;
- (void)localizeWindow:(NSWindow *)window;
- (BOOL)isOptionKeyPressedForEvent:(NSEvent *)event;
- (NSArray<NSDictionary *> *)displayItemsMatchingSearch:(NSString *)search;
- (NSImage *)previewImageForClipping:(FloatcutClipping *)clipping size:(CGFloat)size;
- (void)addClippingToPasteboard:(FloatcutClipping *)clipping;
- (BOOL)pasteResolvedStoreIndex:(int)storeIndex refreshUI:(BOOL)refreshUI;
- (BOOL)pasteIndex:(int)position refreshUI:(BOOL)refreshUI;
- (void)updateSearchResultsForSearch:(NSString *)search;
- (void)toggleStatusPopover:(id)sender;
- (void)presentSaveLocationPanelForAutoSave:(BOOL)autoSave;
- (void)prewarmStatusPopoverIfNeeded;
- (void)refreshStatusItemsContaining:(NSString *)search;
- (void)clearFavoritesStore:(BOOL)clearFavorites statusPopoverController:(FloatcutStatusPopoverController *)controller;
- (void)rememberPotentialPasteTargetApplication:(NSRunningApplication *)application;
- (void)workspaceDidActivateApplication:(NSNotification *)notification;
- (void)restorePasteTargetApplication;
- (void)pasteIntoRememberedTargetApplication;
- (NSImage *)menuIconImageWithBaseName:(NSString *)baseName;
- (void)showLegacyApplicationRunningWarningIfNeeded;
- (void)showPendingMigrationSuccessIfNeeded;
- (BOOL)consumeBlockedPasteboardChangeCount:(NSInteger)changeCount;
@property (nonatomic, retain) FloatcutSearchWindowController *swiftSearchWindowController;
@property (nonatomic, retain) FloatcutPreferencesWindowController *swiftPreferencesWindowController;
@property (nonatomic, retain) FloatcutStatusPopoverController *statusPopoverController;
@property (nonatomic, assign) BOOL preserveStatusPopoverSearchOnNextMenuUpdate;

@end

@implementation AppController

@synthesize swiftSearchWindowController = _swiftSearchWindowController;
@synthesize swiftPreferencesWindowController = _swiftPreferencesWindowController;
@synthesize statusPopoverController = _statusPopoverController;


- (id)init
{
	[[NSUserDefaults standardUserDefaults] registerDefaults:[NSDictionary dictionaryWithObjectsAndKeys:
		[NSDictionary dictionaryWithObjects:[NSArray arrayWithObjects:[NSNumber numberWithInt:9],[NSNumber numberWithLong:1179648],nil] forKeys:[NSArray arrayWithObjects:@"keyCode",@"modifierFlags",nil]],
		@"ShortcutRecorder mainHotkey",
		[NSDictionary dictionaryWithObjects:[NSArray arrayWithObjects:[NSNumber numberWithInt:1],[NSNumber numberWithLong:1179648|NSEventModifierFlagShift],nil] forKeys:[NSArray arrayWithObjects:@"keyCode",@"modifierFlags",nil]],
		@"ShortcutRecorder searchHotkey",
		[NSNumber numberWithInt:10],
		@"displayNum",
		[NSNumber numberWithInt:40],
		@"displayLen",
		[NSNumber numberWithInt:0],
		@"menuIcon",
		[NSNumber numberWithFloat:.25],
		@"bezelAlpha",
		[NSNumber numberWithBool:NO],
		@"stickyBezel",
		[NSNumber numberWithBool:NO],
		@"wraparoundBezel",
		[NSNumber numberWithBool:NO],// No by default
		@"loadOnStartup",
		[NSNumber numberWithBool:YES], 
		@"menuSelectionPastes",
        // Floatcut-specific options
        [NSNumber numberWithFloat:500.0],
        @"bezelWidth",
        [NSNumber numberWithFloat:320.0],
        @"bezelHeight",
        [NSNumber numberWithBool:NO],
        @"popUpAnimation",
        [NSNumber numberWithBool:YES],
        @"displayClippingSource",
        [NSNumber numberWithBool:NO],
        @"saveForgottenClippings",
        [NSNumber numberWithBool:YES],
        @"saveForgottenFavorites",
        [NSNumber numberWithBool:NO],
        @"suppressAccessibilityAlert",
        nil]];

	// Initialize search window pointers to nil
	searchWindow = nil;
	searchWindowSearchField = nil;
	searchWindowTableView = nil;
	searchResults = nil;
	isSearchWindowDisplayed = NO;

	return [super init];
}

- (void)openAccessibilitySettings {
    NSString *urlString;
    NSOperatingSystemVersion ver = [[NSProcessInfo processInfo] operatingSystemVersion];
    if (ver.majorVersion >= 13) {
        urlString = @"x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility";
    } else {
        urlString = @"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility";
    }
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:urlString]];
}

- (void)requestAccessibilityWithPrompt {
    // This method WILL trigger the system prompt if permissions are not granted
    NSLog(@"[Accessibility] User requested system prompt for accessibility permissions");
    
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    
    NSDictionary* options = @{(id) (kAXTrustedCheckOptionPrompt): @YES};
    BOOL trusted = AXIsProcessTrustedWithOptions((CFDictionaryRef) (options));
    
    NSLog(@"[Accessibility] After prompt request - Bundle: %@, ID: %@, Trusted: %@", 
          bundlePath, bundleID, trusted ? @"YES" : @"NO");
    
    if (!trusted) {
        // Give the system a moment to show the prompt, then open settings
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self openAccessibilitySettings];
        });
    }
}

- (void)showAccessibilityAlert {
    BOOL suppressAlert = [[NSUserDefaults standardUserDefaults] boolForKey:@"suppressAccessibilityAlert"];
    NSDictionary* options = @{(id) (kAXTrustedCheckOptionPrompt): @NO};
    BOOL trusted = AXIsProcessTrustedWithOptions((CFDictionaryRef) (options));
    
    // Log context for diagnostics
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    NSLog(@"[Accessibility] Alert check - Bundle: %@, ID: %@, Trusted: %@, Suppressed: %@", 
          bundlePath, bundleID, trusted ? @"YES" : @"NO", suppressAlert ? @"YES" : @"NO");
    
    if (!suppressAlert && &AXIsProcessTrustedWithOptions != NULL && !trusted) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:FCLocalizedString(@"Floatcut")];
        [alert setInformativeText:FCLocalizedString(@"For correct functioning of the app please tick Floatcut in Accessibility apps list.\n\nIf Floatcut is already listed but paste doesn't work, remove it from the list, then add it again and restart Floatcut.")];
        [alert addButtonWithTitle:FCLocalizedString(@"Open Settings")];
        [alert addButtonWithTitle:FCLocalizedString(@"Request System Prompt")];
        alert.showsSuppressionButton = YES;
        NSModalResponse response = [alert runModal];
        
        if (alert.suppressionButton.state == NSControlStateValueOn) {
            [[NSUserDefaults standardUserDefaults] setValue:[NSNumber numberWithBool:YES]
                                                     forKey:@"suppressAccessibilityAlert"];
        }
        [alert release];
        
        if (response == NSAlertFirstButtonReturn) {
            [self openAccessibilitySettings];
        } else if (response == NSAlertSecondButtonReturn) {
            [self requestAccessibilityWithPrompt];
        }
    }
}





- (void)awakeFromNib
{
	// Log startup diagnostics for accessibility troubleshooting
	NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
	NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
	NSDictionary* options = @{(id) (kAXTrustedCheckOptionPrompt): @NO};
	BOOL initialTrustState = AXIsProcessTrustedWithOptions((CFDictionaryRef) (options));
	
	NSLog(@"[Floatcut Startup] Bundle Path: %@", bundlePath);
	NSLog(@"[Floatcut Startup] Bundle ID: %@", bundleID);
	NSLog(@"[Floatcut Startup] Initial Accessibility Trust State: %@", initialTrustState ? @"TRUSTED" : @"NOT TRUSTED");

    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                           selector:@selector(workspaceDidActivateApplication:)
                                                               name:NSWorkspaceDidActivateApplicationNotification
                                                             object:nil];
    [self rememberPotentialPasteTargetApplication:[[NSWorkspace sharedWorkspace] frontmostApplication]];
	
	[self buildAppearancesPreferencePanel];
    [self applyLocalization];

	// We no longer get autosave from ShortcutRecorder, so let's set the recorder by hand
	if ( [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"ShortcutRecorder mainHotkey"] ) {
		[mainRecorder setKeyCombo:SRMakeKeyCombo([[[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"ShortcutRecorder mainHotkey"] objectForKey:@"keyCode"] intValue],
												 [[[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"ShortcutRecorder mainHotkey"] objectForKey:@"modifierFlags"] intValue] )
		];
	};

	// Set up search hotkey recorder
	if ( [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"ShortcutRecorder searchHotkey"] && searchRecorder ) {
		[searchRecorder setKeyCombo:SRMakeKeyCombo([[[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"ShortcutRecorder searchHotkey"] objectForKey:@"keyCode"] intValue],
												   [[[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"ShortcutRecorder searchHotkey"] objectForKey:@"modifierFlags"] intValue] )
		];
	};

	// Initialize the FloatcutOperator
	flycutOperator = [[FloatcutOperator alloc] init];
	flycutOperator.delegate = self;
	[flycutOperator setClippingsStoreDelegate:self];
	[flycutOperator setFavoritesStoreDelegate:self];
	[flycutOperator awakeFromNibDisplaying:[[NSUserDefaults standardUserDefaults] integerForKey:@"displayNum"]
						 withDisplayLength:[[NSUserDefaults standardUserDefaults] integerForKey:@"displayLen"]
						  withSaveSelector:@selector(savePreferencesOnDict:)
								 forTarget:self];

    [bezel setColor:NO];
    
	// Set up the bezel window
	[self setupBezel:nil];

	// Set up the bezel date formatter
	dateFormat = [[NSDateFormatter alloc] init];
    dateFormat.locale = [NSLocale autoupdatingCurrentLocale];
    // Long style keeps the localized date but omits the weekday included by Full style.
    dateFormat.dateStyle = NSDateFormatterLongStyle;
    dateFormat.timeStyle = NSDateFormatterShortStyle;

    // The list uses localized abbreviated month names while preserving the
    // user's date order and 12/24-hour clock preference.
    listDateFormat = [[NSDateFormatter alloc] init];
    listDateFormat.locale = [NSLocale autoupdatingCurrentLocale];
    [listDateFormat setLocalizedDateFormatFromTemplate:@"d MMM y jm"];

	// Create our pasteboard interface
    jcPasteboard = [NSPasteboard generalPasteboard];
    [jcPasteboard declareTypes:[NSArray arrayWithObject:NSPasteboardTypeString] owner:nil];
    pbCount = [jcPasteboard changeCount];

	// Build the statusbar menu
    statusItem = [[[NSStatusBar systemStatusBar]
            statusItemWithLength:NSVariableStatusItemLength] retain];
    [statusItem setHighlightMode:YES];
    [self switchMenuIconTo: [[NSUserDefaults standardUserDefaults] integerForKey:@"menuIcon"]];
	[statusItem setMenu:nil];
    [statusItem.button setTarget:self];
    [statusItem.button setAction:@selector(toggleStatusPopover:)];
    [jcMenu setDelegate:self];
    jcMenuBaseItemsCount = [[[[jcMenu itemArray] reverseObjectEnumerator] allObjects] count];
    [statusItem setEnabled:YES];
    [self performSelector:@selector(prewarmStatusPopoverIfNeeded) withObject:nil afterDelay:0.0];

    // If our preferences indicate that we are saving, we may have loaded the dictionary from the
    // saved plist and should update the menu.
	if ( [[NSUserDefaults standardUserDefaults] integerForKey:@"savePreference"] >= 1 ) {
        [self updateMenu];
	}

	// Build our listener timer
	NSDate *oneSecondFromNow = [NSDate dateWithTimeIntervalSinceNow:1.0];
	pollPBTimer = [[NSTimer alloc] initWithFireDate:oneSecondFromNow
										   interval:(1.0)
											 target:self
										   selector:@selector(pollPB:)
										   userInfo:nil
											repeats:YES];
	// Assign it to NSRunLoopCommonModes so that it will still poll while the menu is open.  Using a simple NSTimer scheduledTimerWithTimeInterval: would result in polling that stops while the menu is active.  In the past this was okay but with Universal Clipboard a new clipping an arrive while the user has the menu open.
	[[NSRunLoop currentRunLoop] addTimer:pollPBTimer forMode:NSRunLoopCommonModes];

    // Finish up
	srTransformer = [[[SRKeyCodeTransformer alloc] init] retain];
    pbBlockCount = 0;
    pbBlockedChangeCounts = [[NSMutableOrderedSet alloc] init];
    [FloatcutSyncCoordinator shared].clipboardDelegate = self;
    [[FloatcutSyncCoordinator shared] startIfEnabled];
    [pollPBTimer fire];
    
    
    // Check if the app is registered as a login item
    SMAppService *loginItem = [SMAppService mainAppService];
    BOOL isEnabled = (loginItem.status == SMAppServiceStatusEnabled);
    [[NSUserDefaults standardUserDefaults] setValue:[NSNumber numberWithBool:isEnabled]
                                             forKey:@"loadOnStartup"];

    [NSApp activateIgnoringOtherApps: YES];
    
    // Check if the app has Accessibility permission
    [self showAccessibilityAlert];
}

-(void)savePreferencesOnDict:(NSMutableDictionary *)saveDict
{
	[saveDict setObject:[NSNumber numberWithInt:[[NSUserDefaults standardUserDefaults] integerForKey:@"displayLen"]]
				 forKey:@"displayLen"];
	[saveDict setObject:[NSNumber numberWithInt:[[NSUserDefaults standardUserDefaults] integerForKey:@"displayNum"]]
				 forKey:@"displayNum"];
}

-(void)menuWillOpen:(NSMenu *)menu
{
    NSEvent *event = [NSApp currentEvent];
    if ([self isOptionKeyPressedForEvent:event]) {
        [menu cancelTracking];
        bool disableStore = [self toggleMenuIconDisabled];
        if (!disableStore)
        {
            // Update the pbCount so we don't enable and have it immediately copy the thing the user was trying to avoid.
            // Code copied from pollPB, which is disabled at this point, so the "should be okay" should still be okay.

            // Reload pbCount with the current changeCount
            // Probably poor coding technique, but pollPB should be the only thing messing with pbCount, so it should be okay
            pbCount = [jcPasteboard changeCount];
        }
        [flycutOperator setDisableStoreTo:disableStore];
    }
    // Note: Removed the search box activation code. The search box in the menu is for manual use only.
    // Users should use the dedicated search window (cmd-shift-s) for keyboard-driven search.
}

-(void)menuDidClose:(NSMenu *)menu
{
    // Menu closed - no special handling needed now that we removed search box activation
}

-(void)toggleStatusPopover:(id)sender
{
    NSEvent *event = [NSApp currentEvent];
    if ([self isOptionKeyPressedForEvent:event]) {
        bool disableStore = [self toggleMenuIconDisabled];
        if (!disableStore) {
			pbCount = [jcPasteboard changeCount];
        }
        [flycutOperator setDisableStoreTo:disableStore];
        [self.statusPopoverController closePopover];
        statusItem.button.state = NSControlStateValueOff;
        return;
    }

    if (!self.statusPopoverController) {
        self.statusPopoverController = [[[FloatcutStatusPopoverController alloc] init] autorelease];
        self.statusPopoverController.bridgeDelegate = self;
    }

    NSStatusBarButton *button = statusItem.button;
    if (button) {
		if (!self.statusPopoverController.isShown) {
			[self.statusPopoverController resetSearch];
			[self.statusPopoverController setFavoritesStoreActive:[flycutOperator favoritesStoreIsSelected]];
			[self refreshStatusItemsContaining:nil];
		}
        NSRect anchorRect = button.bounds;
        if (event.window == button.window) {
            NSPoint clickPoint = [button convertPoint:event.locationInWindow fromView:nil];
            if (NSPointInRect(clickPoint, button.bounds)) {
                anchorRect = NSMakeRect(clickPoint.x - 0.5, NSMinY(button.bounds), 1.0, NSHeight(button.bounds));
            }
        }
        [self.statusPopoverController toggleWithRelativeTo:anchorRect of:button];
        button.state = self.statusPopoverController.isShown ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

-(bool)toggleMenuIconDisabled
{
    // Toggles the "disabled" look of the menu icon.  Returns if the icon looks disabled or not, allowing the caller to decide if anything is actually being disabled or if they just wanted the icon to be a status display.
    if (nil == statusItemText)
    {
        statusItemText = statusItem.button.title;
        statusItemImage = statusItem.button.image;
        statusItem.button.title = @"";
        statusItem.button.image = [self menuIconImageWithBaseName:@"de.meierkarsten.floatcut.xout"];
        return true;
    }
    else
    {
        statusItem.button.title = statusItemText;
        statusItem.button.image = statusItemImage;
        statusItemText = nil;
        statusItemImage = nil;
    }
    return false;
}

- (BOOL)isOptionKeyPressedForEvent:(NSEvent *)event
{
    NSEventModifierFlags eventFlags = [event modifierFlags];
    if (eventFlags & NSEventModifierFlagOption)
        return YES;

    CGEventFlags currentFlags = CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
    return (currentFlags & kCGEventFlagMaskAlternate) != 0;
}

- (void)prewarmStatusPopoverIfNeeded
{
    if (self.statusPopoverController)
        return;

    self.statusPopoverController = [[[FloatcutStatusPopoverController alloc] init] autorelease];
    self.statusPopoverController.bridgeDelegate = self;
}

- (void)reopenMenu
{
    [NSApp sendEvent:menuOpenEvent];
    [menuOpenEvent release];
    menuOpenEvent = nil;
}

- (void)activateSearchBox
{
    menuFirstResponder = [[searchBox window] firstResponder]; // So we can return control to normal menu function if the user presses an arrow key.
    [[searchBox window] makeFirstResponder:searchBox]; // So the search box works.
}

-(IBAction) activateAndOrderFrontStandardAboutPanel:(id)sender
{
    [currentRunningApplication release];
    currentRunningApplication = nil; // So it doesn't get pulled foreground atop the about panel.
    [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];

    if (aboutPanel == nil) {
        NSRect contentRect = NSMakeRect(0, 0, 620, 230);
        aboutPanel = [[NSPanel alloc] initWithContentRect:contentRect
                                                 styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
        [aboutPanel setTitle:FCLocalizedString(@"About Floatcut")];
        [aboutPanel setReleasedWhenClosed:NO];
        [aboutPanel setHidesOnDeactivate:NO];

        NSView *contentView = [aboutPanel contentView];
        NSImageView *iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(30, 90, 92, 92)];
        [iconView setImage:[[NSApplication sharedApplication] applicationIconImage]];
        [iconView setImageScaling:NSImageScaleProportionallyUpOrDown];
        [contentView addSubview:iconView];
        [iconView release];

        NSTextField *nameLabel = [NSTextField labelWithString:@"Floatcut"];
        [nameLabel setFrame:NSMakeRect(145, 166, 180, 32)];
        [nameLabel setFont:[NSFont systemFontOfSize:25 weight:NSFontWeightSemibold]];
        [contentView addSubview:nameLabel];

        NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
        NSTextField *versionLabel = [NSTextField labelWithString:version];
        [versionLabel setFrame:NSMakeRect(260, 174, 110, 20)];
        [versionLabel setFont:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium]];
        [versionLabel setTextColor:[NSColor secondaryLabelColor]];
        [contentView addSubview:versionLabel];

        // This slogan deliberately remains English in every app localization.
        NSTextField *sloganLabel = [NSTextField labelWithString:@"Don't jump, don't fly, just float"];
        [sloganLabel setFrame:NSMakeRect(145, 123, 440, 24)];
        NSFont *sloganFont = [[NSFontManager sharedFontManager]
            convertFont:[NSFont systemFontOfSize:16]
            toHaveTrait:NSFontItalicTrait];
        [sloganLabel setFont:sloganFont ?: [NSFont systemFontOfSize:16]];
        [sloganLabel setTextColor:[NSColor secondaryLabelColor]];
        [contentView addSubview:sloganLabel];

        NSString *copyright = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSHumanReadableCopyright"] ?: @"";
        NSTextField *copyrightLabel = [NSTextField labelWithString:copyright];
        [copyrightLabel setFrame:NSMakeRect(145, 47, 445, 56)];
        [copyrightLabel setFont:[NSFont systemFontOfSize:12]];
        [copyrightLabel setTextColor:[NSColor secondaryLabelColor]];
        [copyrightLabel setMaximumNumberOfLines:3];
        [copyrightLabel setLineBreakMode:NSLineBreakByWordWrapping];
        [contentView addSubview:copyrightLabel];
    }

    [aboutPanel center];
    [aboutPanel makeKeyAndOrderFront:sender];
}

-(IBAction) setBezelAlpha:(id)sender
{
	// In a masterpiece of poorly-considered design--because I want to eventually 
	// allow users to select from a variety of bezels--I've decided to create the
	// bezel programatically, meaning that I have to go through AppController as
	// a cutout to allow the user interface to interact w/the bezel.
	[bezel setAlpha:[sender floatValue]];
}

-(IBAction) setBezelWidth:(id)sender
{
    NSSize bezelSize = NSMakeSize([sender floatValue], bezel.frame.size.height);
	NSRect windowFrame = NSMakeRect( 0, 0, bezelSize.width, bezelSize.height);
	
	// Defer frame update to avoid layout recursion during preference changes
	dispatch_async(dispatch_get_main_queue(), ^{
		[bezel setFrame:windowFrame display:NO];
		[bezel trueCenter];
	});
}

-(IBAction) setBezelHeight:(id)sender
{
    NSSize bezelSize = NSMakeSize(bezel.frame.size.width, [sender floatValue]);
	NSRect windowFrame = NSMakeRect( 0, 0, bezelSize.width, bezelSize.height);
	
	// Defer frame update to avoid layout recursion during preference changes
	dispatch_async(dispatch_get_main_queue(), ^{
		[bezel setFrame:windowFrame display:NO];
		[bezel trueCenter];
	});
}

-(IBAction) setupBezel:(id)sender
{
	BOOL showSource = [[NSUserDefaults standardUserDefaults] boolForKey:@"displayClippingSource"];
	if (bezel) {
		[bezel setShowSource:showSource];
		if (isBezelDisplayed)
			[self updateBezel];
		return;
	}

    NSRect windowFrame = NSMakeRect(0, 0,
                                    [[NSUserDefaults standardUserDefaults] floatForKey:@"bezelWidth"],
                                    [[NSUserDefaults standardUserDefaults] floatForKey:@"bezelHeight"]);
    bezel = [[BezelWindow alloc] initWithContentRect:windowFrame
                                           styleMask:NSWindowStyleMaskBorderless
                                             backing:NSBackingStoreBuffered
                                               defer:NO
                                          showSource:showSource];

    [bezel trueCenter];
    [bezel setDelegate:self];
}

-(IBAction) switchMenuIcon:(id)sender
{
    [self switchMenuIconTo: [sender indexOfSelectedItem]];
}

-(void) switchMenuIconTo:(int)number
{
    if (number == 1 ) {
        statusItem.button.title = @"";
        statusItem.button.image = [self menuIconImageWithBaseName:@"de.meierkarsten.floatcut.black"];
    } else if (number == 2 ) {
        statusItem.button.image = nil;
        statusItem.button.title = [NSString stringWithFormat:@"%C",0x2704];
    } else if ( number == 3 ) {
        statusItem.button.image = nil;
        statusItem.button.title = [NSString stringWithFormat:@"%C",0x2702];
    } else {
        statusItem.button.title = @"";
        statusItem.button.image = [self menuIconImageWithBaseName:@"de.meierkarsten.floatcut"];
    }
}

-(NSImage *)menuIconImageWithBaseName:(NSString *)baseName
{
    NSSize logicalSize = NSMakeSize(16.0, 16.0);
    NSImage *combinedImage = [[[NSImage alloc] initWithSize:logicalSize] autorelease];
    NSArray<NSString *> *filenames = @[
        [baseName stringByAppendingString:@".16.png"],
        [baseName stringByAppendingString:@".32.png"]
    ];

    for (NSString *filename in filenames) {
        NSImage *sourceImage = [NSImage imageNamed:filename];
        for (NSImageRep *sourceRepresentation in sourceImage.representations) {
            NSImageRep *representation = [sourceRepresentation copy];
            representation.size = logicalSize;
            [combinedImage addRepresentation:representation];
            [representation release];
        }
    }

    combinedImage.template = [baseName hasSuffix:@".black"];

    return combinedImage;
}

-(NSDictionary*) checkPreferencesChanges:(NSDictionary*)changes
{
	if ( [changes valueForKey:@"rememberNum"] )
		[self checkRememberNumPref:[[NSUserDefaults standardUserDefaults] integerForKey:@"rememberNum"]
				   forPrimaryStore:YES];
	if ( [changes valueForKey:@"favoritesRememberNum"] )
		[self checkFavoritesRememberNumPref:[[NSUserDefaults standardUserDefaults] integerForKey:@"favoritesRememberNum"]];
	return nil;
}

-(IBAction) setRememberNumPref:(id)sender
{
	[self checkRememberNumPref:[sender intValue] forPrimaryStore:YES];
}

-(int) checkRememberNumPref:(int)newRemember forPrimaryStore:(BOOL) isPrimaryStore
{
	int oldRemember = [flycutOperator rememberNum];
	int setRemember = [flycutOperator setRememberNum:newRemember forPrimaryStore:YES];

	if ( isPrimaryStore )
	{
		if ( setRemember == oldRemember )
		{
			[self updateMenu];
		}
		else if ( setRemember < oldRemember )
		{
			// Trim down the number displayed in the menu if it is greater than the new
			// number to remember.
			if ( isPrimaryStore ) {
				if ( setRemember < [[NSUserDefaults standardUserDefaults] integerForKey:@"displayNum"] ) {
					[[NSUserDefaults standardUserDefaults] setValue:[NSNumber numberWithInt:setRemember]
															 forKey:@"displayNum"];
					[self updateMenu];
				}
			}
		}
	}

	return setRemember;
}

-(IBAction) setFavoritesRememberNumPref:(id)sender
{
	[self checkFavoritesRememberNumPref:[sender intValue]];
}

-(void) checkFavoritesRememberNumPref:(int)newRemember
{
	BOOL favoritesWasSelected = [flycutOperator favoritesStoreIsSelected];
	[flycutOperator setFavoritesStoreSelected:YES];
	[self checkRememberNumPref:newRemember forPrimaryStore:NO];
	[flycutOperator setFavoritesStoreSelected:favoritesWasSelected];
}

-(IBAction) setDisplayNumPref:(id)sender
{
	[self updateMenu];
}

-(NSTextField*) preferencePanelSliderLabelForText:(NSString*)text aligned:(NSTextAlignment)alignment andFrame:(NSRect)frame
{
	NSTextField *newLabel = [[NSTextField alloc] initWithFrame:frame];
	newLabel.editable = NO;
	[newLabel setAlignment:alignment];
	[newLabel setBordered:NO];
	[newLabel setDrawsBackground:NO];
	[newLabel setFont:[NSFont labelFontOfSize:10]];
	[newLabel setStringValue:text];
	return [newLabel autorelease];
}

-(NSBox*) preferencePanelSliderRowForText:(NSString*)title withTicks:(int)ticks minText:(NSString*)minText maxText:(NSString*)maxText minValue:(double)min maxValue:(double)max frameMaxY:(int)frameMaxY binding:(NSString*)keyPath action:(SEL)action
{
	NSRect panelFrame = [appearancePanel frame];

	if ( frameMaxY < 0 )
		frameMaxY = panelFrame.size.height-8;

	int height = 63;

	NSBox *newRow = [[NSBox alloc] initWithFrame:NSMakeRect(0, frameMaxY-height, panelFrame.size.width-10, height)];
	[newRow setTitlePosition:NSNoTitle];
	[newRow setTransparent:YES];

    [newRow addSubview:[self preferencePanelSliderLabelForText:title aligned:NSTextAlignmentNatural andFrame:NSMakeRect(8, 25, 100, 25)]];

    [newRow addSubview:[self preferencePanelSliderLabelForText:minText aligned:NSTextAlignmentLeft andFrame:NSMakeRect(113, 0, 151, 25)]];
    [newRow addSubview:[self preferencePanelSliderLabelForText:maxText aligned:NSTextAlignmentRight andFrame:NSMakeRect(109+310-151-4, 0, 151, 25)]];

	NSSlider *newControl = [[NSSlider alloc] initWithFrame:NSMakeRect(109, 29, 310, 25)];

	newControl.numberOfTickMarks=ticks;
	[newControl setMinValue:min];
	[newControl setMaxValue:max];

	[self setBinding:@"value" forKey:keyPath andOrAction:action on:newControl];

	[newRow addSubview:newControl];
	[newControl release];

	return [newRow autorelease];
}

-(NSBox*) preferencePanelPopUpRowForText:(NSString*)title items:(NSArray*)items frameMaxY:(int)frameMaxY binding:(NSString*)keyPath action:(SEL)action
{
	NSRect panelFrame = [appearancePanel frame];

	if ( frameMaxY < 0 )
		frameMaxY = panelFrame.size.height-8;

	int height = 40;

	NSBox *newRow = [[NSBox alloc] initWithFrame:NSMakeRect(0, frameMaxY-height+5, panelFrame.size.width-10, height)];
	[newRow setTitlePosition:NSNoTitle];
	[newRow setTransparent:YES];

    [newRow addSubview:[self preferencePanelSliderLabelForText:title aligned:NSTextAlignmentNatural andFrame:NSMakeRect(8, -2, 100, 25)]];

	NSPopUpButton *newControl = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(109, 4, 150, 25) pullsDown:NO];

	[newControl addItemsWithTitles:items];

	[self setBinding:@"selectedIndex" forKey:keyPath andOrAction:action on:newControl];

	[newRow addSubview:newControl];
	[newControl release];

	return [newRow autorelease];
}

-(NSBox*) preferencePanelCheckboxRowForText:(NSString*)title frameMaxY:(int)frameMaxY binding:(NSString*)keyPath action:(SEL)action
{
	NSRect panelFrame = [appearancePanel frame];

	if ( frameMaxY < 0 )
		frameMaxY = panelFrame.size.height-8;

	int height = 40;

	NSBox *newRow = [[NSBox alloc] initWithFrame:NSMakeRect(0, frameMaxY-height+5, panelFrame.size.width-10, height)];
	[newRow setTitlePosition:NSNoTitle];
	[newRow setTransparent:YES];

	NSButton *newControl = [[NSButton alloc] initWithFrame:NSMakeRect(8, 4, panelFrame.size.width-20, 25)];

    [newControl setButtonType:NSButtonTypeSwitch];
	[newControl setTitle:title];

	[self setBinding:@"value" forKey:keyPath andOrAction:action on:newControl];

	[newRow addSubview:newControl];
	[newControl release];

	return [newRow autorelease];
}

-(NSBox*) preferencePanelHotkeyRowForText:(NSString*)title recorder:(SRRecorderControl**)recorder frameMaxY:(int)frameMaxY
{
	NSRect panelFrame = [appearancePanel frame];

	if ( frameMaxY < 0 )
		frameMaxY = panelFrame.size.height-8;

	int height = 50; // Increased height for better hotkey recorder visibility

	NSBox *newRow = [[NSBox alloc] initWithFrame:NSMakeRect(0, frameMaxY-height+5, panelFrame.size.width-10, height)];
	[newRow setTitlePosition:NSNoTitle];
	[newRow setTransparent:YES];

    [newRow addSubview:[self preferencePanelSliderLabelForText:title aligned:NSTextAlignmentNatural andFrame:NSMakeRect(8, 15, 180, 25)]];

	*recorder = [[SRRecorderControl alloc] initWithFrame:NSMakeRect(200, 12, 280, 25)]; // Wider recorder control
	[*recorder setDelegate:self];
	[newRow addSubview:*recorder];

	return [newRow autorelease];
}

-(void)setBinding:(NSString*)binding forKey:(NSString*)keyPath andOrAction:(SEL)action on:(NSControl*)newControl
{
	[newControl bind:binding
			toObject:[NSUserDefaults standardUserDefaults]
		 withKeyPath:keyPath
			 options:[NSDictionary dictionaryWithObject:[NSNumber numberWithBool:YES]
												 forKey:@"NSContinuouslyUpdatesValue"]];
	if ( nil != action )
	{
		[newControl setTarget:self];
		[newControl setAction:action];
	}
}

-(void) buildAppearancesPreferencePanel
{
	NSRect screenFrame = [[NSScreen mainScreen] frame];

	int nextYMax = -1;
	NSView *row = [self preferencePanelSliderRowForText:FCLocalizedString(@"Bezel transparency")
											 withTicks:16
											   minText:FCLocalizedString(@"Lighter")
											   maxText:FCLocalizedString(@"Darker")
											  minValue:0.1
											  maxValue:0.9
											 frameMaxY:nextYMax
											   binding:@"bezelAlpha"
												action:@selector(setBezelAlpha:)];
	[appearancePanel addSubview:row];
	nextYMax = row.frame.origin.y;

	row = [self preferencePanelSliderRowForText:FCLocalizedString(@"Bezel width")
									  withTicks:50
										minText:FCLocalizedString(@"Smaller")
										maxText:FCLocalizedString(@"Bigger")
									   minValue:200
									   maxValue:screenFrame.size.width
									  frameMaxY:nextYMax
										binding:@"bezelWidth"
										 action:@selector(setBezelWidth:)];
	[appearancePanel addSubview:row];
	nextYMax = row.frame.origin.y;

	row = [self preferencePanelSliderRowForText:FCLocalizedString(@"Bezel height")
									  withTicks:50
										minText:FCLocalizedString(@"Smaller")
										maxText:FCLocalizedString(@"Bigger")
									   minValue:200
									   maxValue:screenFrame.size.height
									  frameMaxY:nextYMax
										binding:@"bezelHeight"
										 action:@selector(setBezelHeight:)];
	[appearancePanel addSubview:row];
	nextYMax = row.frame.origin.y;

	row = [self preferencePanelPopUpRowForText:FCLocalizedString(@"Menu item icon")
										 items:[NSArray arrayWithObjects:
												FCLocalizedString(@"Floatcut icon"),
												FCLocalizedString(@"Black Floatcut icon"),
												FCLocalizedString(@"White scissors"),
												FCLocalizedString(@"Black scissors"),nil]
									 frameMaxY:nextYMax
									   binding:@"menuIcon"
										action:@selector(switchMenuIcon:)];
	[appearancePanel addSubview:row];
	nextYMax = row.frame.origin.y;

	// Add search hotkey recorder - moved up for better visibility
	row = [self preferencePanelHotkeyRowForText:FCLocalizedString(@"Search clipboard hotkey:") recorder:&searchRecorder frameMaxY:nextYMax];
	[appearancePanel addSubview:row];
	nextYMax = row.frame.origin.y;

//	row = [self preferencePanelCheckboxRowForText:@"Animate bezel appearance"
//										frameMaxY:nextYMax
//										  binding:@"popUpAnimation"
//										   action:nil];
//	[appearancePanel addSubview:row];
//	nextYMax = row.frame.origin.y;

    row = [self preferencePanelCheckboxRowForText:FCLocalizedString(@"Show clipping source app and time")
                                        frameMaxY:nextYMax
                                          binding:@"displayClippingSource"
                                          action:@selector(setupBezel:)];
    [appearancePanel addSubview:row];
    nextYMax = row.frame.origin.y;
    
    // Add Accessibility Check button
    NSRect panelFrame = [appearancePanel frame];
    int height = 40;
    NSBox *accessibilityRow = [[NSBox alloc] initWithFrame:NSMakeRect(0, nextYMax - height + 5, panelFrame.size.width - 10, height)];
    [accessibilityRow setTitlePosition:NSNoTitle];
    [accessibilityRow setTransparent:YES];
    
    NSButton *accessibilityButton = [[NSButton alloc] initWithFrame:NSMakeRect(8, 4, 250, 25)];
    [accessibilityButton setTitle:FCLocalizedString(@"Check Accessibility Permissions")];
    [accessibilityButton setButtonType:NSButtonTypeMomentaryPushIn];
    [accessibilityButton setBezelStyle:NSBezelStyleRounded];
    [accessibilityButton setTarget:self];
    [accessibilityButton setAction:@selector(recheckAccessibility:)];
    
    [accessibilityRow addSubview:accessibilityButton];
    [appearancePanel addSubview:accessibilityRow];
	[accessibilityButton release];
	[accessibilityRow release];
    
}

-(IBAction) showPreferencePanel:(id)sender
{
    [currentRunningApplication release];
    currentRunningApplication = nil; // So it doesn't get pulled foreground atop the preference panel.
    if (!self.swiftPreferencesWindowController) {
        self.swiftPreferencesWindowController = [[[FloatcutPreferencesWindowController alloc] init] autorelease];
        self.swiftPreferencesWindowController.bridgeDelegate = self;
    }
    [self.swiftPreferencesWindowController showAndFocus];
	[flycutOperator willShowPreferences];
}

-(IBAction)toggleLoadOnStartup:(id)sender {
	// Since the control in Interface Builder is bound to User Defaults and sends this action, this method is called after User Defaults already reflects the newly-selected state and merely conveys that value to the relevant mechanisms rather than acting to negate the User Defaults state.
	SMAppService *loginItem = [SMAppService mainAppService];
	NSError *error = nil;
	if ( [[NSUserDefaults standardUserDefaults] boolForKey:@"loadOnStartup"] ) {
		if (![loginItem registerAndReturnError:&error]) {
			NSLog(@"Failed to enable login item: %@", error);
		}
	} else {
		if (![loginItem unregisterAndReturnError:&error]) {
			NSLog(@"Failed to disable login item: %@", error);
		}
	}
}

-(IBAction)recheckAccessibility:(id)sender {
    // Re-check accessibility state and offer to trigger system prompt
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    NSDictionary* options = @{(id) (kAXTrustedCheckOptionPrompt): @NO};
    BOOL trusted = AXIsProcessTrustedWithOptions((CFDictionaryRef) (options));
    
    NSLog(@"[Accessibility] Manual recheck - Bundle: %@, ID: %@, Trusted: %@", 
          bundlePath, bundleID, trusted ? @"YES" : @"NO");
    
    if (trusted) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = FCLocalizedString(@"Accessibility Access Granted");
        alert.informativeText = [NSString stringWithFormat:FCLocalizedString(@"Floatcut has accessibility permissions.\n\nBundle: %@\nBundle ID: %@"), bundlePath, bundleID];
        [alert addButtonWithTitle:FCLocalizedString(@"OK")];
        [alert runModal];
        [alert release];
    } else {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = FCLocalizedString(@"Accessibility Access Required");
        alert.informativeText = [NSString stringWithFormat:FCLocalizedString(@"Floatcut does not have accessibility permissions.\n\nBundle: %@\nBundle ID: %@\n\nYou can request the system prompt or open Settings to grant access manually."), bundlePath, bundleID];
        [alert addButtonWithTitle:FCLocalizedString(@"Request System Prompt")];
        [alert addButtonWithTitle:FCLocalizedString(@"Open Settings")];
        [alert addButtonWithTitle:FCLocalizedString(@"Cancel")];
        NSModalResponse response = [alert runModal];
        [alert release];
        
        if (response == NSAlertFirstButtonReturn) {
            [self requestAccessibilityWithPrompt];
        } else if (response == NSAlertSecondButtonReturn) {
            [self openAccessibilitySettings];
        }
    }
}


- (void)restoreStashedStoreAndUpdate
{
    if ([flycutOperator restoreStashedStore])
    {
        [bezel setColor:NO];
        [self updateBezel];
    }
}

- (void)rememberPotentialPasteTargetApplication:(NSRunningApplication *)application
{
    if (nil == application)
        return;

    if (application.processIdentifier == [[NSProcessInfo processInfo] processIdentifier])
        return;

    if (application.activationPolicy == NSApplicationActivationPolicyProhibited)
        return;

    [application retain];
    [currentRunningApplication release];
    currentRunningApplication = application;
}

- (void)workspaceDidActivateApplication:(NSNotification *)notification
{
    NSRunningApplication *application = notification.userInfo[NSWorkspaceApplicationKey];
    [self rememberPotentialPasteTargetApplication:application];
}

- (void)restorePasteTargetApplication
{
    if (nil == currentRunningApplication || currentRunningApplication.terminated)
        return;

    if (currentRunningApplication.processIdentifier == [[NSProcessInfo processInfo] processIdentifier])
        return;

    [currentRunningApplication activateWithOptions:NSApplicationActivateIgnoringOtherApps];
}

- (void)pasteIntoRememberedTargetApplication
{
    [self hideApp];
    [self restorePasteTargetApplication];
    [self performSelector:@selector(fakeCommandV) withObject:nil afterDelay:0.2];
}

- (void)pasteFromStack
{
	DLog(@"pasteFromStack called");
	FloatcutClipping *clipping = [flycutOperator clippingAtStackPosition];
	if ( nil != clipping ) {
		[self addClippingToPasteboard:clipping];
		[self performSelector:@selector(pasteIntoRememberedTargetApplication) withObject:nil afterDelay:0.2];
	} else {
		DLog(@"No content found in stack position");
		[self performSelector:@selector(hideApp) withObject:nil afterDelay:0.2];
	}
    [self restoreStashedStoreAndUpdate];
}

- (void)moveItemAtStackPositionToTopOfStack
{
	[flycutOperator moveClippingAtStackPositionToTop];
	[self performSelector:@selector(hideApp) withObject:nil afterDelay:0.2];
}

- (BOOL)pasteIndex:(int)position refreshUI:(BOOL)refreshUI
{
    // If there is an active search, we need to map the menu index to the stack position.
    NSString* search = [searchBox stringValue];
    if ( nil != search && 0 != search.length )
    {
        NSArray *mapping = [flycutOperator previousIndexes:[[NSUserDefaults standardUserDefaults] integerForKey:@"displayNum"] containing:search];
        position = [mapping[position] intValue];
    }

    return [self pasteResolvedStoreIndex:position refreshUI:refreshUI];
}

- (BOOL)pasteResolvedStoreIndex:(int)storeIndex refreshUI:(BOOL)refreshUI
{
    FloatcutClipping *clipping = [flycutOperator getClippingFromIndex:storeIndex];
    NSString *content = [flycutOperator getPasteFromIndex:storeIndex];
    if ( nil != clipping && (nil != content || [clipping isImage]) )
    {
        [self addClippingToPasteboard:clipping];
        if (refreshUI)
            [self updateMenu];
        return YES;
	}
    return NO;
}

- (void)pasteIndexAndUpdate:(int) position {
    [self pasteIndex:position refreshUI:YES];
}

- (void)metaKeysReleased
{
	DLog(@"metaKeysReleased called - isBezelPinned: %@", isBezelPinned ? @"YES" : @"NO");
	if ( ! isBezelPinned ) {
		[self pasteFromStack];
	}
}

- (void)windowDidResignKey:(NSNotification *)notification {
	[self hideApp];
}

-(void)fakeKey:(NSNumber*) keyCode withCommandFlag:(BOOL) setFlag
	/*" +fakeKey synthesizes keyboard events. "*/
{     
    CGEventSourceRef sourceRef = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
    if (!sourceRef)
    {
        DLog(@"No event source");
        return;
    }
    CGKeyCode veeCode = (CGKeyCode)[keyCode intValue];
    CGEventRef eventDown = CGEventCreateKeyboardEvent(sourceRef, veeCode, true);
    if ( setFlag )
        CGEventSetFlags(eventDown, kCGEventFlagMaskCommand|0x000008); // some apps want bit set for one of the command keys
    CGEventRef eventUp = CGEventCreateKeyboardEvent(sourceRef, veeCode, false);
    CGEventPost(kCGHIDEventTap, eventDown);
    CGEventPost(kCGHIDEventTap, eventUp);
    CFRelease(eventDown);
    CFRelease(eventUp);
    CFRelease(sourceRef);
}

/*" +fakeCommandV synthesizes keyboard events for Cmd-v Paste shortcut. "*/
-(void)fakeCommandV {
    DLog(@"fakeCommandV called - attempting to paste");

    // Check accessibility without prompting - the startup alert handles prompting.
    // Using @YES here would trigger a system dialog that steals focus and breaks paste.
    BOOL accessibilityEnabled = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @NO});

    if (!accessibilityEnabled) {
        // Consolidated failure log with all relevant context
        NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        NSLog(@"[Accessibility FAILURE] Cannot simulate Cmd-V paste. Bundle: %@, ID: %@, Trusted: NO. User must grant Accessibility permission in System Settings.", bundlePath, bundleID);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = FCLocalizedString(@"Accessibility Access Required");
            alert.informativeText = FCLocalizedString(@"Floatcut needs accessibility access to paste.\n\nIf you already granted permission, try removing Floatcut from the Accessibility list, adding it again, and restarting the app.");
            [alert addButtonWithTitle:FCLocalizedString(@"Open Settings")];
            [alert addButtonWithTitle:FCLocalizedString(@"Cancel")];
            NSModalResponse response = [alert runModal];
            [alert release];
            if (response == NSAlertFirstButtonReturn) {
                [self openAccessibilitySettings];
            }
        });
        return;
    }

    [self fakeKey:[srTransformer reverseTransformedValue:@"V"] withCommandFlag:TRUE];
}

/*" +fakeDownArrow synthesizes keyboard events for the down-arrow key. "*/
-(void)fakeDownArrow { [self fakeKey:@125 withCommandFlag:FALSE]; }

/*" +fakeUpArrow synthesizes keyboard events for the up-arrow key. "*/
-(void)fakeUpArrow { [self fakeKey:@126 withCommandFlag:FALSE]; }

// Perform the search and display updated results when the user types.
-(void)controlTextDidChange:(NSNotification *)aNotification
{
    NSString* search = [searchBox stringValue];
    [self updateMenuContaining:search];
}

// Perform the search and display updated results when the search field performs its action.
-(IBAction)searchItems:(id)sender
{
    NSString* search = [searchBox stringValue];
    [self updateMenuContaining:search];
}

// Catch keystrokes in the search field and look for arrows.
-(BOOL)control:(NSControl *)control textView:(NSTextView *)fieldEditor doCommandBySelector:(SEL)commandSelector
{
    // Handle menu search box navigation
    if (control == searchBox) {
        if( commandSelector == @selector(moveUp:) )
        {
            [[searchBox window] makeFirstResponder:menuFirstResponder];
            [self fakeUpArrow];
            return YES;    // We handled this command; don't pass it on
        }
        if( commandSelector == @selector(moveDown:) )
        {
            [[searchBox window] makeFirstResponder:menuFirstResponder];
            [self fakeDownArrow];
            return YES;    // We handled this command; don't pass it on
        }
    }
    // Handle search window navigation
    else if (control == searchWindowSearchField) {
        if( commandSelector == @selector(moveUp:) )
        {
            NSInteger currentRow = [searchWindowTableView selectedRow];
            NSInteger newRow = currentRow <= 0 ? [searchWindowTableView numberOfRows] - 1 : currentRow - 1;
            [searchWindowTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:newRow] byExtendingSelection:NO];
            [searchWindowTableView scrollRowToVisible:newRow];
            return YES;
        }
        if( commandSelector == @selector(moveDown:) )
        {
            NSInteger currentRow = [searchWindowTableView selectedRow];
            NSInteger newRow = currentRow >= [searchWindowTableView numberOfRows] - 1 ? 0 : currentRow + 1;
            [searchWindowTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:newRow] byExtendingSelection:NO];
            [searchWindowTableView scrollRowToVisible:newRow];
            return YES;
        }
        if( commandSelector == @selector(insertNewline:) ) // Enter key
        {
            [self searchWindowItemSelected:nil];
            return YES;
        }
        if( commandSelector == @selector(cancelOperation:) ) // Escape key
        {
            [self hideSearchWindow];
            return YES;
        }
        if( commandSelector == @selector(performClose:) ) // Cmd-W
        {
            [self hideSearchWindow];
            return YES;
        }
    }

    return NO;    // Default handling of the command
}

-(void)pollPB:(NSTimer *)timer
{
	// Keep probing the advertised types on every tick. This is intentionally done
	// before the change-count fast path because Universal Clipboard may materialize
	// remote contents lazily when the pasteboard is inspected.
    NSString *textType = [jcPasteboard availableTypeFromArray:@[NSPasteboardTypeString]];
    NSString *imageType = [jcPasteboard availableTypeFromArray:@[NSPasteboardTypePNG, @"public.jpeg", NSPasteboardTypeTIFF]];
    NSInteger observedChangeCount = [jcPasteboard changeCount];
    if ( pbCount != observedChangeCount && ![flycutOperator storeDisabled] ) {
		pbCount = observedChangeCount;
        if ( textType != nil || imageType != nil ) {
				NSRunningApplication *currRunningApp = [[NSWorkspace sharedWorkspace] frontmostApplication];
				NSArray *availableTypes = [jcPasteboard types];
				bool largeCopyRisk = nil != currRunningApp && [[currRunningApp localizedName] rangeOfString:@"Remote Desktop Connection"].location != NSNotFound;

			// Microsoft's Remote Desktop Connection has an issue with large copy actions, which appears to be in the time it takes to transer them over the network.  The copy starts being registered with OS X prior to completion of the transfer, and if the active application changes during the transfer the copy will be lost.  Indicate this time period by toggling the menu icon at the beginning of all RDC trasfers and back at the end.  Apple's Screen Sharing does not demonstrate this problem.
			if (largeCopyRisk)
				[self toggleMenuIconDisabled];

			// In case we need to do a status visual, this will be dispatched out so our thread isn't blocked.
			dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0);
			dispatch_async(queue, ^{

				// This operation blocks until the transfer is complete, though it was was here before the RDC issue was discovered.  Convenient.
                NSString *contents = textType ? [jcPasteboard stringForType:textType] : nil;
                NSData *imageData = imageType ? [jcPasteboard dataForType:imageType] : nil;
                NSInteger materializedChangeCount = [jcPasteboard changeCount];

				dispatch_async(dispatch_get_main_queue(), ^{
					// Toggle back if dealing with the RDC issue.
					if (largeCopyRisk)
						[self toggleMenuIconDisabled];

					// If another owner wrote while lazy pasteboard data was being
					// materialized, these bytes cannot safely be attributed to the
					// originally observed change. The next poll handles the newer
					// count (and its explicit Sync/self-write token) instead.
					if (materializedChangeCount != observedChangeCount ||
						[self consumeBlockedPasteboardChangeCount:observedChangeCount])
						return;

					if ( imageData.length > 0 ) {
							BOOL accepted = [flycutOperator addImageClippingData:imageData
                                                          ofType:imageType
                                                         fromApp:[currRunningApp localizedName]
                                                  withAppBundleURL:currRunningApp.bundleURL.path
                                                           target:self
                                           clippingAddedSelector:@selector(updateMenu)];
							if (accepted)
								[[FloatcutSyncCoordinator shared] sendAcceptedLocalImage:imageData pasteboardType:imageType];
					} else if ( contents == nil || [flycutOperator shouldSkip:contents ofType:textType fromAvailableTypes:availableTypes] ) {
						DLog(@"Contents: Empty or skipped");
					} else {
						BOOL accepted = [flycutOperator addClipping:contents ofType:textType fromApp:[currRunningApp localizedName] withAppBundleURL:currRunningApp.bundleURL.path target:self clippingAddedSelector:@selector(updateMenu)];
						if (accepted)
							[[FloatcutSyncCoordinator shared] sendAcceptedLocalText:contents];
					}
				});
            });
        } 
    }
}

- (void)processBezelKeyDown:(NSEvent *)theEvent {
	int newStackPosition;
	// AppControl should only be getting these directly from bezel via delegation
    if ([theEvent type] == NSEventTypeKeyDown) {
		if ([theEvent keyCode] == [mainRecorder keyCombo].code ) {
            if ([theEvent modifierFlags] & NSEventModifierFlagShift) [self stackUp];
			 else [self stackDown];
			return;
		}
		unichar pressed = [[theEvent charactersIgnoringModifiers] characterAtIndex:0];
        NSUInteger modifiers = [theEvent modifierFlags];
		switch (pressed) {
			case 0x1B:
				[self hideApp];
				break;
            case 0xD: // Enter or Return
				[self pasteFromStack];
				break;
			case 0x3:
                [self moveItemAtStackPositionToTopOfStack];
                break;
            case 0x2C: // Comma
                if ( modifiers & NSEventModifierFlagCommand ) {
                    [self showPreferencePanel:nil];
                }
                break;
			case NSUpArrowFunctionKey: 
			case NSLeftArrowFunctionKey: 
            case 0x6B: // k
				[self stackUp];
				break;
			case NSDownArrowFunctionKey: 
			case NSRightArrowFunctionKey:
            case 0x6A: // j
				[self stackDown];
				break;
            case NSHomeFunctionKey:
				if ( [flycutOperator setStackPositionToFirstItem] ) {
					[self updateBezel];
				}
				break;
            case NSEndFunctionKey:
				if ( [flycutOperator setStackPositionToLastItem] ) {
					[self updateBezel];
				}
				break;
            case NSPageUpFunctionKey:
				if ( [flycutOperator setStackPositionToTenMoreRecent] ) {
					[self updateBezel];
				}
				break;
			case NSPageDownFunctionKey:
				if ( [flycutOperator setStackPositionToTenLessRecent] ) {
                    [self updateBezel];
                }
				break;
			case NSBackspaceCharacter:
            case NSDeleteCharacter:
                if ( [flycutOperator clearItemAtStackPosition] ) {
                    [self updateBezel];
                    [self updateMenu];
                }
                break;
            case NSDeleteFunctionKey: break;
			case 0x30: case 0x31: case 0x32: case 0x33: case 0x34: 				// Numeral 
			case 0x35: case 0x36: case 0x37: case 0x38: case 0x39:
				// We'll currently ignore the possibility that the user wants to do something with shift.
				// First, let's set the new stack count to "10" if the user pressed "0"
				newStackPosition = pressed == 0x30 ? 9 : [[NSString stringWithCharacters:&pressed length:1] intValue] - 1;
				if ( [flycutOperator setStackPositionTo: newStackPosition] ) {
					[self fillBezel];
				}
				break;
            case 's': case 'S': // Save / Save-and-delete
                {
                    bool success = [flycutOperator saveFromStack];
                    [self performSelector:@selector(hideApp) withObject:nil afterDelay:0.2];
                    [self restoreStashedStoreAndUpdate];

                    if ( success ) {
                        if ( modifiers & NSEventModifierFlagShift ) {
                            [flycutOperator clearItemAtStackPosition];
                            [self updateBezel];
                            [self updateMenu];
                        }
                    }
                }
                break;
            case 'f':
                [flycutOperator toggleToFromFavoritesStore];
                [bezel setColor:[flycutOperator favoritesStoreIsSelected]];
                [self updateBezel];
                [self hideBezel];
                [self showBezel];
                break;
            case 'F':
                if ( [flycutOperator saveFromStackToFavorites] )
                {
                    [self performSelector:@selector(hideApp) withObject:nil afterDelay:0.2];
                    [self restoreStashedStoreAndUpdate];
                    [self updateBezel];
                    [self updateMenu];
                }

                [self performSelector:@selector(hideApp) withObject:nil afterDelay:0.2];
                break;
            case ' ':
                isBezelPinned = YES;
                [bezel setCharString:[NSString stringWithFormat:FCLocalizedString(@"%d of %d (%@)"),
                    [flycutOperator stackPosition] + 1, [flycutOperator jcListCount], FCLocalizedString(@"pinned")]];
                break;
            default: // It's not a navigation/application-defined thing, so let's figure out what to do with it.
				DLog(@"PRESSED %d", pressed);
				DLog(@"CODE %ld", (long)[mainRecorder keyCombo].code);
				break;
		}		
    }
}

-(void) processBezelMouseEvents:(NSEvent *)theEvent {
    if (theEvent.type == NSEventTypeScrollWheel) {
        if (theEvent.deltaY > 0.0f) {
            [self stackUp];
        } else if (theEvent.deltaY < 0.0f) {
            [self stackDown];
        }
    } else if (theEvent.type == NSEventTypeLeftMouseUp && theEvent.clickCount == 2) {
        [self pasteFromStack];
    } else if (theEvent.type == NSEventTypeRightMouseUp) {
        isBezelPinned = YES;
        [bezel setCharString:[NSString stringWithFormat:FCLocalizedString(@"%d of %d (%@)"),
            [flycutOperator stackPosition] + 1, [flycutOperator jcListCount], FCLocalizedString(@"pinned")]];
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
	//Create our hot keys
	[self toggleMainHotKey:[NSNull null]];
	[self toggleSearchHotKey:[NSNull null]];
	[self showPendingMigrationSuccessIfNeeded];
	[self showLegacyApplicationRunningWarningIfNeeded];
}

- (void)showPendingMigrationSuccessIfNeeded
{
    FloatcutLegacyMigrationService *migrationService = [[FloatcutLegacyMigrationService alloc] init];
    NSString *message = [migrationService consumePendingSuccessMessage];
    [migrationService release];
    if ([message length] == 0)
        return;

    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Migration erfolgreich";
        alert.informativeText = message;
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
        [alert release];
    });
}

- (void)showLegacyApplicationRunningWarningIfNeeded
{
    FloatcutLegacyMigrationService *migrationService = [[FloatcutLegacyMigrationService alloc] init];
    BOOL legacyApplicationRunning = [migrationService isLegacyApplicationRunning];
    [migrationService release];
    if (!legacyApplicationRunning)
        return;

    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Frühere Flycut-/Floatcut-Version läuft";
        alert.informativeText = @"Bitte beende die frühere Version. Zwei gleichzeitig laufende Zwischenablage-Manager können doppelte Einträge, globale Hotkey-Konflikte und konkurrierende Einfügevorgänge verursachen.";
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
        [alert release];
    });
}

- (void) updateBezel
{
	[flycutOperator adjustStackPositionIfOutOfBounds];
	if ([flycutOperator jcListCount] == 0) { // empty
		[bezel setText:@""];
		[bezel setCharString:FCLocalizedString(@"Empty")];
	        [bezel setSource:@""];
	        [bezel setDate:@""];
	        [bezel setSourceIcon:nil];
            [bezel setPreviewImage:nil];
		}
	else { // normal
		[self fillBezel];
	}
}

- (void) showBezel
{
	if ( [flycutOperator stackPositionIsInBounds] ) {
		[self fillBezel];
	}
	NSRect mainScreenRect = [NSScreen mainScreen].visibleFrame;
	[bezel setFrame:NSMakeRect(mainScreenRect.origin.x + mainScreenRect.size.width/2 - bezel.frame.size.width/2,
							   mainScreenRect.origin.y + mainScreenRect.size.height/2 - bezel.frame.size.height/2,
							   bezel.frame.size.width,
							   bezel.frame.size.height) display:YES];
	if ([bezel respondsToSelector:@selector(setCollectionBehavior:)])
		[bezel setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces];
//	if ([[NSUserDefaults standardUserDefaults] boolForKey:@"popUpAnimation"])
//		[bezel makeKeyAndOrderFrontWithPopEffect];
//	else
    [bezel makeKeyAndOrderFront:self];
	isBezelDisplayed = YES;
}

- (void) hideBezel
{
	[bezel orderOut:nil];
	[bezel setCharString:FCLocalizedString(@"Empty")];
    [bezel setPreviewImage:nil];
	isBezelDisplayed = NO;
}

-(void)hideApp
{
	isBezelPinned = NO;
	[self hideBezel];
	[NSApp hide:self];
}

- (void) applicationWillResignActive:(NSApplication *)app; {
	// This should be hidden anyway, but just in case it's not.
	[self hideBezel];
}


- (void)hitMainHotKey:(SGHotKey *)hotKey
{
	if ( ! isBezelDisplayed ) {
		//Do NOT activate the app so focus stays on app the user is interacting with
		//https://github.com/TermiT/Flycut/issues/45
		//[NSApp activateIgnoringOtherApps:YES];
		if ( [[NSUserDefaults standardUserDefaults] boolForKey:@"stickyBezel"] ) {
			isBezelPinned = YES;
		}
		[self showBezel];
	} else {
		[self stackDown];
	}
}

- (IBAction)toggleMainHotKey:(id)sender
{
	if (mainHotKey != nil)
	{
		[[SGHotKeyCenter sharedCenter] unregisterHotKey:mainHotKey];
		[mainHotKey release];
		mainHotKey = nil;
	}
	mainHotKey = [[SGHotKey alloc] initWithIdentifier:@"mainHotKey"
											   keyCombo:[SGKeyCombo keyComboWithKeyCode:[mainRecorder keyCombo].code
																			  modifiers:[mainRecorder cocoaToCarbonFlags: [mainRecorder keyCombo].flags]]];
	[mainHotKey setName:FCLocalizedString(@"Activate Floatcut HotKey")]; //This is typically used by PTKeyComboPanel
	[mainHotKey setTarget: self];
	[mainHotKey setAction: @selector(hitMainHotKey:)];
	[[SGHotKeyCenter sharedCenter] registerHotKey:mainHotKey];
}

- (IBAction)setSavePreference:(id)sender
{
	(void)sender;
}

- (IBAction)selectSaveLocation:(id)sender {
    [self presentSaveLocationPanelForAutoSave:(sender == autoSaveToLocationButton)];
}

- (void)presentSaveLocationPanelForAutoSave:(BOOL)autoSave
{
    NSWindow *parentWindow = self.swiftPreferencesWindowController.window ?: prefsPanel;
	NSOpenPanel* panel = [NSOpenPanel openPanel];
	[panel setCanChooseFiles:NO];
	[panel setCanChooseDirectories:YES];
	[panel setCanCreateDirectories:YES];
	[panel setAllowsMultipleSelection:NO];
	[panel setMessage:FCLocalizedString(@"Select a directory.")];

	[panel beginSheetModalForWindow:parentWindow completionHandler:^(NSInteger result){
        if (result == NSModalResponseOK) {
			NSURL* url = [[panel URLs] firstObject];

			if (!url) { return; }

			if (!autoSave) {
				[[NSUserDefaults standardUserDefaults] setURL:url forKey:@"saveToLocation"];
                [saveToLocationButton setTitle:[url lastPathComponent]];
			}
			else {
				[[NSUserDefaults standardUserDefaults] setURL:url forKey:@"autoSaveToLocation"];
                [autoSaveToLocationButton setTitle:[url lastPathComponent]];
			}
            [self.swiftPreferencesWindowController refreshDynamicContent];
		}

	}];
}

-(IBAction)clearClippingList:(id)sender {
	[self clearFavoritesStore:NO statusPopoverController:nil];
}

- (void)clearFavoritesStore:(BOOL)clearFavorites statusPopoverController:(FloatcutStatusPopoverController *)controller
{
    [NSApp activateIgnoringOtherApps:YES];

    NSAlert *alert = [[NSAlert alloc] init];
	[alert setMessageText:FCLocalizedString(clearFavorites ? @"Clear Favorites" : @"Clear Clipping List")];
	[alert setInformativeText:FCLocalizedString(clearFavorites ? @"Do you want to clear all favorite clippings?" : @"Do you want to clear all recent clippings?")];
    [alert addButtonWithTitle:FCLocalizedString(@"Clear")];
    [alert addButtonWithTitle:FCLocalizedString(@"Cancel")];
	NSInteger choice = [alert runModal];
    [alert release];

    if ( choice == NSAlertFirstButtonReturn ) {
		if (clearFavorites)
			[flycutOperator clearFavoritesList];
		else
			[flycutOperator clearPrimaryList];

		[controller setFavoritesStoreActive:[flycutOperator favoritesStoreIsSelected]];
		[self refreshStatusItemsContaining:[controller currentSearchText]];
		if ( [[NSUserDefaults standardUserDefaults] integerForKey:@"savePreference"] >= 1 ) {
			[flycutOperator saveEngine];
		}
		if (clearFavorites == [flycutOperator favoritesStoreIsSelected])
			[bezel setText:@""];
    }
}

-(IBAction)mergeClippingList:(id)sender {
    [flycutOperator mergeList];
    [self updateMenu];
}

- (NSImage *)previewImageForClipping:(FloatcutClipping *)clipping size:(CGFloat)size
{
    if (![clipping isImage])
        return nil;

    FloatcutThumbnailService *service = [FloatcutThumbnailService shared];
    NSString *identifier = [clipping identifier];
    CGFloat scale = bezel.backingScaleFactor;
    NSImage *cached = [service cachedImageWithIdentifier:identifier size:size scale:scale];
    if (cached)
        return cached;
    NSUInteger generation = bezelPreviewGeneration;
    [service requestWithData:[clipping imageData] identifier:identifier size:size scale:scale completion:^(NSImage *image) {
        if (generation != bezelPreviewGeneration || ![bezel isVisible] ||
            ![[[flycutOperator clippingAtStackPosition] identifier] isEqualToString:identifier])
            return;
        [bezel setPreviewImage:image];
    }];
    // Reserve the existing image slot while decoding so text/layout do not jump.
    return [[[NSImage alloc] initWithSize:NSMakeSize(size, size)] autorelease];
}

- (NSArray<NSDictionary *> *)displayItemsMatchingSearch:(NSString *)search
{
    NSInteger howMany = [[NSUserDefaults standardUserDefaults] integerForKey:@"displayNum"];
    NSMutableArray *items = [NSMutableArray array];
    BOOL hasSearch = search.length > 0;
	BOOL favoritesStoreActive = [flycutOperator favoritesStoreIsSelected];
	NSSet *favoriteIdentifiers = favoritesStoreActive ? nil : [flycutOperator favoriteClippingIdentifiers];
    NSInteger totalCount = [flycutOperator jcListCount];

    for (NSInteger storeIndex = 0; storeIndex < totalCount && [items count] < howMany; storeIndex++) {
        FloatcutClipping *clipping = [flycutOperator getClippingFromIndex:(int)storeIndex];
        if (!clipping)
            continue;

        NSString *title = [clipping isImage] ? FCLocalizedString(@"Image") : [clipping displayString];
		NSString *localizedName = [clipping appLocalizedName] ?: @"";
		if (hasSearch) {
			BOOL matchesContent = [clipping isImage]
				? ([title rangeOfString:search options:NSCaseInsensitiveSearch].location != NSNotFound)
				: ([[clipping contents] rangeOfString:search options:NSCaseInsensitiveSearch].location != NSNotFound);
			BOOL matches = matchesContent
				|| ([localizedName rangeOfString:search options:NSCaseInsensitiveSearch].location != NSNotFound);
            if (!matches)
                continue;
        }

        NSString *dateString = @"";
        if ([clipping timestamp] > 0)
            dateString = [listDateFormat stringFromDate:[NSDate dateWithTimeIntervalSince1970:[clipping timestamp]]] ?: @"";
        NSMutableDictionary *item = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                     title ?: @"", @"title",
                                     [NSNumber numberWithInteger:storeIndex], @"storeIndex",
									 @([clipping isImage]), @"isImage",
									 @([clipping receivedFromSync]), @"isRemoteSync",
									 @(!favoritesStoreActive && [favoriteIdentifiers containsObject:[clipping identifier]]), @"isFavorite",
									 [clipping identifier], @"clippingID",
                                     nil];
        if ([localizedName length] > 0)
            [item setObject:localizedName forKey:@"sourceName"];
        if ([dateString length] > 0)
            [item setObject:dateString forKey:@"dateText"];

        if ([clipping isImage]) {
            NSData *previewData = [clipping imageData];
            if (previewData)
                [item setObject:previewData forKey:@"previewData"];
        }

        [items addObject:item];
    }

    return items;
}

- (void)updateMenu {
	if (menuUpdateScheduled)
		return;
	menuUpdateScheduled = YES;

	dispatch_async(dispatch_get_main_queue(), ^{
		menuUpdateScheduled = NO;
		if ( !statusItem || !statusItem.button.enabled || !self.statusPopoverController.isShown ) {
			self.preserveStatusPopoverSearchOnNextMenuUpdate = NO;
			return;
		}

		BOOL preserveSearch = self.preserveStatusPopoverSearchOnNextMenuUpdate;
		self.preserveStatusPopoverSearchOnNextMenuUpdate = NO;
		NSString *search = preserveSearch ? [self.statusPopoverController currentSearchText] : nil;
		[self refreshStatusItemsContaining:search];
		if (preserveSearch)
			return;

        // Clear the search box whenever the is reason for updateMenu to be called, since the nil call will produce non-searched results.
        [searchBox setStringValue:@""];
        [[[searchBox cell] cancelButtonCell] performClick:self];
        [self.statusPopoverController resetSearch];
    });
}

- (void)refreshStatusItemsContaining:(NSString *)search {
	[self.statusPopoverController setFavoritesStoreActive:[flycutOperator favoritesStoreIsSelected]];
	NSArray *displayItems = [self displayItemsMatchingSearch:search];
	[self.statusPopoverController updateItems:displayItems];
}

- (void)updateMenuContaining:(NSString*)search {
	if (![NSThread isMainThread]) {
		dispatch_async(dispatch_get_main_queue(), ^{
			[self refreshStatusItemsContaining:search];
		});
		return;
	}
	[self refreshStatusItemsContaining:search];
}

-(IBAction)processMenuClippingSelection:(id)sender
{
	int index = [[sender representedObject] intValue];
	[self pasteIndex:index refreshUI:NO];

	if ( [[NSUserDefaults standardUserDefaults] boolForKey:@"menuSelectionPastes"] ) {
		[self performSelector:@selector(pasteIntoRememberedTargetApplication) withObject:nil afterDelay:0.1];
	}
}

-(void) setPBBlockCount:(NSInteger)newPBBlockCount
{
	pbBlockCount = newPBBlockCount;
	NSNumber *value = [NSNumber numberWithInteger:newPBBlockCount];
	[pbBlockedChangeCounts addObject:value];
	while ([pbBlockedChangeCounts count] > 32)
		[pbBlockedChangeCounts removeObjectAtIndex:0];
}

- (BOOL)consumeBlockedPasteboardChangeCount:(NSInteger)changeCount
{
	NSNumber *value = [NSNumber numberWithInteger:changeCount];
	if (![pbBlockedChangeCounts containsObject:value])
		return NO;
	[pbBlockedChangeCounts removeObject:value];
	return YES;
}

-(void)addClipToPasteboard:(NSString*)pbFullText
{
    [jcPasteboard declareTypes:@[NSPasteboardTypeString] owner:NULL];
    [jcPasteboard setString:pbFullText forType:NSPasteboardTypeString];
	[self setPBBlockCount:[jcPasteboard changeCount]];
}

- (void)addClippingToPasteboard:(FloatcutClipping *)clipping
{
    if ([clipping isImage]) {
        NSData *imageData = [clipping imageData];
        NSString *pasteboardType = [clipping type];
        if (nil == pasteboardType || [pasteboardType length] == 0)
            pasteboardType = NSPasteboardTypePNG;
        [jcPasteboard declareTypes:@[pasteboardType] owner:nil];
        [jcPasteboard setData:imageData forType:pasteboardType];
		[self setPBBlockCount:[jcPasteboard changeCount]];
        return;
    }

    [self addClipToPasteboard:[clipping contents]];
}

-(void) stackDown
{
	DLog(@"stackDown: current position=%d, total count=%d", [flycutOperator stackPosition], [flycutOperator jcListCount]);
	if ( [flycutOperator setStackPositionToOneLessRecent] ) {
		DLog(@"stackDown: moved to position=%d", [flycutOperator stackPosition]);
		[self fillBezel];
	} else {
		DLog(@"stackDown: could not move, at limit");
	}
}

-(void) fillBezel
{
    bezelPreviewGeneration++;
    FloatcutClipping* clipping = [flycutOperator clippingAtStackPosition];
    NSString *bezelText = [clipping isImage] ? FCLocalizedString(@"Image") : [NSString stringWithFormat:@"%@", [clipping contents]];
    [bezel setText:bezelText];
    
    int currentPos = [flycutOperator stackPosition] + 1;
    int totalCount = [flycutOperator jcListCount];
    [bezel setCharString:[NSString stringWithFormat:FCLocalizedString(@"%d of %d"), currentPos, totalCount]];
    
    NSString *localizedName = [clipping appLocalizedName];
    if ( nil == localizedName )
        localizedName = @"";
    NSString* dateString = @"";
    if ( [clipping timestamp] > 0)
        dateString = [dateFormat stringFromDate:[NSDate dateWithTimeIntervalSince1970: [clipping timestamp]]];
    NSImage* icon = nil;
    if (nil != [clipping appBundleURL])
        icon = [[NSWorkspace sharedWorkspace] iconForFile:[clipping appBundleURL]];
    [bezel setSource:localizedName];
    [bezel setDate:dateString];
    [bezel setSourceIcon:icon];
    [bezel setPreviewImage:[clipping isImage] ? [self previewImageForClipping:clipping size:88.0] : nil];
}

-(void) stackUp
{
	DLog(@"stackUp: current position=%d, total count=%d", [flycutOperator stackPosition], [flycutOperator jcListCount]);
	if ( [flycutOperator setStackPositionToOneMoreRecent] ) {
		DLog(@"stackUp: moved to position=%d", [flycutOperator stackPosition]);
		[self fillBezel];
	} else {
		DLog(@"stackUp: could not move, at limit");
	}
}

- (void)setHotKeyPreferenceForRecorder:(SRRecorderControl *)aRecorder {
    if (aRecorder == mainRecorder) {
        NSDictionary *hotKeyDict = @{
            @"keyCode": @([mainRecorder keyCombo].code),
            @"modifierFlags": @([mainRecorder keyCombo].flags)
        };
        [[NSUserDefaults standardUserDefaults] setObject:hotKeyDict
                                                   forKey:@"ShortcutRecorder mainHotkey"];
    } else if (aRecorder == searchRecorder) {
        NSDictionary *hotKeyDict = @{
            @"keyCode": @([searchRecorder keyCombo].code),
            @"modifierFlags": @([searchRecorder keyCombo].flags)
        };
        [[NSUserDefaults standardUserDefaults] setObject:hotKeyDict
                                                   forKey:@"ShortcutRecorder searchHotkey"];
    }
}

- (BOOL)shortcutRecorder:(SRRecorderControl *)aRecorder isKeyCode:(NSInteger)keyCode andFlagsTaken:(NSUInteger)flags reason:(NSString **)aReason {
	return NO;
}

- (void)shortcutRecorder:(SRRecorderControl *)aRecorder keyComboDidChange:(KeyCombo)newKeyCombo {
	DLog(@"keyComboDidChange called for recorder: %p, code: %ld, flags: %lu", aRecorder, (long)newKeyCombo.code, (unsigned long)newKeyCombo.flags);
	
	if (aRecorder == mainRecorder) {
		[self toggleMainHotKey: aRecorder];
		[self setHotKeyPreferenceForRecorder: aRecorder];
	} else if (aRecorder == searchRecorder) {
		DLog(@"Search recorder keyCombo changed");
		[self toggleSearchHotKey: aRecorder];
		[self setHotKeyPreferenceForRecorder: aRecorder];
	}
}

- (NSString*)alertWithMessageText:(NSString*)message informationText:(NSString*)information buttonsTexts:(NSArray*)buttons {
	NSAlert *alert = [[NSAlert alloc] init];
	[alert setMessageText:FCLocalizedString(message)];
	[buttons enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
		[alert addButtonWithTitle:FCLocalizedString(obj)];
	}];
	[alert setInformativeText:FCLocalizedString(information)];
	NSInteger result = [alert runModal];
	[alert release];
	if ( result < NSAlertFirstButtonReturn || result >= NSAlertFirstButtonReturn + [buttons count] )
		return nil;
	return buttons[result - NSAlertFirstButtonReturn];
}

- (void)applyLocalization
{
    [self localizeMenu:jcMenu];
    [self localizeWindow:prefsPanel];
    if ([[searchBox cell] respondsToSelector:@selector(setPlaceholderString:)]) {
        [(id)[searchBox cell] setPlaceholderString:FCLocalizedString(@"Search")];
    }
}

- (void)localizeWindow:(NSWindow *)window
{
    if (!window)
        return;

    if (window.title.length > 0)
        window.title = FCLocalizedString(window.title);
    [self localizeView:window.contentView];
}

- (void)localizeMenu:(NSMenu *)menu
{
    if (!menu)
        return;

    if (menu.title.length > 0)
        menu.title = FCLocalizedString(menu.title);
    for (NSMenuItem *item in menu.itemArray)
        [self localizeMenuItem:item];
}

- (void)localizeMenuItem:(NSMenuItem *)item
{
    if (!item.isSeparatorItem && item.title.length > 0)
        item.title = FCLocalizedString(item.title);
    if (item.toolTip.length > 0)
        item.toolTip = FCLocalizedString(item.toolTip);
    if (item.submenu)
        [self localizeMenu:item.submenu];
    if (item.view)
        [self localizeView:item.view];
}

- (void)localizeView:(NSView *)view
{
    if (!view)
        return;

    if (view.toolTip.length > 0)
        view.toolTip = FCLocalizedString(view.toolTip);

    if ([view isKindOfClass:[NSButton class]]) {
        NSButton *button = (NSButton *)view;
        if (button.title.length > 0)
            button.title = FCLocalizedString(button.title);
    } else if ([view isKindOfClass:[NSTextField class]]) {
        NSTextField *textField = (NSTextField *)view;
        if (!textField.isEditable && textField.stringValue.length > 0)
            textField.stringValue = FCLocalizedString(textField.stringValue);
    } else if ([view isKindOfClass:[NSTabView class]]) {
        NSTabView *tabView = (NSTabView *)view;
        for (NSTabViewItem *item in tabView.tabViewItems) {
            if (item.label.length > 0)
                item.label = FCLocalizedString(item.label);
            [self localizeView:item.view];
        }
    } else if ([view isKindOfClass:[NSPopUpButton class]]) {
        [self localizeMenu:[(NSPopUpButton *)view menu]];
    }

    for (NSView *subview in view.subviews)
        [self localizeView:subview];
}

- (void)beginUpdates {
	needBezelUpdate = NO;
	needMenuUpdate = NO;
}

- (void)endUpdates {
	DLog(@"ending updates");
	if ( needBezelUpdate && isBezelDisplayed )
		[self updateBezel];
	if ( needMenuUpdate )
	{
		DLog(@"launching updateMenu");
		[self updateMenu];
	}
	needBezelUpdate = needMenuUpdate = NO;
}

- (void)insertClippingAtIndex:(int)index {
	[self noteChangeAtIndex:index];
}

- (void)deleteClippingAtIndex:(int)index {
	[self noteChangeAtIndex:index];
}

- (void)reloadClippingAtIndex:(int)index {
	[self noteChangeAtIndex:index];
}

- (void)moveClippingAtIndex:(int)index toIndex:(int)newIndex {
	[self noteChangeAtIndex:index];
	[self noteChangeAtIndex:newIndex];
}

- (void)noteChangeAtIndex:(int)index {
	// Always give bezel update, since the count may need updating and the possibility of concurrent user bezel navigation and store changes make need detection risky.
	needBezelUpdate = YES;
	if ( index < [[NSUserDefaults standardUserDefaults] integerForKey:@"displayNum"] )
		needMenuUpdate = YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
	[[FloatcutSyncCoordinator shared] shutdown];
	[flycutOperator applicationWillTerminate];
	//Unregister our hot keys (not required)
	[[SGHotKeyCenter sharedCenter] unregisterHotKey: mainHotKey];
	[mainHotKey release];
	mainHotKey = nil;
	[[SGHotKeyCenter sharedCenter] unregisterHotKey: searchHotKey];
	[searchHotKey release];
	searchHotKey = nil;
	[self hideBezel];
	[self hideSearchWindow];
	[[NSDistributedNotificationCenter defaultCenter]
		removeObserver:self
        		  name:@"AppleKeyboardPreferencesChangedNotification"
				object:nil];
	[[NSDistributedNotificationCenter defaultCenter]
		removeObserver:self
				  name:@"AppleSelectedInputSourcesChangedNotification"
				object:nil];
}

#pragma mark - Search Hotkey Methods

- (IBAction)toggleSearchHotKey:(id)sender
{
	if (searchHotKey != nil)
	{
		[[SGHotKeyCenter sharedCenter] unregisterHotKey:searchHotKey];
		[searchHotKey release];
		searchHotKey = nil;
	}
	
	// Only create hotkey if searchRecorder exists and has a valid combo
	if (searchRecorder && [searchRecorder keyCombo].code != -1) {
		searchHotKey = [[SGHotKey alloc] initWithIdentifier:@"searchHotKey"
												   keyCombo:[SGKeyCombo keyComboWithKeyCode:[searchRecorder keyCombo].code
																				  modifiers:[searchRecorder cocoaToCarbonFlags: [searchRecorder keyCombo].flags]]];
		[searchHotKey setName:FCLocalizedString(@"Search Clipboard HotKey")];
		[searchHotKey setTarget: self];
		[searchHotKey setAction: @selector(hitSearchHotKey:)];
		[[SGHotKeyCenter sharedCenter] registerHotKey:searchHotKey];
	}
}

- (void)hitSearchHotKey:(SGHotKey *)hotKey
{
	DLog(@"hitSearchHotKey called! isSearchWindowDisplayed: %d", isSearchWindowDisplayed);
	if ( ! isSearchWindowDisplayed ) {
		[self showSearchWindow];
	} else {
		[self hideSearchWindow];
	}
}

#pragma mark - Search Window Methods

- (void)buildSearchWindow
{
	if (self.swiftSearchWindowController)
		return;

	self.swiftSearchWindowController = [[[FloatcutSearchWindowController alloc] init] autorelease];
	self.swiftSearchWindowController.bridgeDelegate = self;
}

- (void)showSearchWindow
{
	if (!self.swiftSearchWindowController) {
		[self buildSearchWindow];
	}

    [self.swiftSearchWindowController resetSearch];
	[self updateSearchResultsForSearch:nil];
	[self.swiftSearchWindowController showAndFocus];
	isSearchWindowDisplayed = YES;
}

- (void)hideSearchWindow
{
	[self.swiftSearchWindowController hideWindow];
	isSearchWindowDisplayed = NO;
}

- (IBAction)searchWindowSearchFieldChanged:(id)sender
{
	[self updateSearchResults];
}

- (void)updateSearchResults
{
	[self updateSearchResultsForSearch:nil];
}

- (void)updateSearchResultsForSearch:(NSString *)search
{
    [self.swiftSearchWindowController updateItems:[self displayItemsMatchingSearch:search]];
}

- (IBAction)searchWindowItemSelected:(id)sender
{
	(void)sender;
}

#pragma mark - Search Window Table View Data Source & Delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
	if (tableView == searchWindowTableView) {
		return searchResults ? [searchResults count] : 0;
	}
	return 0;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	if (tableView == searchWindowTableView && searchResults && row < [searchResults count]) {
		return [searchResults objectAtIndex:row];
	}
	return nil;
}

- (void)tableView:(NSTableView *)tableView willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	if (tableView == searchWindowTableView) {
		// Customize cell appearance to match bezel style with modern system colors
		NSTextFieldCell *textCell = (NSTextFieldCell *)cell;
		if (@available(macOS 10.14, *)) {
			[textCell setTextColor:[NSColor labelColor]];
		} else {
			[textCell setTextColor:[NSColor whiteColor]];
		}
		[textCell setFont:[NSFont systemFontOfSize:12]];
	}
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row
{
	// Allow selection for keyboard navigation
	return YES;
}

#pragma mark - Search Window Delegate

- (void)windowWillClose:(NSNotification *)notification
{
	if ([notification object] == searchWindow || [notification object] == self.swiftSearchWindowController.window) {
		isSearchWindowDisplayed = NO;
	}
}

- (BOOL)windowShouldClose:(NSWindow *)sender
{
	if (sender == searchWindow || sender == self.swiftSearchWindowController.window) {
		[self hideSearchWindow];
		return NO; // We handle the closing ourselves
	}
	return YES;
}

- (void)cancelOperation:(id)sender
{
	// Handle ESC key for search window
	DLog(@"cancelOperation called, isSearchWindowDisplayed: %d", isSearchWindowDisplayed);
	if (isSearchWindowDisplayed) {
		[self hideSearchWindow];
	}
}

- (void)performClose:(id)sender
{
	// Handle cmd-W for search window
	DLog(@"performClose called, isSearchWindowDisplayed: %d", isSearchWindowDisplayed);
	if (isSearchWindowDisplayed) {
		[self hideSearchWindow];
	}
}

- (void)searchWindowController:(FloatcutSearchWindowController *)controller didSelectStoreIndex:(NSNumber *)storeIndex
{
    (void)controller;
    [self pasteResolvedStoreIndex:[storeIndex intValue] refreshUI:NO];
    [self performSelector:@selector(fakeCommandV) withObject:nil afterDelay:0.3];
}

- (void)searchWindowController:(FloatcutSearchWindowController *)controller searchTextDidChange:(NSString *)searchText
{
    (void)controller;
    [self updateSearchResultsForSearch:(searchText.length > 0 ? searchText : nil)];
}

- (void)searchWindowControllerDidClose:(FloatcutSearchWindowController *)controller
{
    (void)controller;
    isSearchWindowDisplayed = NO;
}

- (void)preferencesWindowControllerDidRequestAccessibilityCheck:(FloatcutPreferencesWindowController *)controller
{
    (void)controller;
    [self recheckAccessibility:nil];
}

- (void)preferencesWindowController:(FloatcutPreferencesWindowController *)controller didRequestSelectSaveLocation:(NSNumber *)autoSave
{
    (void)controller;
    [self presentSaveLocationPanelForAutoSave:[autoSave boolValue]];
}

- (void)preferencesWindowController:(FloatcutPreferencesWindowController *)controller didChangeMainHotKeyKeyCode:(NSNumber *)keyCode modifierFlags:(NSNumber *)modifierFlags
{
    (void)controller;
    [mainRecorder setKeyCombo:SRMakeKeyCombo([keyCode intValue], [modifierFlags unsignedIntegerValue])];
    [self toggleMainHotKey:mainRecorder];
    [self setHotKeyPreferenceForRecorder:mainRecorder];
}

- (void)preferencesWindowController:(FloatcutPreferencesWindowController *)controller didChangeSearchHotKeyKeyCode:(NSNumber *)keyCode modifierFlags:(NSNumber *)modifierFlags
{
    (void)controller;
    [searchRecorder setKeyCombo:SRMakeKeyCombo([keyCode intValue], [modifierFlags unsignedIntegerValue])];
    [self toggleSearchHotKey:searchRecorder];
    [self setHotKeyPreferenceForRecorder:searchRecorder];
}

- (void)preferencesWindowController:(FloatcutPreferencesWindowController *)controller didChangeRememberNum:(NSNumber *)value
{
    (void)controller;
    [self checkRememberNumPref:[value intValue] forPrimaryStore:YES];
}

- (void)preferencesWindowController:(FloatcutPreferencesWindowController *)controller didChangeFavoritesRememberNum:(NSNumber *)value
{
    (void)controller;
    [self checkFavoritesRememberNumPref:[value intValue]];
}

- (void)preferencesWindowControllerDidChangeDisplayNum:(FloatcutPreferencesWindowController *)controller
{
    (void)controller;
    [self updateMenu];
}

- (void)preferencesWindowControllerDidChangeBezelAppearance:(FloatcutPreferencesWindowController *)controller
{
    (void)controller;
    [self setBezelAlpha:@([[NSUserDefaults standardUserDefaults] floatForKey:@"bezelAlpha"])];
    [self setBezelWidth:@([[NSUserDefaults standardUserDefaults] floatForKey:@"bezelWidth"])];
    [self setBezelHeight:@([[NSUserDefaults standardUserDefaults] floatForKey:@"bezelHeight"])];
}

- (void)preferencesWindowControllerDidChangeMenuIcon:(FloatcutPreferencesWindowController *)controller
{
    (void)controller;
    [self switchMenuIconTo:[[NSUserDefaults standardUserDefaults] integerForKey:@"menuIcon"]];
}

- (void)preferencesWindowControllerDidChangeDisplaySource:(FloatcutPreferencesWindowController *)controller
{
    (void)controller;
    [self setupBezel:nil];
}

- (void)preferencesWindowControllerDidChangeLoadOnStartup:(FloatcutPreferencesWindowController *)controller
{
    (void)controller;
    [self toggleLoadOnStartup:nil];
}

- (void)preferencesWindowControllerDidChangeSavePreference:(FloatcutPreferencesWindowController *)controller
{
    (void)controller;
    [self setSavePreference:nil];
}

- (void)preferencesWindowControllerDidRequestOpenLoginItems:(FloatcutPreferencesWindowController *)controller
{
    (void)controller;
    if (@available(macOS 13.0, *)) {
        [SMAppService openSystemSettingsLoginItems];
    }
}

- (void)preferencesWindowController:(FloatcutPreferencesWindowController *)controller didCompleteLegacyMigration:(NSString *)message
{
    (void)controller;
    (void)message;

    // The migration service has already written and verified the complete new
    // domain.  Do not let the old in-memory store save over it while exiting.
    [flycutOperator prepareForMigrationRestart];
    [pollPBTimer invalidate];
    pollPBTimer = nil;

    NSWorkspaceOpenConfiguration *configuration = [[NSWorkspaceOpenConfiguration alloc] init];
    configuration.createsNewApplicationInstance = YES;
    NSURL *appURL = [[NSBundle mainBundle] bundleURL];
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:appURL
                                           configuration:configuration
                                       completionHandler:^(NSRunningApplication * _Nullable application, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error != nil || application == nil) {
                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText = @"Neustart erforderlich";
                alert.informativeText = @"Die Daten wurden vorbereitet. Bitte beende und starte Floatcut manuell neu, damit die Migration geprüft werden kann.";
                [alert addButtonWithTitle:@"OK"];
                [alert runModal];
                [alert release];
                return;
            }
            [NSApp terminate:nil];
        });
    }];
    [configuration release];
}

- (void)statusPopoverController:(FloatcutStatusPopoverController *)controller didSelectStoreIndex:(NSNumber *)storeIndex
{
    (void)controller;
    [self pasteResolvedStoreIndex:[storeIndex intValue] refreshUI:NO];

    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"menuSelectionPastes"]) {
        [self performSelector:@selector(pasteIntoRememberedTargetApplication) withObject:nil afterDelay:0.1];
    }
}

- (void)statusPopoverController:(FloatcutStatusPopoverController *)controller searchTextDidChange:(NSString *)searchText
{
    (void)controller;
    [self updateMenuContaining:(searchText.length > 0 ? searchText : nil)];
}

- (void)statusPopoverControllerDidRequestToggleStore:(FloatcutStatusPopoverController *)controller
{
	BOOL selectFavorites = ![flycutOperator favoritesStoreIsSelected];
	[flycutOperator setFavoritesStoreSelected:selectFavorites];
	[bezel setColor:selectFavorites];
	if (isBezelDisplayed)
		[self updateBezel];
	[controller setFavoritesStoreActive:[flycutOperator favoritesStoreIsSelected]];
	[self refreshStatusItemsContaining:[controller currentSearchText]];
}

- (void)statusPopoverController:(FloatcutStatusPopoverController *)controller didRequestActionForClippingIdentifier:(NSString *)clippingIdentifier
{
	self.preserveStatusPopoverSearchOnNextMenuUpdate = YES;
	BOOL success = [flycutOperator favoritesStoreIsSelected]
		? [flycutOperator moveFavoriteToPrimaryStoreWithIdentifier:clippingIdentifier]
		: [flycutOperator toggleFavoriteForClippingWithIdentifier:clippingIdentifier];
	if (success) {
		[self refreshStatusItemsContaining:[controller currentSearchText]];
		if (!menuUpdateScheduled)
			self.preserveStatusPopoverSearchOnNextMenuUpdate = NO;
	} else {
		self.preserveStatusPopoverSearchOnNextMenuUpdate = NO;
	}
}

- (void)statusPopoverController:(FloatcutStatusPopoverController *)controller didRequestClearFavorites:(NSNumber *)clearFavorites
{
	[self clearFavoritesStore:[clearFavorites boolValue] statusPopoverController:controller];
}

- (void)statusPopoverControllerDidRequestMergeAll:(FloatcutStatusPopoverController *)controller
{
    (void)controller;
    [self mergeClippingList:nil];
}

- (void)statusPopoverControllerDidRequestPreferences:(FloatcutStatusPopoverController *)controller
{
    (void)controller;
    [self showPreferencePanel:nil];
}

- (void)statusPopoverControllerDidRequestAbout:(FloatcutStatusPopoverController *)controller
{
    (void)controller;
    [self activateAndOrderFrontStandardAboutPanel:nil];
}

- (void)statusPopoverControllerDidRequestQuit:(FloatcutStatusPopoverController *)controller
{
    (void)controller;
    [NSApp terminate:nil];
}

- (void)statusPopoverControllerDidClose:(FloatcutStatusPopoverController *)controller
{
    (void)controller;
    statusItem.button.state = NSControlStateValueOff;
}

#pragma mark - Clipboard P2P Sync

- (BOOL)syncCoordinatorIsClipboardPaused:(FloatcutSyncCoordinator *)coordinator
{
	(void)coordinator;
	return [flycutOperator storeDisabled];
}

- (NSString *)syncCoordinator:(FloatcutSyncCoordinator *)coordinator
               didReceiveText:(NSString *)text
                     peerName:(NSString *)peerName
                 peerDeviceID:(NSString *)peerDeviceID
                       clipID:(NSString *)clipID
{
	(void)coordinator;
	(void)peerDeviceID;
	(void)clipID;
	if ([flycutOperator storeDisabled] || [text length] == 0)
		return @"skipped";
	NSArray *availableTypes = @[NSPasteboardTypeString];
	if ([flycutOperator shouldSkip:text ofType:NSPasteboardTypeString fromAvailableTypes:availableTypes])
		return @"skipped";

	NSString *source = [NSString stringWithFormat:@"Sync: %@", peerName ?: @"Device"];
	BOOL accepted = [flycutOperator addClipping:text
	                                    ofType:NSPasteboardTypeString
	                                   fromApp:source
	                            withAppBundleURL:nil
	                                     target:self
	                     clippingAddedSelector:@selector(updateMenu)];
	if (accepted)
		[[flycutOperator getClippingFromIndex:0] setReceivedFromSync:YES];

	// This is intentionally a direct, main-thread write with an explicit block
	// token. It never enters sendAcceptedLocalText:, so remote origin remains
	// one-hop even when normal duplicate removal is disabled.
	[jcPasteboard declareTypes:@[NSPasteboardTypeString] owner:nil];
	[jcPasteboard setString:text forType:NSPasteboardTypeString];
	[self setPBBlockCount:[jcPasteboard changeCount]];
	return accepted ? @"applied" : @"duplicate";
}

- (NSString *)syncCoordinator:(FloatcutSyncCoordinator *)coordinator
              didReceiveImage:(NSData *)data
                  contentType:(NSString *)contentType
                     peerName:(NSString *)peerName
                 peerDeviceID:(NSString *)peerDeviceID
                       clipID:(NSString *)clipID
{
	(void)coordinator;
	(void)peerDeviceID;
	(void)clipID;
	if ([flycutOperator storeDisabled] || [data length] == 0)
		return @"skipped";
	NSString *pasteboardType = [contentType isEqualToString:@"image/png"] ? NSPasteboardTypePNG : @"public.jpeg";
	NSString *source = [NSString stringWithFormat:@"Sync: %@", peerName ?: @"Device"];
	BOOL accepted = [flycutOperator addImageClippingData:data
	                                               ofType:pasteboardType
	                                              fromApp:source
	                                       withAppBundleURL:nil
	                                                target:self
	                                clippingAddedSelector:@selector(updateMenu)];
	if (accepted)
		[[flycutOperator getClippingFromIndex:0] setReceivedFromSync:YES];
	[jcPasteboard declareTypes:@[pasteboardType] owner:nil];
	[jcPasteboard setData:data forType:pasteboardType];
	[self setPBBlockCount:[jcPasteboard changeCount]];
	return accepted ? @"applied" : @"duplicate";
}

- (void) dealloc {
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
	[bezel release];
	[srTransformer release];
	[currentRunningApplication release];
	[searchRecorder release];
	[_swiftSearchWindowController release];
	[_swiftPreferencesWindowController release];
	[_statusPopoverController release];
	[searchWindow release]; // Legacy ivar retained for compatibility
	[searchResults release];
	[aboutPanel release];
	[dateFormat release];
	[listDateFormat release];
	[pbBlockedChangeCounts release];
	[super dealloc];
}

@end
