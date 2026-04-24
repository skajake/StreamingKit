/**********************************************************************************
 AudioPlayer.m

 Created by Thong Nguyen on 14/05/2012.
 https://github.com/tumtumtum/audjustable

 Copyright (c) 2012 Thong Nguyen (tumtumtum@gmail.com). All rights reserved.

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 1. Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 2. Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 3. All advertising materials mentioning features or use of this software
 must display the following acknowledgement:
 This product includes software developed by Thong Nguyen (tumtumtum@gmail.com)
 4. Neither the name of Thong Nguyen nor the
 names of its contributors may be used to endorse or promote products
 derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY Thong Nguyen ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL THONG NGUYEN BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
**********************************************************************************/

#import "STKCoreFoundationDataSource.h"

@interface STKCoreFoundationDataSource ()
{
    NSMutableData* pendingBuffer;
    NSLock* bufferLock;
    BOOL dataAvailableScheduled;
    BOOL eofScheduled;
    BOOL errorScheduled;
    uint64_t notificationEpoch;
}
@end

@implementation STKCoreFoundationDataSource

-(instancetype) init
{
    if (self = [super init])
    {
        pendingBuffer = [[NSMutableData alloc] init];
        bufferLock = [[NSLock alloc] init];
    }
    return self;
}

-(BOOL) isInErrorState
{
    return self->isInErrorState;
}

-(void) dataAvailable
{
    [self.delegate dataSourceDataAvailable:self];
}

-(void) eof
{
    [self.delegate dataSourceEof:self];
}

-(void) errorOccured
{
    self->isInErrorState = YES;

    [self.delegate dataSourceErrorOccured:self];
}

-(void) dealloc
{
    [self close];
}

-(void) close
{
    [self unregisterForEvents];
    [self resetBuffer];
}

-(void) open
{
}

-(void) openCompleted
{
}

-(void) seekToOffset:(SInt64)offset
{
}

-(BOOL) hasBytesAvailable
{
    [bufferLock lock];
    BOOL hasBytes = pendingBuffer.length > 0;
    [bufferLock unlock];
    return hasBytes;
}

-(int) readIntoBuffer:(UInt8*)buffer withSize:(int)size
{
    if (size <= 0)
    {
        return 0;
    }

    [bufferLock lock];

    NSUInteger available = pendingBuffer.length;

    if (available == 0)
    {
        [bufferLock unlock];
        return self->isInErrorState ? -1 : 0;
    }

    NSUInteger toCopy = MIN((NSUInteger)size, available);
    memcpy(buffer, pendingBuffer.bytes, toCopy);

    if (toCopy < available)
    {
        [pendingBuffer replaceBytesInRange:NSMakeRange(0, toCopy) withBytes:NULL length:0];
    }
    else
    {
        pendingBuffer.length = 0;
    }

    [bufferLock unlock];

    return (int)toCopy;
}

-(BOOL) registerForEvents:(NSRunLoop*)runLoop
{
    eventsRunLoop = runLoop;

    // If bytes/eof/error accumulated before registration, kick them now.
    [self scheduleIfPending];

    return YES;
}

-(void) unregisterForEvents
{
    // Bump the epoch; any blocks already queued on the run loop will bail out.
    [bufferLock lock];
    notificationEpoch++;
    dataAvailableScheduled = NO;
    eofScheduled = NO;
    errorScheduled = NO;
    [bufferLock unlock];

    eventsRunLoop = nil;
}

-(void) resetBuffer
{
    [bufferLock lock];
    pendingBuffer.length = 0;
    notificationEpoch++;
    dataAvailableScheduled = NO;
    eofScheduled = NO;
    errorScheduled = NO;
    self->isInErrorState = NO;
    [bufferLock unlock];
}

#pragma mark - Producer push API

-(void) didOpen
{
    NSRunLoop* runLoop = eventsRunLoop;
    if (runLoop == nil)
    {
        return;
    }

    uint64_t epoch;
    [bufferLock lock];
    epoch = notificationEpoch;
    [bufferLock unlock];

    CFRunLoopPerformBlock([runLoop getCFRunLoop], (__bridge CFStringRef)NSRunLoopCommonModes, ^
    {
        if ([self currentEpochIs:epoch])
        {
            [self openCompleted];
        }
    });
    CFRunLoopWakeUp([runLoop getCFRunLoop]);
}

