//
//  AIMRendezvousHandler.m
//  LibOrange
//
//  Created by Alex Nichol on 6/14/11.
//  Copyright 2011 __MyCompanyName__. All rights reserved.
//

#import "AIMRendezvousHandler.h"

@interface AIMRendezvousHandler (Private)

- (void)_handleRendezvousMessage:(AIMICBMMessageToClient *)message;
- (void)_handleReceiving:(AIMReceivingFileTransfer *)ft rvMessage:(AIMIMRendezvous *)msg;

@end

@implementation AIMRendezvousHandler

@synthesize delegate;

- (id)initWithSession:(AIMSession *)theSession {
	if ((self = [super init])) {
		fileTransfers = [[NSMutableArray alloc] init];
		session = [theSession retain];
		[session addHandler:self];
	}
	return self;
}

- (void)handleIncomingSnac:(SNAC *)aSnac {
	NSAssert([NSThread currentThread] == [session backgroundThread], @"Running on incorrect thread");
	if (SNAC_ID_IS_EQUAL(SNAC_ID_NEW(SNAC_ICBM, ICBM__CHANNEL_MSG_TOCLIENT), [aSnac snac_id])) {
		AIMICBMMessageToClient * message = [[AIMICBMMessageToClient alloc] initWithData:[aSnac innerContents]];
		if ([message channel] == 2) {
			[self performSelector:@selector(_handleRendezvousMessage:) onThread:session.mainThread withObject:message waitUntilDone:NO];
		}
		[message release];
	}
}

- (void)sessionClosed {
	// TODO: cancel all transfers.
	[fileTransfers release];
	fileTransfers = nil;
	[session removeHandler:self];
	[session release];
	session = nil;
}

- (AIMFileTransfer *)fileTransferWithCookie:(AIMICBMCookie *)cookie {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	for (AIMFileTransfer * transfer in fileTransfers) {
		if ([[transfer cookie] isEqualToCookie:cookie]) {
			return transfer;
		}
	}
	return nil;
}

- (void)acceptFileTransfer:(AIMReceivingFileTransfer *)ft  saveToPath:(NSString *)path {
	// send the information.
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	ft.writePath = path;
	[ft setDelegate:self];
	[ft tryProposal];
}

- (void)cancelFileTransfer:(AIMFileTransfer *)ft {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	if ([ft isTransferring]) {
		if ([ft isKindOfClass:[AIMReceivingFileTransfer class]]) {
			[(AIMReceivingFileTransfer *)ft cancelDownload];
		}
	}
	
	AIMIMRendezvous * cancelRV = [[AIMIMRendezvous alloc] init];
	cancelRV.type = RV_TYPE_CANCEL;
	cancelRV.cookie = [ft cookie];
	cancelRV.service = [[[AIMCapability alloc] initWithType:AIMCapabilityFileTransfer] autorelease];
	UInt16 cReasonFlip = flipUInt16(CANCEL_REASON_USER_CANCEL);
	TLV * cReason = [[TLV alloc] initWithType:TLV_RV_CANCEL_REASON data:[NSData dataWithBytes:&cReasonFlip length:2]];
	cancelRV.params = [NSArray arrayWithObject:cReason];
	[cReason release];
	AIMICBMMessageToServer * msg = [[AIMICBMMessageToServer alloc] initWithRVData:[cancelRV encodePacket] toUser:[ft buddy].username cookie:[ft cookie]];
	[cancelRV release];
	SNAC * sendMsg = [[SNAC alloc] initWithID:SNAC_ID_NEW(SNAC_ICBM, ICBM__CHANNEL_MSG_TOHOST) flags:0 requestID:[session generateReqID] data:[msg encodePacket]];
	[msg release];
	[session performSelector:@selector(writeSnac:) onThread:session.backgroundThread withObject:sendMsg waitUntilDone:NO];
	[sendMsg release];
	[fileTransfers removeObject:ft];
}

- (void)_handleRendezvousMessage:(AIMICBMMessageToClient *)message {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	AIMFileTransfer * ft = [self fileTransferWithCookie:[message cookie]];
	if (!ft) {
		AIMReceivingFileTransfer * newTransfer = [[AIMReceivingFileTransfer alloc] initWithCookie:[message cookie]];
		[fileTransfers addObject:newTransfer];
		[newTransfer setLocalUsername:[session username]];
		newTransfer.buddy = [[session buddyList] buddyWithUsername:[message.nickInfo username]];
		ft = [newTransfer autorelease];
	}
	// populate with information.
	AIMIMRendezvous * rvMessage = [[AIMIMRendezvous alloc] initWithICBMMessage:message];
	if ([ft isKindOfClass:[AIMReceivingFileTransfer class]]) {
		[self _handleReceiving:(AIMReceivingFileTransfer *)ft rvMessage:rvMessage];
	}
	[rvMessage release];
}

