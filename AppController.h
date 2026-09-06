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

#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import "BezelWindow.h"
#import "SRRecorderControl.h"
#import "SRKeyCodeTransformer.h"
#import "FloatcutOperator.h"
#import "SGHotKey.h"

@class SGHotKey;

@interface AppController : NSResponder <NSMenuDelegate, NSApplicationDelegate, FloatcutStoreDelegate, FloatcutOperatorDelegate, BezelWindowDelegate> {
    BezelWindow					*bezel;
    NSUInteger                  bezelPreviewGeneration;
	SGHotKey					*mainHotKey;
	IBOutlet SRRecorderControl	*mainRecorder;
	SGHotKey					*searchHotKey;
	SRRecorderControl			*searchRecorder;
	IBOutlet NSPanel			*prefsPanel;
	NSPanel                     *aboutPanel;
	IBOutlet NSTextView			*acknowledgementsView;
	IBOutlet NSBox			  *appearancePanel;
	int							mainHotkeyModifiers;
	SRKeyCodeTransformer        *srTransformer;
	BOOL						isBezelDisplayed;
	BOOL						isBezelPinned;
	NSString					*currentKeycodeCharacter;
    NSDateFormatter*            dateFormat;
    NSDateFormatter*            listDateFormat;
	
	// Search window components
	NSWindow					*searchWindow;
	NSSearchField				*searchWindowSearchField;
	NSTableView					*searchWindowTableView;
	NSArray						*searchResults;
	BOOL						isSearchWindowDisplayed;

    FloatcutOperator				*flycutOperator;

    // Status item -- the little icon in the menu bar
    NSStatusItem *statusItem;
    NSString *statusItemText;
    NSImage *statusItemImage;
    
    IBOutlet NSTextField *savingSectionLabel;
    IBOutlet NSTextField *saveFromBezelToLabel;
    IBOutlet NSTextField *forgottenItemLabel;
    IBOutlet NSButton *forgottenFavoritesCheckbox;
    IBOutlet NSButton *forgottenClippingsCheckbox;
    IBOutlet NSButton *saveToLocationButton;
    IBOutlet NSButton *autoSaveToLocationButton;
    // The menu attatched to same
    IBOutlet NSMenu *jcMenu;
    int jcMenuBaseItemsCount;
    IBOutlet NSSearchField *searchBox;
    NSResponder *menuFirstResponder;
    NSRunningApplication *currentRunningApplication;
    NSEvent *menuOpenEvent;
    IBOutlet NSSlider * heightSlider;
    IBOutlet NSSlider * widthSlider;
    
    // A timer which will let us check the pasteboard;
    // this should default to every .5 seconds but be user-configurable
    NSTimer *pollPBTimer;
    // We want an interface to the pasteboard
    NSPasteboard *jcPasteboard;
    // Track the clipboard count so we only act when its contents change
	NSInteger pbCount;
    // Stores PasteboardCount for internal Floatcut pasteboard actions so they don't trigger any events.
	NSInteger pbBlockCount;
    // Bounded set of Floatcut/Sync-owned pasteboard writes. A set is used
    // instead of only one count so rapid remote writes cannot be mistaken for
    // a later local copy when asynchronous Handoff materialization is active.
    NSMutableOrderedSet *pbBlockedChangeCounts;
    //Preferences
	NSDictionary *standardPreferences;
    int jcDisplayNum;
	BOOL needBezelUpdate;
	BOOL needMenuUpdate;
	BOOL menuUpdateScheduled;
}

// Basic functionality
-(void) pollPB:(NSTimer *)timer;
-(void) addClipToPasteboard:(NSString*)pbFullText;
-(void) setPBBlockCount:(NSInteger)newPBBlockCount;
-(void) hideApp;
-(void) fakeCommandV;
-(IBAction)clearClippingList:(id)sender;
-(IBAction)mergeClippingList:(id)sender;
-(void)controlTextDidChange:(NSNotification *)aNotification;
-(BOOL)control:(NSControl *)control textView:(NSTextView *)fieldEditor doCommandBySelector:(SEL)commandSelector;
-(IBAction)searchItems:(id)sender;

// Hotkey related
-(void)hitMainHotKey:(SGHotKey *)hotKey;
-(void)hitSearchHotKey:(SGHotKey *)hotKey;
-(IBAction)toggleSearchHotKey:(id)sender;

// Search window related
-(void) showSearchWindow;
-(void) hideSearchWindow;
-(void) buildSearchWindow;
-(void) updateSearchResults;
-(IBAction)searchWindowItemSelected:(id)sender;
-(void) cancelOperation:(id)sender;
-(void) performClose:(id)sender;

// Bezel related
-(void) updateBezel;
-(void) showBezel;
-(void) hideBezel;
-(void) processBezelKeyDown:(NSEvent *)theEvent;
-(void) processBezelMouseEvents:(NSEvent *)theEvent;
-(void) metaKeysReleased;
-(void) windowDidResignKey:(NSNotification *)notification;

// Menu related
-(void) updateMenu;
-(IBAction) processMenuClippingSelection:(id)sender;
-(IBAction) activateAndOrderFrontStandardAboutPanel:(id)sender;

// Preference related
-(IBAction) showPreferencePanel:(id)sender;
-(IBAction) setRememberNumPref:(id)sender;
-(IBAction) setFavoritesRememberNumPref:(id)sender;
-(IBAction) setDisplayNumPref:(id)sender;
-(IBAction) setBezelAlpha:(id)sender;
-(IBAction) setBezelHeight:(id)sender;
-(IBAction) setBezelWidth:(id)sender;
-(IBAction) switchMenuIcon:(id)sender;
-(IBAction) toggleLoadOnStartup:(id)sender;
-(IBAction) toggleMainHotKey:(id)sender;
-(IBAction) recheckAccessibility:(id)sender;
-(IBAction) setSavePreference:(id)sender;
-(void) setHotKeyPreferenceForRecorder:(SRRecorderControl *)aRecorder;

@end
