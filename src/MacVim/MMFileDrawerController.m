#import "MMFileDrawerController.h"
#import "MMWindowController.h"
#import "MMAppController.h"
#import "ImageAndTextCell.h"
#import "Miscellaneous.h"
#import "MMVimController.h"

#import <CoreServices/CoreServices.h>

// ****************************************************************************
// File system model
// ****************************************************************************

// The FileSystemItem class is an adaptation of Apple's example in the Outline
// View Programming Topics document.

@interface FileSystemItem : NSObject {
  NSString *path;
  FileSystemItem *parent;
  NSMutableArray *children;
  MMVimController *vim;
  NSImage *icon;
  BOOL includesHiddenFiles;
  BOOL ignoreNextReload;
}

@property (nonatomic, assign) BOOL includesHiddenFiles, ignoreNextReload, useWildIgnore;
@property (readonly) FileSystemItem *parent;

- (id)initWithPath:(NSString *)path parent:(FileSystemItem *)parentItem vim:(MMVimController *)vim;
- (NSInteger)numberOfChildren; // Returns -1 for leaf nodes
- (FileSystemItem *)childAtIndex:(NSUInteger)n; // Invalid to call on leaf nodes
- (NSString *)fullPath;
- (NSString *)relativePath;
- (BOOL)isLeaf;
- (void)clear;
- (BOOL)reloadRecursive:(BOOL)recursive;
- (FileSystemItem *)itemAtPath:(NSString *)itemPath;
- (FileSystemItem *)itemWithName:(NSString *)name;
- (NSArray *)parents;

@end

@interface FileSystemItem (Private)
- (FileSystemItem *)_itemAtPath:(NSArray *)components;
- (BOOL)_ignoreFile:(NSString *)filename;
@end


@implementation FileSystemItem

static NSMutableArray *leafNode = nil;

+ (void)initialize {
  if (self == [FileSystemItem class]) {
    leafNode = [[NSMutableArray alloc] init];
  }
}

@synthesize parent, includesHiddenFiles, ignoreNextReload, useWildIgnore;

- (id)initWithPath:(NSString *)thePath parent:(FileSystemItem *)parentItem vim:(MMVimController *)vimInstance {
  if ((self = [super init])) {
    icon = nil;
    path = [thePath retain];
    parent = parentItem;
    vim = vimInstance;
    if (parent) {
      includesHiddenFiles = parent.includesHiddenFiles;
      useWildIgnore = parent.useWildIgnore;
    } else {
      includesHiddenFiles = NO;
      useWildIgnore = YES;
    }
    ignoreNextReload = NO;
  }
  return self;
}

// * Creates, caches, and returns the array of children
// * Loads children incrementally
- (NSArray *)children {
  if (children == nil) {
    NSFileManager *fileManager = [NSFileManager defaultManager];

    BOOL isDir, valid;
    valid = [fileManager fileExistsAtPath:path isDirectory:&isDir];
    if (valid && isDir) {
      // Create a dummy array, which is replaced by -[FileSystemItem reloadRecursive]
      children = [NSArray new];
      [self reloadRecursive:NO];
    } else {
      children = leafNode;
    }
  }
  return children;
}

- (void)clear {
  [children release];
  children = nil;
}

