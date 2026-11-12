#import <UIKit/UIKit.h>

CGSize BKSize(void);
void   BKRelayout(void);

BOOL   BKIsBusy(void);            // panel or editor open
void   BKSetInputGated(BOOL g);   // panel open -> capture drives UI only

void   BKCursorSet(BOOL on);
BOOL   BKCursorOn(void);
void   BKApplySettings(void);     // re-read core after a change
void   BKReleaseAll(void);

NSMutableArray *BKMarks(void);
void   BKRedrawMarkers(void);
void   BKSaveMarks(void);
void   BKReloadMarks(void);

void   BKPointerDelta(double dx, double dy);
void   BKButtonDown(int btn, BOOL down);
void   BKKeyUsage(int usage, BOOL down);

void   BKSetEditorOpen(BOOL open);
BOOL   BKEditorOpen(void);
int    BKSelectedMarker(void);
void   BKSelectMarker(int idx);

void   BKMenuOpen(void);
void   BKMenuClose(void);
void   BKEditorOpenUI(void);
