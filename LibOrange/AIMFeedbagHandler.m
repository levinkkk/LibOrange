//
//  AIMFeedbagHandler.m
//  LibOrange
//
//  Created by Alex Nichol on 6/4/11.
//  Copyright 2011 __MyCompanyName__. All rights reserved.
//

#import "AIMFeedbagHandler.h"

@interface AIMFeedbagHandler (private)

- (void)_handleInsert:(NSArray *)feedbagItems;
- (void)_handleDelete:(NSArray *)feedbagItems;
- (void)_handleUpdate:(NSArray *)feedbagItems;

/* Update Handlers */
- (void)_handleGroupChanged:(AIMFeedbagItem *)oldItem newItem:(AIMFeedbagItem *)item;
- (void)_handleRootGroupChanged:(AIMFeedbagItem *)oldItem newItem:(AIMFeedbagItem *)newItem;

/* Informers */
- (void)_delegateInformHasBlist;
- (void)_delegateInformAddedB:(AIMBlistBuddy *)theBuddy;
- (void)_delegateInformRemovedB:(AIMBlistBuddy *)theBuddy;
- (void)_delegateInformAddedG:(AIMBlistGroup *)theGroup;
- (void)_delegateInformRemovedG:(AIMBlistGroup *)theGroup;
- (void)_delegateInformRenamed:(AIMBlistGroup *)theGroup;

@end

@implementation AIMFeedbagHandler

@synthesize feedbag;
@synthesize session;
@synthesize delegate;
@synthesize feedbagRights;
@synthesize tempBuddyHandler;

- (id)initWithSession:(AIMSession *)theSession {
	if ((self = [super init])) {
		session = theSession;
		[session addHandler:self];
	}
	return self;
}

- (BOOL)sendFeedbagRequest {
	NSAssert([NSThread currentThread] == [session backgroundThread], @"Running on incorrect thread");
	SNAC * query = [[SNAC alloc] initWithID:SNAC_ID_NEW(19, 4) flags:0 requestID:[session generateReqID] data:nil];
	BOOL success = [session writeSnac:query];
	[query release];
	return success;
}

- (void)handleIncomingSnac:(SNAC *)aSnac {
	NSAssert([NSThread currentThread] == [session backgroundThread], @"Running on incorrect thread");
	if (SNAC_ID_IS_EQUAL([aSnac snac_id], SNAC_ID_NEW(SNAC_FEEDBAG, FEEDBAG__REPLY))) {
		if (!feedbag) {
			feedbag = [[AIMFeedbag alloc] initWithSnac:aSnac];
		} else {
			AIMFeedbag * theFeedbag = [[AIMFeedbag alloc] initWithSnac:aSnac];
			[feedbag appendFeedbagItems:theFeedbag];
			[theFeedbag release];
		}
		if ([aSnac isLastResponse]) {
			SNAC * feedbagUse = [[SNAC alloc] initWithID:SNAC_ID_NEW(SNAC_FEEDBAG, FEEDBAG__USE) flags:0 requestID:[session generateReqID] data:nil];
			[session writeSnac:feedbagUse];
			[feedbagUse release];
			session.buddyList = [[[AIMBlist alloc] initWithFeedbag:feedbag tempBuddyHandler:tempBuddyHandler] autorelease];
			[self performSelector:@selector(_delegateInformHasBlist) onThread:[session mainThread] withObject:nil waitUntilDone:NO];
		}
	} else if (SNAC_ID_IS_EQUAL([aSnac snac_id], SNAC_ID_NEW(SNAC_FEEDBAG, FEEDBAG__INSERT_ITEMS))) {
		NSArray * items = [AIMFeedbagItem decodeArray:[aSnac innerContents]];
		[self performSelector:@selector(_handleInsert:) onThread:session.mainThread withObject:items waitUntilDone:YES];
	} else if (SNAC_ID_IS_EQUAL([aSnac snac_id], SNAC_ID_NEW(SNAC_FEEDBAG, FEEDBAG__UPDATE_ITEMS))) {
		NSArray * items = [AIMFeedbagItem decodeArray:[aSnac innerContents]];
		[self performSelector:@selector(_handleUpdate:) onThread:session.mainThread withObject:items waitUntilDone:YES];
	} else if (SNAC_ID_IS_EQUAL([aSnac snac_id], SNAC_ID_NEW(SNAC_FEEDBAG, FEEDBAG__DELETE_ITEMS))) {
		NSArray * items = [AIMFeedbagItem decodeArray:[aSnac innerContents]];
		[self performSelector:@selector(_handleDelete:) onThread:session.mainThread withObject:items waitUntilDone:YES];
	}
}

