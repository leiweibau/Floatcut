#ifndef FloatcutStatusMenuUpdateState_h
#define FloatcutStatusMenuUpdateState_h

#import <Foundation/Foundation.h>

// Main-thread-only coalescing state for status-menu snapshots. A request may
// upgrade an already scheduled refresh to preserve the current search.
typedef struct {
    BOOL scheduled;
    BOOL preserveSearch;
} FloatcutStatusMenuUpdateState;

static inline BOOL FloatcutScheduleStatusMenuUpdate(FloatcutStatusMenuUpdateState *state)
{
    if (state->scheduled)
        return NO;
    state->scheduled = YES;
    return YES;
}

static inline BOOL FloatcutConsumeStatusMenuUpdate(FloatcutStatusMenuUpdateState *state)
{
    state->scheduled = NO;
    BOOL preserveSearch = state->preserveSearch;
    state->preserveSearch = NO;
    return preserveSearch;
}

static inline BOOL FloatcutShouldRenderStatusMenuUpdate(BOOL statusButtonEnabled, BOOL popoverShown)
{
    return statusButtonEnabled && popoverShown;
}

static inline NSString *FloatcutStatusMenuSearchForUpdate(BOOL preserveSearch, NSString *currentSearch)
{
    return preserveSearch ? currentSearch : nil;
}

#endif