// Returns YES if the children have been reloaded, otherwise it returns NO.
//
// This is really only so the controller knows whether or not to reload the view.
- (BOOL)reloadRecursive:(BOOL)recursive {
  if (children) {
    // Only reload items that have been loaded before
    // NSLog(@"Reload: %@", path);
    if (parent) {
      includesHiddenFiles = parent.includesHiddenFiles;
      useWildIgnore = parent.useWildIgnore;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSMutableArray *reloaded;

    NSArray *entries = [fileManager contentsOfDirectoryAtPath:path error:NULL];
    reloaded = [[NSMutableArray alloc] initWithCapacity:[entries count]];

    for (NSString *childName in entries) {
      if ([self _ignoreFile:childName]) {
        continue;
      }

      FileSystemItem *child = nil;
      // Check if we already have an item for the child path
      for (FileSystemItem *item in children) {
        if ([[item relativePath] isEqualToString:childName]) {
          child = item;
          break;
        }
      }
      if (child) {
        // NSLog(@"Already have item for child: %@", childName);
        // If an item already existed use it and reload its children
        [reloaded addObject:child];
        if (recursive && ![child isLeaf]) {
          [child reloadRecursive:YES];
        }
        [children removeObject:child];
      } else {
        // New child, so create a new item
        child = [[FileSystemItem alloc] initWithPath:[path stringByAppendingPathComponent:childName]
                                              parent:self
                                                 vim:vim];
        [reloaded addObject:child];
        [child release];
      }
    }

    [children release];
    children = reloaded;
    return YES;
  } else {
    // NSLog(@"Not loaded yet, so don't reload: %@", path);
  }
  return NO;
}

- (BOOL)_ignoreFile:(NSString *)filename {
  BOOL isHiddenFile = [filename characterAtIndex:0] == '.';
  if (isHiddenFile && !includesHiddenFiles) {
    // It's a hidden file which are currently not visible.
    return YES;
  } else if (isHiddenFile && [filename length] >= 4) {
    // Does include hidden files, but never add Vim swap files to browser.
    //
    // Vim swap files have names of type
    //   .original-file-name.sXY
    // where XY can be anything from "aa" to "wp".
    NSString *last3 = [filename substringFromIndex:[filename length]-3];
    if ([last3 compare:@"saa"] >= 0 && [last3 compare:@"swp"] <= 0) {
      // It's a swap file, ignore it.
      return YES;
    }
  } else if (useWildIgnore) {
    NSString *eval = [NSString stringWithFormat:@"empty(expand(fnameescape('%@')))", filename];
    NSString *result = [vim evaluateVimExpression:eval];
    return [result isEqualToString:@"1"];
  }
  return NO;
}

- (BOOL)isLeaf {
  if (children) {
    return children == leafNode;
  } else {
    BOOL isDir;
    [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir];
    return !isDir;
  }
}

// Returns `self' if it's a directory item, otherwise it returns the parent item.
- (FileSystemItem *)dirItem {
  return [self isLeaf] ? parent : self;
}

- (NSString *)relativePath {
  return [path lastPathComponent];
}

- (NSString *)fullPath {
  return path;
}

- (FileSystemItem *)childAtIndex:(NSUInteger)n {
  return [[self children] objectAtIndex:n];
}

- (NSInteger)numberOfChildren {
  if ([self isLeaf]) {
    return -1;
  } else {
    return [[self children] count];
  }
}

// TODO for now we don't really resize
- (NSImage *)icon {
  if (icon == nil) {
    icon = [[NSWorkspace sharedWorkspace] iconForFiles:[NSArray arrayWithObject:path]];
    [icon retain];
    [icon setSize:NSMakeSize(16, 16)];
  }
  return icon;
}

- (FileSystemItem *)itemAtPath:(NSString *)itemPath {
  if ([itemPath hasSuffix:@"/"])
    itemPath = [itemPath stringByStandardizingPath];
  NSArray *components = [itemPath pathComponents];
  NSArray *root = [path pathComponents];

  // check if itemPath is enclosed into the current directory
  if([components count] < [root count])
    return nil;
  if(![[components subarrayWithRange:NSMakeRange(0, [root count])] isEqualToArray:root])
    return nil;

  // minus one extra because paths from FSEvents have a trailing slash
  components = [components subarrayWithRange:NSMakeRange([root count], [components count] - [root count])];
  return [self _itemAtPath:components];
}

- (FileSystemItem *)_itemAtPath:(NSArray *)components {
  if ([components count] == 0) {
    return self;
  } else {
    FileSystemItem *child = [self itemWithName:[components objectAtIndex:0]];
    if (child) {
      return [child _itemAtPath:[components subarrayWithRange:NSMakeRange(1, [components count] - 1)]];
    }
  }
  return nil;
}

- (FileSystemItem *)itemWithName:(NSString *)name {
  for (FileSystemItem *child in [self children]) {
    if ([[child relativePath] isEqualToString:name]) {
      return child;
    }
  }
  return nil;
}

- (NSArray *)parents {
  NSMutableArray *result = [[[NSMutableArray alloc] init] autorelease];
  id item = parent;
  while(item != nil) {
    [result addObject:item];
    item = [item parent];
  }
  return result;
}

- (void)dealloc {
  if (children != leafNode) {
    [children release];
  }
  [path release];
  [icon release];
  vim = nil;
  [super dealloc];
}

@end

// ****************************************************************************
// Outline view
// ****************************************************************************

#define ENTER_KEY_CODE 36
#define J_KEY_CODE 38
#define DOWN_KEY_CODE 125
#define K_KEY_CODE 40
#define UP_KEY_CODE 126

static NSString *DOWN_KEY_CHAR, *UP_KEY_CHAR;

@interface FilesOutlineView : NSOutlineView {
  BOOL canBecomeFirstResponder;
}
- (void)makeFirstResponder;
- (NSMenu *)menuForEvent:(NSEvent *)event;
- (void)cancelOperation:(id)sender;
- (void)expandParentsOfItem:(id)item;
- (void)selectItem:(id)item;
@end

@implementation FilesOutlineView

- (id)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    canBecomeFirstResponder = NO;
  }
  return self;
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (BOOL)becomeFirstResponder {
  if (canBecomeFirstResponder) {
    [self setNeedsDisplay];
  }
  return canBecomeFirstResponder;
}

- (BOOL)resignFirstResponder {
  canBecomeFirstResponder = NO;
  [self setNeedsDisplay];
  return YES;
}