#pragma mark Modification Handlers

- (void)_handleInsert:(NSArray *)feedbagItems {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	for (AIMFeedbagItem * item in feedbagItems) {
		[[feedbag items] addObject:item];
	}
}
- (void)_handleDelete:(NSArray *)feedbagItems {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	for (AIMFeedbagItem * item in feedbagItems) {
		for (int i = 0; i < [[feedbag items] count]; i++) {
			AIMFeedbagItem * oldItem = [[feedbag items] objectAtIndex:i];
			if ([oldItem groupID] == [item groupID] && [oldItem itemID] == [item itemID]) {
				[[feedbag items] removeObjectAtIndex:i];
				break;
			}
		}
	}
}
- (void)_handleUpdate:(NSArray *)feedbagItems {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	for (AIMFeedbagItem * item in feedbagItems) {
		for (int i = 0; i < [[feedbag items] count]; i++) {
			AIMFeedbagItem * oldItem = [[feedbag items] objectAtIndex:i];
			if ([oldItem groupID] == [item groupID] && [oldItem itemID] == [item itemID]) {
				if ([oldItem classID] == FEEDBAG_GROUP && [oldItem groupID] != 0) {
					[self _handleGroupChanged:oldItem newItem:item];
					if (![[oldItem itemName] isEqual:[item itemName]]) {
						AIMBlistGroup * group = [session.buddyList groupWithFeedbagID:item.groupID];
						if (group) {
							[group setName:[item itemName]];
							/* Should already be on main thread. */
							[self performSelector:@selector(_delegateInformRenamed:) onThread:session.mainThread withObject:group waitUntilDone:YES];
						}
					}
				} else if ([oldItem classID] == FEEDBAG_GROUP && [oldItem groupID] == 0) {
					[self _handleRootGroupChanged:oldItem newItem:item];
				}
				[oldItem setAttributes:[item attributes]];
				[oldItem setItemName:[item itemName]];
				break;
			}
		}
	}
}

- (void)_handleGroupChanged:(AIMFeedbagItem *)oldItem newItem:(AIMFeedbagItem *)item {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	NSArray * added = nil;
	NSArray * removed = nil;
	BOOL changed = [oldItem orderChangeToItem:item added:&added removed:&removed];
	if (changed) {
		for (NSNumber * removedID in removed) {
			UInt16 itemID = [removedID unsignedShortValue];
			AIMBlistBuddy * buddy = [[session.buddyList buddyWithFeedbagID:itemID] retain];
			if (buddy) {
				AIMBlistGroup * group = [buddy group];
				NSMutableArray * buddies = (NSMutableArray *)[group buddies];
				[buddies removeObject:buddy];
				/* Should be running on main thread anyway. */
				[self performSelector:@selector(_delegateInformRemovedB:) onThread:session.mainThread withObject:buddy waitUntilDone:YES];
				[buddy release];
			}
		}
		for (NSNumber * addedID in added) {
			AIMFeedbagItem * theItem = [feedbag itemWithItemID:[addedID unsignedShortValue]];
			if (theItem) {
				AIMBlistBuddy * buddy = [[AIMBlistBuddy alloc] initWithUsername:[theItem itemName]];
				AIMBlistGroup * group = [session.buddyList groupWithFeedbagID:[oldItem groupID]];
				if (group) {
					NSMutableArray * buddies = (NSMutableArray *)[group buddies];
					[buddies addObject:buddy];
					[buddy setGroup:group];
					[buddy setFeedbagItemID:[theItem itemID]];
					/* Should be running on main thread anyway. */
					[self performSelector:@selector(_delegateInformAddedB:) onThread:session.mainThread withObject:buddy waitUntilDone:YES];
					if ([tempBuddyHandler tempBuddyWithName:[theItem itemName]]) {
						[tempBuddyHandler deleteTempBuddy:[tempBuddyHandler tempBuddyWithName:[theItem itemName]]];
					}
				} else {
					NSLog(@"%@ added to unknown group %@", buddy, [oldItem itemName]);
				}
				[buddy release];
			}
		}
	}
}

