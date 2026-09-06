//
//  FloatcutOperator.h
//  Floatcut
//
//  Flycut by Gennadiy Potapov and contributors. Based on Jumpcut by Steve Cook.
//  Copyright 2011 General Arcade. All rights reserved.
//
//  This code is open-source software subject to the MIT License; see the homepage
//  at <https://github.com/TermiT/Flycut> for details.
//

// FloatcutOperator owns and interacts with the FloatcutStores, providing
// manipulation of the stores.

#ifndef FloatcutOperator_h
#define FloatcutOperator_h

#import "FloatcutStore.h"

@protocol FloatcutOperatorDelegate <NSObject>
@optional
- (NSString*)alertWithMessageText:(NSString*)message informationText:(NSString*)information buttonsTexts:(NSArray*)buttons;
@end

@interface FloatcutOperator : NSObject <FloatcutStoreDeleteDelegate> {
    int							stackPosition;
    int							favoritesStackPosition;
    int							stashedStackPosition;

    FloatcutStore				*clippingStore;
    FloatcutStore				*favoritesStore;
    FloatcutStore				*stashedStore;

	SEL saveSelector;
	NSObject* saveTarget;
	int displayNum;
	int displayLength;

    BOOL disableStore;
	BOOL inhibitSaveEngineAfterListModification;
	BOOL inhibitAutosaveClippings;

	//Preferences
	BOOL issuedRememberResizeWarning;
    BOOL pendingDeferredSave;
	BOOL suppressNextTerminationSave;
}

// Basic functionality
-(int)indexOfClipping:(NSString*)contents ofType:(NSString*)type fromApp:(NSString *)appName withAppBundleURL:(NSString *)bundleURL;
-(bool)addClipping:(NSString*)contents ofType:(NSString*)type fromApp:(NSString *)appName withAppBundleURL:(NSString *)bundleURL target:(id)selectorTarget clippingAddedSelector:(SEL)clippingAddedSelector;
-(bool)addImageClippingData:(NSData*)imageData ofType:(NSString*)type fromApp:(NSString *)appName withAppBundleURL:(NSString *)bundleURL target:(id)selectorTarget clippingAddedSelector:(SEL)clippingAddedSelector;
-(BOOL)shouldSkip:(NSString *)contents ofType:(NSString *)type fromAvailableTypes:(NSArray<NSString *> *)availableTypes;
-(int)stackPosition;
-(NSString*)getPasteFromStackPosition;
-(NSString*)getPasteFromIndex:(int) position;
-(FloatcutClipping*)getClippingFromIndex:(int) position;
-(bool)moveClippingAtStackPositionToTop;
-(bool) saveFromStack;
-(bool)clearItemAtStackPosition;
-(void)clearList;
-(void)clearPrimaryList;
-(void)clearFavoritesList;
-(void)mergeList;

// Stack position manipulation functionality
-(bool)setStackPositionToOneMoreRecent;
-(bool)setStackPositionToOneLessRecent;
-(bool)setStackPositionToFirstItem;
-(bool)setStackPositionToLastItem;
-(bool)setStackPositionToTenMoreRecent;
-(bool)setStackPositionToTenLessRecent;
-(bool)setStackPositionTo:(int) newStackPosition;
-(void)adjustStackPositionIfOutOfBounds;
-(bool)stackPositionIsInBounds;

// Stack related
-(BOOL) isValidClippingNumber:(NSNumber *)number;
-(NSString *) clippingStringWithCount:(int)count;

// Save and load
-(void) saveEngine;
-(bool) loadEngineFromPList;
// Cancels deferred persistence before the app is relaunched after a manual
// preferences-domain migration.  The migrated domain must not be overwritten
// by the old in-memory stores during termination.
-(void) prepareForMigrationRestart;

// Preference related
-(void) willShowPreferences;
-(int) setRememberNum:(int)newRemember forPrimaryStore:(BOOL) isPrimaryStore;

// Initialization / cleanup related
-(void)applicationWillTerminate;;
-(void)awakeFromNibDisplaying:(int) displayNum withDisplayLength:(int) displayLength withSaveSelector:(SEL) selector forTarget:(NSObject*) target;

// Favorites Store related
-(bool)favoritesStoreIsSelected;
-(void)setFavoritesStoreSelected:(bool)selected;
-(void)switchToFavoritesStore;
-(bool)restoreStashedStore;
-(void)toggleToFromFavoritesStore;
-(bool)saveFromStackToFavorites;
-(NSSet *)favoriteClippingIdentifiers;
-(bool)isClippingFavoriteWithIdentifier:(NSString *)identifier;
-(bool)toggleFavoriteForClippingWithIdentifier:(NSString *)identifier;
-(bool)moveFavoriteToPrimaryStoreWithIdentifier:(NSString *)identifier;

// Clippings Store related
-(int)jcListCount;
-(int)rememberNum;
-(FloatcutClipping*)clippingAtStackPosition;
-(NSArray *) previousDisplayStrings:(int)howMany containing:(NSString*)search;
-(NSArray *) previousIndexes:(int)howMany containing:(NSString*)search; // This method is in newest-first order.
-(void)setDisableStoreTo:(bool) value;
-(bool)storeDisabled;
-(void)setClippingsStoreDelegate:(id<FloatcutStoreDelegate>) delegate;
-(void)setFavoritesStoreDelegate:(id<FloatcutStoreDelegate>) delegate;

/** optional delegate (not retained) */
@property (nonatomic, nullable, assign) id<FloatcutOperatorDelegate> delegate;

@end

#endif /* FloatcutOperator_h */