-(void) didReceiveData:(NSData*)data
{
    if (data.length > 0)
    {
        [bufferLock lock];
        [pendingBuffer appendData:data];
        [bufferLock unlock];
    }

    [self scheduleDataAvailable];
}

-(void) didComplete
{
    [bufferLock lock];
    if (eofScheduled)
    {
        [bufferLock unlock];
        return;
    }
    eofScheduled = YES;
    uint64_t epoch = notificationEpoch;
    [bufferLock unlock];

    NSRunLoop* runLoop = eventsRunLoop;
    if (runLoop == nil)
    {
        return;
    }

    CFRunLoopPerformBlock([runLoop getCFRunLoop], (__bridge CFStringRef)NSRunLoopCommonModes, ^
    {
        if ([self currentEpochIs:epoch])
        {
            [self eof];
        }
    });
    CFRunLoopWakeUp([runLoop getCFRunLoop]);
}

-(void) didFailWithError:(NSError*)error
{
    [bufferLock lock];
    if (errorScheduled)
    {
        [bufferLock unlock];
        return;
    }
    errorScheduled = YES;
    self->isInErrorState = YES;
    uint64_t epoch = notificationEpoch;
    [bufferLock unlock];

    NSRunLoop* runLoop = eventsRunLoop;
    if (runLoop == nil)
    {
        return;
    }

    CFRunLoopPerformBlock([runLoop getCFRunLoop], (__bridge CFStringRef)NSRunLoopCommonModes, ^
    {
        if ([self currentEpochIs:epoch])
        {
            [self errorOccured];
        }
    });
    CFRunLoopWakeUp([runLoop getCFRunLoop]);
}

#pragma mark - Internal scheduling

-(void) scheduleDataAvailable
{
    [bufferLock lock];
    if (dataAvailableScheduled || pendingBuffer.length == 0)
    {
        [bufferLock unlock];
        return;
    }
    dataAvailableScheduled = YES;
    uint64_t epoch = notificationEpoch;
    [bufferLock unlock];

    NSRunLoop* runLoop = eventsRunLoop;
    if (runLoop == nil)
    {
        // Will be kicked when registerForEvents: runs.
        return;
    }

    CFRunLoopPerformBlock([runLoop getCFRunLoop], (__bridge CFStringRef)NSRunLoopCommonModes, ^
    {
        [self fireDataAvailableForEpoch:epoch];
    });
    CFRunLoopWakeUp([runLoop getCFRunLoop]);
}

-(void) fireDataAvailableForEpoch:(uint64_t)epoch
{
    [bufferLock lock];
    if (epoch != notificationEpoch)
    {
        [bufferLock unlock];
        return;
    }
    dataAvailableScheduled = NO;
    BOOL hasBytes = pendingBuffer.length > 0;
    [bufferLock unlock];

    if (hasBytes)
    {
        [self dataAvailable];
    }
}

-(void) scheduleIfPending
{
    [bufferLock lock];
    BOOL hasBytes = pendingBuffer.length > 0 && !dataAvailableScheduled;
    BOOL fireEof = eofScheduled;
    BOOL fireError = errorScheduled;
    [bufferLock unlock];

    if (hasBytes)
    {
        [self scheduleDataAvailable];
    }

    // Re-queue eof / error if they happened before registration.
    if (fireEof || fireError)
    {
        [bufferLock lock];
        eofScheduled = NO;
        errorScheduled = NO;
        [bufferLock unlock];

        if (fireError)
        {
            [self didFailWithError:nil];
        }
        else if (fireEof)
        {
            [self didComplete];
        }
    }
}

-(BOOL) currentEpochIs:(uint64_t)epoch
{
    [bufferLock lock];
    BOOL match = (epoch == notificationEpoch);
    [bufferLock unlock];
    return match;
}

@end