- (void)makeFirstResponder {
  canBecomeFirstResponder = YES;
  [[self window] makeFirstResponder:self];
}

- (void)cancelOperation:(id)sender {
  // Pressing Esc will select the next key view, which should be the text view
  [[self window] selectNextKeyView:nil];
}

- (void)keyDown:(NSEvent *)event {
  switch (event.keyCode) {
  case ENTER_KEY_CODE:
    [(id<NSOutlineViewDelegate>)self.delegate outlineViewSelectionIsChanging:nil];
    [(id<NSOutlineViewDelegate>)self.delegate outlineViewSelectionDidChange:nil];
    return;

  case J_KEY_CODE:
    DOWN_KEY_CHAR = [NSString stringWithFormat:@"%C", 0xf701];
    event = [NSEvent keyEventWithType:event.type
                             location:event.locationInWindow
                        modifierFlags:event.modifierFlags
                            timestamp:event.timestamp
                         windowNumber:event.windowNumber
                              context:event.context
                           characters:DOWN_KEY_CHAR
          charactersIgnoringModifiers:DOWN_KEY_CHAR
                            isARepeat:event.isARepeat
                              keyCode:DOWN_KEY_CODE];
    break;

  case K_KEY_CODE:
    UP_KEY_CHAR = [NSString stringWithFormat:@"%C", 0xf700];
    event = [NSEvent keyEventWithType:event.type
                             location:event.locationInWindow
                        modifierFlags:event.modifierFlags
                            timestamp:event.timestamp
                         windowNumber:event.windowNumber
                              context:event.context
                           characters:UP_KEY_CHAR
          charactersIgnoringModifiers:UP_KEY_CHAR
                            isARepeat:event.isARepeat
                              keyCode:UP_KEY_CODE];
    break;
  }
  [super keyDown:event];
}