- (void)_handleReceiving:(AIMReceivingFileTransfer *)ft rvMessage:(AIMIMRendezvous *)msg {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	if ([msg sequenceNumber] == 1 && [msg type] == RV_TYPE_PROPOSE) {
		[ft setRemoteHostAddr:[msg remoteAddress]];
		[ft setRemoteFileName:[[msg serviceData] fileName]];
		[ft setLastProposal:msg];
		if ([delegate respondsToSelector:@selector(aimRendezvousHandler:fileTransferRequested:)]) {
			[delegate aimRendezvousHandler:self fileTransferRequested:ft];
		}
	} else if ([msg type] == RV_TYPE_CANCEL) {
		[ft setWasCancelled:YES];
		if ([delegate respondsToSelector:@selector(aimRendezvousHandler:fileTransferCancelled:reason:)]) {
			[delegate aimRendezvousHandler:self fileTransferCancelled:ft reason:[msg cancelReason]];
		}
		[fileTransfers removeObject:ft];
	} else if ([msg type] == RV_TYPE_PROPOSE && [msg sequenceNumber] == 3) {
		[ft setLastProposal:msg];
		[ft newProposal];
	}
}

#pragma mark AIMReceivingFileTransfer

- (void)aimReceivingFileTransferTransferFailed:(AIMReceivingFileTransfer *)ft {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	if ([delegate respondsToSelector:@selector(aimRendezvousHandler:fileTransferFailed:)]) {
		[delegate aimRendezvousHandler:self fileTransferFailed:ft];
	}
	[self cancelFileTransfer:ft];
	// [fileTransfers removeObject:ft];
}

- (void)aimReceivingFileTransferPropositionSuccess:(AIMReceivingFileTransfer *)ft {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
}

- (void)aimReceivingFileTransferStarted:(AIMReceivingFileTransfer *)ft {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	if ([delegate respondsToSelector:@selector(aimRendezvousHandler:fileTransferStarted:)]) {
		[delegate aimRendezvousHandler:self fileTransferStarted:ft];
	}
}

- (void)aimReceivingFileTransferPropositionFailed:(AIMReceivingFileTransfer *)ft counterProposal:(AIMIMRendezvous *)newProp {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	AIMICBMMessageToServer * msg = [[AIMICBMMessageToServer alloc] initWithRVData:[newProp encodePacket] toUser:[ft buddy].username cookie:[ft cookie]];
	SNAC * sendMsg = [[SNAC alloc] initWithID:SNAC_ID_NEW(SNAC_ICBM, ICBM__CHANNEL_MSG_TOHOST) flags:0 requestID:[session generateReqID] data:[msg encodePacket]];
	[msg release];
	[session performSelector:@selector(writeSnac:) onThread:session.backgroundThread withObject:sendMsg waitUntilDone:NO];
	[sendMsg release];
}

- (void)aimReceivingFileTransferSendAccept:(AIMReceivingFileTransfer *)ft {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	UInt16 maxProtoVersion = flipUInt16(1);
	TLV * maxProto = [[TLV alloc] initWithType:TLV_RV_MAX_PROTOCOL_VERSION data:[NSData dataWithBytes:&maxProtoVersion length:2]];
	AIMIMRendezvous * acceptRV = [[AIMIMRendezvous alloc] init];
	acceptRV.type = RV_TYPE_ACCEPT;
	acceptRV.cookie = [ft cookie];
	acceptRV.service = [[[AIMCapability alloc] initWithType:AIMCapabilityFileTransfer] autorelease];
	acceptRV.params = [NSArray arrayWithObject:maxProto];
	[maxProto release];
	AIMICBMMessageToServer * msg = [[AIMICBMMessageToServer alloc] initWithRVData:[acceptRV encodePacket] toUser:[ft buddy].username cookie:[ft cookie]];
	[acceptRV release];
	SNAC * sendMsg = [[SNAC alloc] initWithID:SNAC_ID_NEW(SNAC_ICBM, ICBM__CHANNEL_MSG_TOHOST) flags:0 requestID:[session generateReqID] data:[msg encodePacket]];
	[msg release];
	[session performSelector:@selector(writeSnac:) onThread:session.backgroundThread withObject:sendMsg waitUntilDone:NO];
	[sendMsg release];
	[fileTransfers removeObject:ft];
}

- (void)aimReceivingFileTransferProgressChanged:(AIMReceivingFileTransfer *)ft {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	if ([delegate respondsToSelector:@selector(aimRendezvousHandler:fileTransferProgressChanged:)]) {
		[delegate aimRendezvousHandler:self fileTransferProgressChanged:ft];
	}
}

- (void)aimReceivingFileTransferFinished:(AIMReceivingFileTransfer *)ft {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	if ([delegate respondsToSelector:@selector(aimRendezvousHandler:fileTransferDone:)]) {
		[delegate aimRendezvousHandler:self fileTransferDone:ft];
	}
}

- (void)dealloc {
	[session release];
	[fileTransfers release];
	[super dealloc];
}

@end
