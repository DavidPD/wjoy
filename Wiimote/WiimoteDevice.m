//
//  WiimoteDevice.m
//  Wiimote
//
//  Created by alxn1 on 29.07.12.
//  Copyright (c) 2012 alxn1. All rights reserved.
//

#import "WiimoteDevice.h"
#import "WiimoteDeviceReport+Private.h"
#import "WiimoteDeviceEventDispatcher+Private.h"
#import "WiimoteDeviceReadMemQueue.h"

#import <IOBluetooth/IOBluetooth.h>

@interface WiimoteDevice (PrivatePart)

- (IOBluetoothL2CAPChannel*)openChannel:(BluetoothL2CAPPSM)channelID;

- (void)handleReport:(WiimoteDeviceReport*)report;
- (void)handleDisconnect;

@end

@interface WiimoteDevice (IOBluetoothL2CAPChannelDelegate)

- (void)l2capChannelData:(IOBluetoothL2CAPChannel*)l2capChannel
                    data:(void*)dataPointer
                  length:(size_t)dataLength;

- (void)l2capChannelClosed:(IOBluetoothL2CAPChannel*)l2capChannel;

@end

@implementation WiimoteDevice

- (id)init
{
	[[super init] release];
	return nil;
}

- (id)initWithBluetoothDevice:(IOBluetoothDevice*)device
{
	self = [super init];
	if(self == nil)
		return nil;

	if(device == nil)
	{
		[self release];
		return nil;
	}

	m_Device				= [device retain];
	m_DataChannel			= nil;
	m_ControlChannel		= nil;
	m_EventDispatcher		= [[WiimoteDeviceEventDispatcher alloc] init];
    m_ReadMemQueue			= [[WiimoteDeviceReadMemQueue alloc] initWithDevice:self];
	m_IsConnected			= NO;
    m_IsVibrationEnabled    = NO;
    m_LEDsState             = 0;

	return self;
}

- (void)dealloc
{
	[self disconnect];
    [m_ReadMemQueue release];
	[m_EventDispatcher release];
	[m_ControlChannel release];
	[m_DataChannel release];
	[m_Device release];
	[super dealloc];
}

- (BOOL)isConnected
{
	return m_IsConnected;
}

- (BOOL)connect
{
	if([self isConnected])
		return YES;

	m_IsConnected		= YES;
	m_ControlChannel	= [[self openChannel:kBluetoothL2CAPPSMHIDControl] retain];
	m_DataChannel		= [[self openChannel:kBluetoothL2CAPPSMHIDInterrupt] retain];

	if(m_ControlChannel == nil ||
       m_DataChannel    == nil)
    {
		[self disconnect];
		m_IsConnected = NO;
        return NO;
    }

	return YES;
}

- (void)disconnect
{
	if(![self isConnected])
		return;

	[m_ControlChannel setDelegate:nil];
	[m_DataChannel setDelegate:nil];

	[m_ControlChannel closeChannel];
	[m_DataChannel closeChannel];
	[m_Device closeConnection];

	m_IsConnected = NO;

	[self handleDisconnect];
	[m_EventDispatcher removeAllHandlers];
}

- (NSData*)address
{
	if(![self isConnected])
		return nil;

	const BluetoothDeviceAddress *address = [m_Device getAddress];
    if(address == NULL)
        return nil;

    return [NSData dataWithBytes:address->data
                          length:sizeof(address->data)];
}

- (NSString*)addressString
{
	if(![self isConnected])
		return nil;

	return [m_Device getAddressString];
}

- (BOOL)postCommand:(WiimoteDeviceCommandType)command data:(NSData*)data
{
	if(![self isConnected] ||
        [data length] == 0)
    {
		return NO;
    }

	uint8_t                     buffer[sizeof(WiimoteDeviceCommandHeader) + [data length]];
    WiimoteDeviceCommandHeader *header = (WiimoteDeviceCommandHeader*)buffer;

    header->packetType  = WiimoteDevicePacketTypeCommand;
    header->commandType = command;
    memcpy(buffer + sizeof(WiimoteDeviceCommandHeader), [data bytes], [data length]);

    if(m_IsVibrationEnabled)
    {
        buffer[sizeof(WiimoteDeviceCommandHeader)] |=
                        WiimoteDeviceCommandFlagVibrationEnabled;
    }
    else
    {
        buffer[sizeof(WiimoteDeviceCommandHeader)] &=
                        (~WiimoteDeviceCommandFlagVibrationEnabled);
    }

    return ([m_DataChannel
                    writeSync:buffer
                       length:sizeof(buffer)] == kIOReturnSuccess);
}