- (void)_handleRootGroupChanged:(AIMFeedbagItem *)oldItem newItem:(AIMFeedbagItem *)newItem {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	NSArray * added = nil;
	NSArray * removed = nil;
	BOOL changed = [oldItem orderChangeToItem:newItem added:&added removed:&removed];
	if (changed) {
		for (NSNumber * removedID in removed) {
			UInt16 groupID = [removedID unsignedShortValue];
			AIMBlistGroup * group = [[session.buddyList groupWithFeedbagID:groupID] retain];
			NSMutableArray * groups = (NSMutableArray *)[session.buddyList groups];
			[groups removeObject:group];
			/* Should be running on main thread anyway. */
			[self performSelector:@selector(_delegateInformRemovedG:) onThread:session.mainThread withObject:group waitUntilDone:NO];
			[group release];
		}
		for (NSNumber * addedID in added) {
			UInt16 groupID = [addedID unsignedShortValue];
			AIMFeedbagItem * item = [feedbag groupWithGroupID:groupID];
			AIMBlistGroup * group = [session.buddyList loadGroup:item inFeedbag:feedbag];
			NSMutableArray * groups = (NSMutableArray *)[session.buddyList groups];
			[groups addObject:group];
			for (AIMBlistBuddy * buddy in [group buddies]) {
				if ([tempBuddyHandler tempBuddyWithName:[buddy username]]) {
					[tempBuddyHandler deleteTempBuddy:[tempBuddyHandler tempBuddyWithName:[buddy username]]];
				}
			}
			/* Should be running on main thread anyway. */
			[self performSelector:@selector(_delegateInformAddedG:) onThread:session.mainThread withObject:group waitUntilDone:NO];
		}
	}
}

#pragma mark Private

- (void)_delegateInformHasBlist {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	if ([delegate respondsToSelector:@selector(aimFeedbagHandlerGotBuddyList:)]) {
		[delegate aimFeedbagHandlerGotBuddyList:self];
	}
}

- (void)_delegateInformAddedB:(AIMBlistBuddy *)theBuddy {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	if ([delegate respondsToSelector:@selector(aimFeedbagHandler:buddyAdded:)]) {
		[delegate aimFeedbagHandler:self buddyAdded:theBuddy];
	}
}
- (void)_delegateInformRemovedB:(AIMBlistBuddy *)theBuddy {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	if ([delegate respondsToSelector:@selector(aimFeedbagHandler:buddyDeleted:)]) {
		[delegate aimFeedbagHandler:self buddyDeleted:theBuddy];
	}
}
- (void)_delegateInformAddedG:(AIMBlistGroup *)theGroup {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	if ([delegate respondsToSelector:@selector(aimFeedbagHandler:groupAdded:)]) {
		[delegate aimFeedbagHandler:self groupAdded:theGroup];
	}
}
- (void)_delegateInformRemovedG:(AIMBlistGroup *)theGroup {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	if ([delegate respondsToSelector:@selector(aimFeedbagHandler:groupDeleted:)]) {
		[delegate aimFeedbagHandler:self groupDeleted:theGroup];
	}
}
- (void)_delegateInformRenamed:(AIMBlistGroup *)theGroup {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	if ([delegate respondsToSelector:@selector(aimFeedbagHandler:groupRenamed:)]) {
		[delegate aimFeedbagHandler:self groupRenamed:theGroup];
	}
}

- (void)dealloc {
	[feedbag release];
	self.feedbagRights = nil;
	[super dealloc];
}

@end