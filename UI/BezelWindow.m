//
//  BezelWindow.m
//  Floatcut
//
//  Flycut by Gennadiy Potapov and contributors. Based on Jumpcut by Steve Cook.
//  Copyright 2011 General Arcade. All rights reserved.
//
//  This code is open-source software subject to the MIT License; see the homepage
//  at <https://github.com/TermiT/Flycut> for details.
//

#import "BezelWindow.h"
#import "Floatcut-Swift.h"

@implementation BezelWindow

- (id)initWithContentRect:(NSRect)contentRect
				styleMask:(NSUInteger)aStyle
  				backing:(NSBackingStoreType)bufferingType
					defer:(BOOL)flag
			   showSource:(BOOL)showSource
{
	self = [super initWithContentRect:contentRect
							styleMask:NSWindowStyleMaskNonactivatingPanel | NSWindowStyleMaskBorderless
							backing:NSBackingStoreBuffered
							defer:NO];
	if (!self)
		return nil;

	[self setLevel:NSScreenSaverWindowLevel];
	[self setOpaque:NO];
	[self setAlphaValue:1.0];
	[self setMovableByWindowBackground:NO];
	[self setHasShadow:YES];
	[self setBackgroundColor:[NSColor clearColor]];
	[self setColor:NO];

	showSourceField = showSource;
	previewImage = nil;

	NSView *containerView = [[[NSView alloc] initWithFrame:[[self contentView] bounds]] autorelease];
	containerView.wantsLayer = YES;
	containerView.layer.backgroundColor = NSColor.clearColor.CGColor;
	containerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	[self setContentView:containerView];

	modernContentView = [[FloatcutBezelContentView alloc] initWithFrame:containerView.bounds showSource:showSourceField];
	[(FloatcutBezelContentView *)modernContentView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
	[(FloatcutBezelContentView *)modernContentView setShowSource:showSourceField];
	[containerView addSubview:modernContentView];

	return self;
}

- (void)update
{
    [super update];
    [self setBackgroundColor:[NSColor clearColor]];
    if (modernContentView) {
        [modernContentView setFrame:[[self contentView] bounds]];
    }
}

- (NSColor *)roundedBackgroundWithRect:(NSRect)bgRect withRadius:(float)radius withAlpha:(float)alpha
{
	(void)bgRect;
	(void)radius;
	(void)alpha;
	return [NSColor clearColor];
}

- (NSColor *)sizedBezelBackgroundWithRadius:(float)radius withAlpha:(float)alpha
{
	(void)radius;
	(void)alpha;
	return [NSColor clearColor];
}

- (void)setAlpha:(float)newValue
{
	[super setAlphaValue:newValue];
}

- (NSString *)title
{
	return title;
}

- (void)setTitle:(NSString *)newTitle
{
	[newTitle retain];
	[title release];
	title = newTitle;
}

- (NSString *)text
{
	return bezelText;
}

- (void)setCharString:(NSString *)newChar
{
	[newChar retain];
	[charString release];
	charString = newChar;
	[(FloatcutBezelContentView *)modernContentView setStatusText:charString ?: @""];
}

- (void)setText:(NSString *)newText
{
    if ([newText length] > 2000)
        newText = [newText substringToIndex:2000];
	[newText retain];
	[bezelText release];
	bezelText = newText;
	[(FloatcutBezelContentView *)modernContentView setDisplayText:bezelText ?: @""];
}

- (void)setSourceIcon:(NSImage *)newSourceIcon
{
	if (!showSourceField)
		return;
	[newSourceIcon retain];
	[sourceIconImage release];
	sourceIconImage = newSourceIcon;
	[(FloatcutBezelContentView *)modernContentView setSourceIconImage:sourceIconImage];
}

- (void)setPreviewImage:(NSImage *)newPreviewImage
{
	[newPreviewImage retain];
	[previewImage release];
	previewImage = newPreviewImage;
	[(FloatcutBezelContentView *)modernContentView setPreviewImage:previewImage];
}

- (void)setShowSource:(BOOL)showSource
{
	showSourceField = showSource;
	[(FloatcutBezelContentView *)modernContentView setShowSource:showSource];
}

- (void)setSource:(NSString *)newSource
{
	if (!showSourceField)
		return;

	[newSource retain];
	[sourceText release];
	sourceText = newSource;
	[(FloatcutBezelContentView *)modernContentView setSourceText:sourceText ?: @""];
}

- (void)setDate:(NSString *)newDate
{
	if (!showSourceField)
		return;
	[newDate retain];
	[dateText release];
	dateText = newDate;
	[(FloatcutBezelContentView *)modernContentView setDateText:dateText ?: @""];
}

- (void)setColor:(BOOL)value
{
    color = value;
	[(FloatcutBezelContentView *)modernContentView setAccentMode:value];
}

-(BOOL)canBecomeKeyWindow
{
	return YES;
}

- (void)dealloc
{
	[charString release];
	[title release];
	[bezelText release];
	[sourceText release];
	[dateText release];
	[sourceIconImage release];
	[previewImage release];
	[modernContentView release];
	[super dealloc];
}

- (BOOL)performKeyEquivalent:(NSEvent*) theEvent
{
	if ( [self delegate] )
	{
		[delegate performSelector:@selector(processBezelKeyDown:) withObject:theEvent];
		return YES;
	}
	return NO;
}

- (void)scrollWheel:(NSEvent *)theEvent
{
    if ( [self delegate] )
    {
        [delegate performSelector:@selector(processBezelMouseEvents:) withObject:theEvent];
    }
}

- (void)mouseUp:(NSEvent *)theEvent
{
    if ( [self delegate] )
    {
       [delegate performSelector:@selector(processBezelMouseEvents:) withObject:theEvent];
    }
}

- (void)rightMouseUp:(NSEvent *)theEvent
{
    if ( [self delegate] )
    {
        [delegate performSelector:@selector(processBezelMouseEvents:) withObject:theEvent];
    }
}

- (void)keyDown:(NSEvent *)theEvent
{
	if ( [self delegate] )
	{
		[delegate performSelector:@selector(processBezelKeyDown:) withObject:theEvent];
	}
}

- (void)flagsChanged:(NSEvent *)theEvent
{
	if ( !    ( [theEvent modifierFlags] & NSEventModifierFlagCommand )
		 && ! ( [theEvent modifierFlags] & NSEventModifierFlagOption )
		 && ! ( [theEvent modifierFlags] & NSEventModifierFlagControl )
		 && ! ( [theEvent modifierFlags] & NSEventModifierFlagShift )
		 && [ self delegate ]
		 )
	{
		[delegate performSelector:@selector(metaKeysReleased)];
	}
}

- (id<BezelWindowDelegate>)delegate
{
    return delegate;
}

- (void)setDelegate:(id<BezelWindowDelegate>)newDelegate
{
    delegate = newDelegate;
	super.delegate = newDelegate;
}

@end