- (NSMenu *)menuForEvent:(NSEvent *)event {
  NSInteger row = [self rowAtPoint:[self convertPoint:[event locationInWindow] fromView:nil]];
  if ([self numberOfSelectedRows] <= 1) {
    [self selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
  }
  return [(MMFileDrawerController *)[self delegate] menuForRow:row];
}

- (void)expandParentsOfItem:(id)item {
  NSArray *parents = [item parents];
  NSEnumerator *e = [parents reverseObjectEnumerator];

  // expand root node
  [self expandItem: nil];

  id parent;
  while((parent = [e nextObject])) {
    if(![self isExpandable:parent])
      break;
    if(![self isItemExpanded:parent])
      [self expandItem: parent];
  }
}

- (void)selectItem:(id)item {
  NSInteger itemIndex = [self rowForItem:item];
  if(itemIndex < 0) {
    [self expandParentsOfItem:item];
    itemIndex = [self rowForItem: item];
    if(itemIndex < 0)
      return;
  }
  [self selectRowIndexes:[NSIndexSet indexSetWithIndex:itemIndex] byExtendingSelection:NO];
  [self scrollRowToVisible:itemIndex];
}

@end

// ****************************************************************************
// Controller
// ****************************************************************************

@interface MMFileDrawerController (Private)
- (FilesOutlineView *)outlineView;
- (void)pwdChanged:(NSNotification *)notification;
- (void)changeWorkingDirectory:(NSString *)path;
- (NSArray *)selectedItemPaths;
- (void)openSelectedFilesInCurrentWindowWithLayout:(int)layout;
- (NSArray *)appsAssociatedWithItem:(FileSystemItem *)item;
- (FileSystemItem *)itemAtRow:(NSInteger)row;
- (void)watchRoot;
- (void)unwatchRoot;
- (void)changeOccurredAtPath:(NSString *)path;
@end


@implementation MMFileDrawerController

- (id)initWithWindowController:(MMWindowController *)controller {
  if ((self = [super initWithNibName:nil bundle:nil])) {
    windowController = controller;
    rootItem = nil;
    fsEventsStream = NULL;
    userHasChangedSelection = NO;
  }
  return self;
}


- (void)loadView {
  NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
  NSRectEdge edge = [ud integerForKey:MMDrawerPreferredEdgeKey] <= 0
                  ? NSMaxXEdge
                  : NSMinXEdge;

  drawer = [[NSDrawer alloc] initWithContentSize:NSMakeSize(200, 0)
                                   preferredEdge:edge];

  FlippedView *drawerView = [[[FlippedView alloc] initWithFrame:NSZeroRect] autorelease];
  [drawerView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

  FilesOutlineView *filesView = [[[FilesOutlineView alloc] initWithFrame:NSZeroRect] autorelease];
  [filesView setDelegate:self];
  [filesView setDataSource:self];
  [filesView setHeaderView:nil];
  [filesView setAllowsMultipleSelection:YES];
  NSTableColumn *column = [[[NSTableColumn alloc] initWithIdentifier:nil] autorelease];
  ImageAndTextCell *cell = [[[ImageAndTextCell alloc] init] autorelease];
  [cell setEditable:YES];
  [column setDataCell:cell];
  [filesView addTableColumn:column];
  [filesView setOutlineTableColumn:column];
  // Typing Tab (or Esc) in browser view sets keyboard focus to text view
  [filesView setNextKeyView:[[windowController vimView] textView]];

  pathControl = [[NSPathControl alloc] initWithFrame:NSMakeRect(0, 0, 0, 20)];
  [pathControl setRefusesFirstResponder:YES];
  [pathControl setAutoresizingMask:NSViewWidthSizable];
  [pathControl setBackgroundColor:[NSColor whiteColor]];
  [pathControl setPathStyle:NSPathStylePopUp];
  [pathControl setFont:[NSFont fontWithName:[[pathControl font] fontName] size:12]];
  [pathControl setTarget:self];
  [pathControl setAction:@selector(changeWorkingDirectoryFromPathControl:)];
  
  // NOTE: does this belong here?
  [pathControl setURL:[NSURL fileURLWithPath:[rootItem fullPath]]];

  NSScrollView *scrollView = [[[NSScrollView alloc] initWithFrame:NSMakeRect(0, 25, 0, 0)] autorelease];
  [scrollView setHasHorizontalScroller:YES];
  [scrollView setHasVerticalScroller:YES];
  [scrollView setAutohidesScrollers:YES];
  [scrollView setDocumentView:filesView];

  [scrollView setFrame:CGRectMake(0, pathControl.frame.size.height, 0, 0)];
  [scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

  [drawerView addSubview:scrollView];
  [drawerView addSubview:pathControl];
  [drawer setContentView:drawerView];

  [self setView:filesView];

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(pwdChanged:)
                                               name:@"MMPwdChanged"
                                             object:[windowController vimController]];
}


- (void)setRoot:(NSString *)root
{
  root = [root stringByStandardizingPath];

  BOOL isDir;
  BOOL valid = [[NSFileManager defaultManager] fileExistsAtPath:root
                                                    isDirectory:&isDir];
  if (!(valid && isDir))
    return;

  if (rootItem) {
    [self unwatchRoot];
    [rootItem autorelease];
    rootItem = nil;
  }

  rootItem = [[FileSystemItem alloc] initWithPath:root parent:nil];
  [pathControl setURL:[NSURL fileURLWithPath:root]];
  [(NSOutlineView *)[self view] expandItem:rootItem];
  [self watchRoot];
}

- (void)open
{
  if([drawer state] == NSDrawerOpenState || [drawer state] == NSDrawerOpeningState)
    return;
  if (!rootItem) {
    NSString *root = [[windowController vimController]
                                                  objectForVimStateKey:@"pwd"];
    [self setRoot:(root ? root : @"~/")];
  }

  [drawer setParentWindow:[windowController window]];
  [drawer open];
}

- (void)close
{
  if([drawer state] == NSDrawerClosedState || [drawer state] == NSDrawerClosingState)
    return;
  [drawer close];
}

- (void)toggle
{
  if (!rootItem) {
    NSString *root = [[windowController vimController]
                                                  objectForVimStateKey:@"pwd"];
    [self setRoot:(root ? root : @"~/")];
  }

  [drawer setParentWindow:[windowController window]];
  [drawer toggle:self];

  [self selectInDrawer];
}

- (void)selectInDrawer {
  if([drawer state] != NSDrawerOpeningState && [drawer state] != NSDrawerOpenState)
    return;
  NSString *fn = [[windowController vimController]
                                                  evaluateVimExpression:@"expand('%:p')"];
  if([fn length] > 0) {
    FileSystemItem *item = [rootItem itemAtPath:fn];
    [[self outlineView] selectItem:item];
  }
}

- (FileSystemItem *)itemAtRow:(NSInteger)row {
  return [[self outlineView] itemAtRow:row];
}

- (NSArray *)selectedItemPaths {
  NSMutableArray *paths = [NSMutableArray array];
  NSIndexSet *indexes = [[self outlineView] selectedRowIndexes];
  [indexes enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
    FileSystemItem *item = [self itemAtRow:index];
    if ([item isLeaf]) {
      [paths addObject:[item fullPath]];
    }
  }];
  return paths;
}

- (void)changeWorkingDirectory:(NSString *)path {
  BOOL isDir;
  if([[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir]) {
    if(!isDir) path = [path stringByDeletingLastPathComponent];
    // Tell Vim to change the pwd.  As a side effect this will cause a new root
    // to be set to the folder the user just double-clicked on.
    NSString *input = [NSString stringWithFormat:
                                   @"<C-\\><C-N>:exe \"cd \" . fnameescape(\"%@\")<CR>", path];
    [[windowController vimController] addVimInput:input];
  }
}

// Ignores the user's preference by always opening in the current window for the
// duration of the block. It restores, in addition, the layout preference.
//
// Any directory in `paths' is ignored.
- (void)openSelectedFilesInCurrentWindowWithLayout:(int)layout {
  NSArray *paths = [self selectedItemPaths];
  if ([paths count] > 0) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    BOOL openInCurrentWindow = [ud boolForKey:MMOpenInCurrentWindowKey];
    [ud setBool:YES forKey:MMOpenInCurrentWindowKey];
    int layoutBefore = [ud integerForKey:MMOpenLayoutKey];
    [ud setInteger:layout forKey:MMOpenLayoutKey];

    [(MMAppController *)[NSApp delegate] openFiles:paths withArguments:nil];

    [ud setBool:openInCurrentWindow forKey:MMOpenInCurrentWindowKey];
    [ud setInteger:layoutBefore forKey:MMOpenLayoutKey];
  }
}

// TODO move into FileSystemItem
- (NSArray *)appsAssociatedWithItem:(FileSystemItem *)item {
  NSString *uti = [[NSWorkspace sharedWorkspace] typeOfFile:[item fullPath] error:NULL];
  if (uti) {
    NSArray *identifiers = (NSArray *)LSCopyAllRoleHandlersForContentType((CFStringRef)uti, kLSRolesAll);
    NSMutableArray *paths = [NSMutableArray array];
    for (NSString *identifier in identifiers) {
      NSString *appPath = [[NSWorkspace sharedWorkspace] absolutePathForAppBundleWithIdentifier:identifier];
      if (appPath) {
        [paths addObject:appPath];
      }
    }
    [identifiers release];
    return [paths count] == 0 ? nil : paths;
  }
  return nil;
}


// Data Source methods
// ===================

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item {
  if (item == nil) {
    item = rootItem;
  }
  return [item numberOfChildren];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item {
  if (item == nil) {
    item = rootItem;
  }
  return ([item numberOfChildren] != -1);
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(id)item {
  if (item == nil) {
    item = rootItem;
  }
  return [(FileSystemItem *)item childAtIndex:index];
}

- (id)outlineView:(NSOutlineView *)outlineView objectValueForTableColumn:(NSTableColumn *)tableColumn byItem:(id)item {
  if (item == nil) {
    item = rootItem;
  }
  return [item relativePath];
}


// Delegate methods
// ================

- (NSMenu *)menuForRow:(NSInteger)row {
  NSMenu *menu = [[NSMenu new] autorelease];
  NSMenuItem *item;
  NSString *title;
  FileSystemItem *fsItem = [self itemAtRow:row];
  BOOL isLeaf = [fsItem isLeaf];

  // File operations
  [menu addItemWithTitle:@"New File" action:@selector(newFile:) keyEquivalent:@""];
  [menu addItemWithTitle:@"New Folder" action:@selector(newFolder:) keyEquivalent:@""];
  if (fsItem) {
    [menu addItemWithTitle:@"Rename…" action:@selector(renameFile:) keyEquivalent:@""];
    [menu addItemWithTitle:@"Delete selected Files" action:@selector(deleteSelectedFiles:) keyEquivalent:@""];

    // Vim open/cwd
    [menu addItem:[NSMenuItem separatorItem]];
    if (isLeaf) {
      [menu addItemWithTitle:@"Open selected Files in Tabs" action:@selector(openFilesInTabs:) keyEquivalent:@""];
      [menu addItemWithTitle:@"Open selected Files in Horizontal Split Views" action:@selector(openFilesInHorizontalSplitViews:) keyEquivalent:@""];
      [menu addItemWithTitle:@"Open selected Files in Vertical Split Views" action:@selector(openFilesInVerticalSplitViews:) keyEquivalent:@""];
    }
    title = [NSString stringWithFormat:@"Change working directory to “%@”", [[fsItem dirItem] relativePath]];
    [menu addItemWithTitle:title action:@selector(changeWorkingDirectoryToSelection:) keyEquivalent:@""];

    // Open elsewhere
    NSString *filename = [fsItem relativePath];
    [menu addItem:[NSMenuItem separatorItem]];
    title = [NSString stringWithFormat:@"Reveal “%@” in Finder", filename];
    [menu addItemWithTitle:title action:@selector(revealInFinder:) keyEquivalent:@""];
    title = [NSString stringWithFormat:@"Open “%@” with Finder", filename];
    [menu addItemWithTitle:title action:@selector(openWithFinder:) keyEquivalent:@""];
    // open with app submenu
    title = [NSString stringWithFormat:@"Open “%@” with…", filename];
    NSMenuItem *openWithFinderItem = [menu addItemWithTitle:title action:NULL keyEquivalent:@""];
    NSArray *appPaths = [self appsAssociatedWithItem:fsItem];
    if (appPaths) {
      NSMenu *submenu = [[NSMenu new] autorelease];
      NSInteger i;
      for (i = 0; i < [appPaths count]; i++) {
        NSString *appPath = [appPaths objectAtIndex:i];
        NSString *appName = [[NSFileManager defaultManager] displayNameAtPath:appPath];
        NSImage *appIcon = [[NSWorkspace sharedWorkspace] iconForFile:appPath];
        [appIcon setSize:NSMakeSize(16, 16)];
        item = [submenu addItemWithTitle:appName action:@selector(openFileWithApp:) keyEquivalent:@""];
        [item setTarget:self];
        [item setTag:i];
        [item setImage:appIcon];
      }
      [openWithFinderItem setSubmenu:submenu];
    }
  }

  // Misc
  [menu addItem:[NSMenuItem separatorItem]];
  item = [menu addItemWithTitle:@"Show hidden Files" action:@selector(toggleShowHiddenFiles:) keyEquivalent:@""];
  [item setState:rootItem.includesHiddenFiles ? NSOnState : NSOffState];

  for (item in [menu itemArray]) {
    [item setTarget:self];
    [item setTag:row];
    [item setRepresentedObject:[fsItem fullPath]];
  }
  return menu;
}

// TODO is this the proper way to differentiate between selection changes because the user selected a file
// and a programmatic selection change?
- (void)outlineViewSelectionIsChanging:(NSNotification *)aNotification {
  userHasChangedSelection = YES;
}

- (void)outlineViewSelectionDidChange:(NSNotification *)notification {
  if (userHasChangedSelection && [[self outlineView] numberOfSelectedRows] == 1) {
    NSEvent *event = [NSApp currentEvent];
    int layout = [[NSUserDefaults standardUserDefaults] integerForKey:MMOpenLayoutKey];
    if ([event modifierFlags] & NSAlternateKeyMask) {
      if (layout == MMLayoutTabs) {
        // The user normally creates a new tab when opening a file,
        // so open this file in the current one
        layout = MMLayoutArglist;
      } else {
        // The user normally opens a file in the current tab,
        // so open this file in a new one
        layout = MMLayoutTabs;
      }
    }
    [self openSelectedFilesInCurrentWindowWithLayout:layout];
  }
  userHasChangedSelection = NO;
}

- (void)outlineView:(NSOutlineView *)outlineView willDisplayCell:(NSCell *)cell forTableColumn:(NSTableColumn *)tableColumn item:(id)item {
  [(ImageAndTextCell *)cell setImage:[item icon]];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView
        shouldEditTableColumn:(NSTableColumn *)tableColumn
                         item:(id)item
{
  // Called when an item was double-clicked, in which case we do make the browser the first responder.
  [outlineView makeFirstResponder];
  return NO;
}

- (void)outlineView:(NSOutlineView *)outlineView setObjectValue:(NSString *)name forTableColumn:(NSTableColumn *)tableColumn byItem:(FileSystemItem *)item {
  // save these here, cause by moving the file and reloading the view 'item' will be released
  BOOL isLeaf = [item isLeaf];
  NSString *fullPath = [item fullPath];

  FileSystemItem *dirItem = item.parent;
  NSString *newPath = [[dirItem fullPath] stringByAppendingPathComponent:name];
  NSError *error = nil;
  dirItem.ignoreNextReload = YES;
  BOOL moved = [[NSFileManager defaultManager] moveItemAtPath:fullPath
                                                       toPath:newPath
                                                        error:&error];
  if (moved) {
    [dirItem reloadRecursive:NO];
    if(dirItem == rootItem)
      [[self outlineView] reloadData];
    else
      [[self outlineView] reloadItem:dirItem reloadChildren:YES];
    // Select the renamed item
    NSInteger row = [[self outlineView] rowForItem:[dirItem itemWithName:name]];
    NSIndexSet *index = [NSIndexSet indexSetWithIndex:row];
    [[self outlineView] selectRowIndexes:index byExtendingSelection:NO];
    if(isLeaf) {
      NSString *input = [NSString string];
      newPath = [newPath stringByEscapingSpecialFilenameCharacters];
      MMVimController *vim = [windowController vimController];
      NSString *bufName = [vim evaluateVimExpression:[NSString stringWithFormat:@"bufname('%@')", fullPath]];
      if([bufName length] != 0) {
        input = [NSString stringWithFormat:@"<C-\\><C-N>"
                                         ":bdelete! %@<CR>", bufName];
      }
      input = [input stringByAppendingString:[NSString stringWithFormat:@"<C-\\><C-N>"
                                           ":edit %@<CR>", newPath]];
      [vim addVimInput:input];
    }
    else {
      // TODO: should reopen all open buffers with files inside of this directory
    }
  } else {
    dirItem.ignoreNextReload = NO;
    NSLog(@"[!] Unable to rename `%@' to `%@'. Error: %@", [item fullPath], newPath, [error localizedDescription]);
  }
}


// Actions
// =======

- (void)renameFile:(NSMenuItem *)sender {
  FileSystemItem *item = [self itemAtRow:[sender tag]];
  NSLog(@"Rename: %@", [item fullPath]);
  [(FilesOutlineView *)[self view] editColumn:0 row:[sender tag] withEvent:nil select:YES];
}

- (void)newFile:(NSMenuItem *)sender {
  FileSystemItem *item = [self itemAtRow:[sender tag]];
  if(!item) item = rootItem;
  if([item isLeaf]) item = [item parent];
  NSString *path = [[item fullPath] stringByAppendingPathComponent:@"new file"];

  int i = 2;
  NSString *result = path;
  NSFileManager *fileManager = [NSFileManager defaultManager];
  while ([fileManager fileExistsAtPath:result]) {
   result = [NSString stringWithFormat:@"%@ %d", path, i];
   i++;
  }

  item.ignoreNextReload = YES;
  BOOL isOK = [fileManager createFileAtPath:result contents:[NSData data] attributes:nil];
  if(isOK) {
    [item reloadRecursive: NO];
    if(item == rootItem)
      [[self outlineView] reloadData];
    else
      [[self outlineView] reloadItem:item reloadChildren:YES];
    if(item != rootItem) [[self outlineView] expandItem:item];
    FileSystemItem *newItem = [item itemWithName:[result lastPathComponent]];
    NSInteger row = [[self outlineView] rowForItem:newItem];
    NSIndexSet *index = [NSIndexSet indexSetWithIndex:row];
    [[self outlineView] selectRowIndexes:index byExtendingSelection:NO];
    [[self outlineView] editColumn:0 row:row withEvent:nil select:YES];
  }
  else {
    NSLog(@"Failed to create file %@", path);
  }
}

- (void)newFolder:(NSMenuItem *)sender {
  FileSystemItem *selItem = [self itemAtRow:[sender tag]];
  FileSystemItem *dirItem = selItem ? [selItem dirItem] : rootItem;
  NSString *path = [[dirItem fullPath] stringByAppendingPathComponent:@"untitled folder"];

  int i = 2;
  NSString *result = path;
  NSFileManager *fileManager = [NSFileManager defaultManager];
  while ([fileManager fileExistsAtPath:result]) {
    result = [NSString stringWithFormat:@"%@ %d", path, i];
    i++;
  }

  // Make sure that the next FSEvent for this item doesn't cause the view to stop editing
  dirItem.ignoreNextReload = YES;

  [fileManager createDirectoryAtPath:result
         withIntermediateDirectories:NO
                          attributes:nil
                               error:NULL];

  // Add the new folder to the items
  [dirItem reloadRecursive:NO]; // for now let's not create the item ourselves
  if(dirItem == rootItem)
    [[self outlineView] reloadData];
  else
    [[self outlineView] reloadItem:dirItem reloadChildren:YES];

  // Show, select and edit the new folder
  if(selItem) [[self outlineView] expandItem:dirItem];
  FileSystemItem *newItem = [dirItem itemWithName:[result lastPathComponent]];
  NSInteger row = [[self outlineView] rowForItem:newItem];
  NSIndexSet *index = [NSIndexSet indexSetWithIndex:row];
  [[self outlineView] selectRowIndexes:index byExtendingSelection:NO];
  [[self outlineView] editColumn:0 row:row withEvent:nil select:YES];
}

// Vim open/cwd

- (void)openFilesInTabs:(NSMenuItem *)sender {
  [self openSelectedFilesInCurrentWindowWithLayout:MMLayoutTabs];
}

- (void)openFilesInHorizontalSplitViews:(NSMenuItem *)sender {
  [self openSelectedFilesInCurrentWindowWithLayout:MMLayoutHorizontalSplit];
}

- (void)openFilesInVerticalSplitViews:(NSMenuItem *)sender {
  [self openSelectedFilesInCurrentWindowWithLayout:MMLayoutVerticalSplit];
}

- (void)changeWorkingDirectoryToSelection:(NSMenuItem *)sender {
  [self changeWorkingDirectory:[sender representedObject]];
}

- (void)changeWorkingDirectoryFromPathControl:(NSPathControl *)sender {
  NSPathComponentCell *clickedCell = [sender clickedPathComponentCell];
  [self changeWorkingDirectory:[[clickedCell URL] path]];
}

// TODO needs multiple selection support
- (void)deleteSelectedFiles:(NSMenuItem *)sender {
  FileSystemItem *item = [self itemAtRow:[sender tag]];
  NSString *fullPath = [item fullPath];
  BOOL isLeaf = [item isLeaf];
  FileSystemItem *dirItem = item.parent;

  dirItem.ignoreNextReload = YES;
  [[NSFileManager defaultManager] removeItemAtPath:fullPath error:NULL];
  [dirItem reloadRecursive:NO];
  if(rootItem == dirItem)
    [[self outlineView] reloadData];
  else
    [[self outlineView] reloadItem:dirItem reloadChildren:YES];

  if(isLeaf) {
    MMVimController *vim = [windowController vimController];
    NSString *bufName = [vim evaluateVimExpression:[NSString stringWithFormat:@"bufname('%@')", fullPath]];
    if([bufName length] != 0) {
      NSString *input = [NSString stringWithFormat:@"<C-\\><C-N>"
                                                 ":bdelete! %@<CR>", bufName];
      [vim addVimInput:input];
    }
  }
}

- (void)toggleShowHiddenFiles:(NSMenuItem *)sender {
  rootItem.includesHiddenFiles = !rootItem.includesHiddenFiles;
  [rootItem reloadRecursive:YES];
  [[self outlineView] reloadData];
}

// Open elsewhere

// TODO add multiple selection support
- (void)revealInFinder:(NSMenuItem *)sender {
  NSString *path = [[self itemAtRow:[sender tag]] fullPath];
  NSArray *urls = [NSArray arrayWithObject:[NSURL fileURLWithPath:path]];
  [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:urls];
}

- (void)openWithFinder:(NSMenuItem *)sender {
  [[NSWorkspace sharedWorkspace] openFile:[[self itemAtRow:[sender tag]] fullPath]];
}

// TODO really need to use selected items instead of tags on the menu item!
- (void)openFileWithApp:(NSMenuItem *)sender {
  NSMenu *menu = [sender menu];
  NSInteger index = [[menu supermenu] indexOfItemWithSubmenu:menu];
  NSMenuItem *parentMenuItem = [[menu supermenu] itemAtIndex:index];
  FileSystemItem *item = [self itemAtRow:[parentMenuItem tag]];
  NSArray *appPaths = [self appsAssociatedWithItem:item];
  if (appPaths) {
    // Actually this action should never be called if there are no associated apps, but let's keep it safe
    NSString *selectedApp = [appPaths objectAtIndex:[sender tag]];
    [[NSWorkspace sharedWorkspace] openFile:[item fullPath] withApplication:selectedApp];
  }
}


// FSEvents
// ========

static void change_occured(ConstFSEventStreamRef stream,
                           void *watcher,
                           size_t eventCount,
                           void *paths,
                           const FSEventStreamEventFlags flags[],
                           const FSEventStreamEventId ids[]) {
  MMFileDrawerController *self = (MMFileDrawerController *)watcher;
  for (NSString *path in (NSArray *)paths) {
    [self changeOccurredAtPath:path];
  }
}

- (void)changeOccurredAtPath:(NSString *)path {
  FileSystemItem *item = [rootItem itemAtPath:path];
  if (item) {
    if (item.ignoreNextReload) {
      item.ignoreNextReload = NO;
      return;
    }
    // NSLog(@"Change occurred in path: %@", [item fullPath]);
    // No need to reload recursive, the change occurred in *this* item only
    if ([item reloadRecursive:NO]) {
      if(rootItem == item) {
        [[self outlineView] reloadData];
      }
      else
        [[self outlineView] reloadItem:item reloadChildren:YES];
    }
  }
}

- (void)watchRoot {
  NSString *path = [rootItem fullPath];
  // NSLog(@"Watch: %@", path);

  FSEventStreamContext context;
  context.version = 0;
  context.info = (void *)self;
  context.retain = NULL;
  context.release = NULL;
  context.copyDescription = NULL;

  fsEventsStream = FSEventStreamCreate(kCFAllocatorDefault,
                                       &change_occured,
                                       &context,
                                       (CFArrayRef)[NSArray arrayWithObject:path],
                                       kFSEventStreamEventIdSinceNow,
                                       1.5,
                                       // TODO MacVim doesn't deal with the root path changing afaik
                                       //kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes);
                                       kFSEventStreamCreateFlagUseCFTypes);

  FSEventStreamScheduleWithRunLoop(fsEventsStream, [[NSRunLoop currentRunLoop] getCFRunLoop], kCFRunLoopDefaultMode);
  FSEventStreamStart(fsEventsStream);
}

- (void)unwatchRoot
{
  if (fsEventsStream != NULL) {
    FSEventStreamStop(fsEventsStream);
    FSEventStreamInvalidate(fsEventsStream);
    FSEventStreamRelease(fsEventsStream);
    fsEventsStream = NULL;
  }
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];

  [self unwatchRoot];
  [drawer release]; drawer = nil;
  [pathControl release]; pathControl = nil;
  [rootItem release]; rootItem = nil;

  [super dealloc];
}


- (FilesOutlineView *)outlineView
{
  return (FilesOutlineView *)[self view];
}

- (void)pwdChanged:(NSNotification *)notification
{
  NSString *pwd = [[notification userInfo] objectForKey:@"pwd"];
  if (pwd) {
    [self setRoot:pwd];
    [[self outlineView] reloadData];
    [[self outlineView] expandItem:rootItem];
  }
}

@end


@implementation FlippedView

- (BOOL) isFlipped {
  return YES;
}

@end