- (BOOL)writeMemory:(NSUInteger)address data:(NSData*)data
{
    if(![self isConnected] ||
		[data length] > WiimoteDeviceWriteMemoryReportMaxDataSize)
	{
		return NO;
	}

    if([data length] == 0)
		return YES;

    NSMutableData                   *commandData	= [NSMutableData dataWithLength:sizeof(WiimoteDeviceWriteMemoryParams)];
	uint8_t                         *buffer         = [commandData mutableBytes];
    WiimoteDeviceWriteMemoryParams  *params         = (WiimoteDeviceWriteMemoryParams*)buffer;

    params->address = OSSwapHostToBigConstInt32(address);
    params->length  = [data length];
    memset(params->data, 0, sizeof(params->data));
    memcpy(params->data, [data bytes], [data length]);

    return [self postCommand:WiimoteDeviceCommandTypeWriteMemory
						data:commandData];
}

- (BOOL)readMemory:(NSRange)memoryRange target:(id)target action:(SEL)action
{
	if(![self isConnected])
		return NO;

	return [m_ReadMemQueue readMemory:memoryRange
							   target:target
							   action:action];
}

- (BOOL)injectReport:(NSUInteger)type data:(NSData*)data
{
    if(![self isConnected])
        return NO;

    WiimoteDeviceReport *report = [WiimoteDeviceReport
                                            deviceReportWithType:type
                                                            data:data
                                                          device:self];

    if(report == nil)
        return NO;

    [self handleReport:report];
    return YES;
}

- (BOOL)requestStateReport
{
    uint8_t param = 0;
    return [self postCommand:WiimoteDeviceCommandTypeGetState
                        data:[NSData dataWithBytes:&param length:sizeof(param)]];
}

- (BOOL)requestReportType:(WiimoteDeviceReportType)type
{
	WiimoteDeviceSetReportTypeParams params;

    params.flags        = 0;
    params.reportType   = type;

    return [self postCommand:WiimoteDeviceCommandTypeSetReportType
						data:[NSData dataWithBytes:&params
                                            length:sizeof(params)]];
}

- (BOOL)postVibrationAndLEDStates
{
    return [self postCommand:WiimoteDeviceCommandTypeSetLEDState
                        data:[NSData dataWithBytes:&m_LEDsState
                                            length:sizeof(m_LEDsState)]];
}

- (BOOL)isVibrationEnabled
{
    return m_IsVibrationEnabled;
}

- (BOOL)setVibrationEnabled:(BOOL)enabled
{
    if(m_IsVibrationEnabled == enabled)
        return YES;

    m_IsVibrationEnabled = enabled;
    if(![self postVibrationAndLEDStates])
    {
        m_IsVibrationEnabled = !enabled;
        return NO;
    }

    return YES;
}

- (uint8_t)LEDsState
{
    return m_LEDsState;
}

- (BOOL)setLEDsState:(uint8_t)state
{
    uint8_t oldState = m_LEDsState;

    m_LEDsState = state;
    if(![self postVibrationAndLEDStates])
    {
        m_LEDsState = oldState;
        return NO;
    }

    return YES;
}

- (WiimoteDeviceEventDispatcher*)eventDispatcher
{
    return [[m_EventDispatcher retain] autorelease];
}

@end

@implementation WiimoteDevice (PrivatePart)

- (IOBluetoothL2CAPChannel*)openChannel:(BluetoothL2CAPPSM)channelID
{
	IOBluetoothL2CAPChannel *result = nil;

	if([m_Device openL2CAPChannelSync:&result
                              withPSM:channelID
                             delegate:self] != kIOReturnSuccess)
    {
		return nil;
    }

	return result;
}

- (void)handleReport:(WiimoteDeviceReport*)report
{
    [m_ReadMemQueue handleReport:report];
	[m_EventDispatcher handleReport:report];
}

- (void)handleDisconnect
{
    [m_ReadMemQueue handleDisconnect];
	[m_EventDispatcher handleDisconnect];
}

@end

@implementation WiimoteDevice (IOBluetoothL2CAPChannelDelegate)

- (void)l2capChannelData:(IOBluetoothL2CAPChannel*)l2capChannel
                    data:(void*)dataPointer
                  length:(size_t)dataLength
{
	[self handleReport:[WiimoteDeviceReport
                                parseReportData:dataPointer
                                         length:dataLength
                                         device:self]];
}

- (void)l2capChannelClosed:(IOBluetoothL2CAPChannel*)l2capChannel
{
    [self disconnect];
}

@end
