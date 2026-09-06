#import "FloatcutLocalization.h"

NSString *FCLocalizedString(NSString *key)
{
    return [[NSBundle mainBundle] localizedStringForKey:key value:key table:nil];
}
