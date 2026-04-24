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

#import "STKLocalFileDataSource.h"

@interface STKLocalFileDataSource()
{
    SInt64 position;
    SInt64 length;
    AudioFileTypeID audioFileTypeHint;
    NSFileHandle* fileHandle;
    BOOL eofReached;
}
@property (readwrite, copy) NSString* filePath;
-(void) open;
@end

@implementation STKLocalFileDataSource
@synthesize filePath;

-(instancetype) initWithFilePath:(NSString*)filePathIn
{
    if (self = [super init])
    {
        self.filePath = filePathIn;

        audioFileTypeHint = [STKLocalFileDataSource audioFileTypeHintFromFileExtension:filePathIn.pathExtension];
    }

    return self;
}

+(AudioFileTypeID) audioFileTypeHintFromFileExtension:(NSString*)fileExtension
{
    static dispatch_once_t onceToken;
    static NSDictionary* fileTypesByFileExtensions;

    dispatch_once(&onceToken, ^
    {
        fileTypesByFileExtensions =
        @{
            @"mp3": @(kAudioFileMP3Type),
            @"wav": @(kAudioFileWAVEType),
            @"aifc": @(kAudioFileAIFCType),
            @"aiff": @(kAudioFileAIFFType),
            @"m4a": @(kAudioFileM4AType),
            @"mp4": @(kAudioFileMPEG4Type),
            @"caf": @(kAudioFileCAFType),
            @"aac": @(kAudioFileAAC_ADTSType),
            @"ac3": @(kAudioFileAC3Type),
            @"3gp": @(kAudioFile3GPType)
        };
    });

    NSNumber* number = [fileTypesByFileExtensions objectForKey:fileExtension];

    if (!number)
    {
        return 0;
    }

    return (AudioFileTypeID)number.intValue;
}

-(AudioFileTypeID) audioFileTypeHint
{
    return audioFileTypeHint;
}

-(void) dealloc
{
    [self close];
}

-(void) close
{
    if (fileHandle)
    {
        [fileHandle closeFile];
        fileHandle = nil;
    }
    [super close];
}

-(void) open
{
    if (fileHandle)
    {
        [fileHandle closeFile];
        fileHandle = nil;
    }

    eofReached = NO;

    fileHandle = [NSFileHandle fileHandleForReadingAtPath:self.filePath];

    if (fileHandle == nil)
    {
        [self didFailWithError:nil];
        return;
    }

    NSError* fileError = nil;
    NSFileManager* manager = [[NSFileManager alloc] init];
    NSDictionary* attributes = [manager attributesOfItemAtPath:filePath error:&fileError];

    if (fileError)
    {
        [fileHandle closeFile];
        fileHandle = nil;
        [self didFailWithError:fileError];
        return;
    }

    NSNumber* number = [attributes objectForKey:NSFileSize];

    if (number)
    {
        length = number.longLongValue;
    }

    [self didOpen];

    if (position < length)
    {
        [self signalDataAvailable];
    }
    else
    {
        [self markEof];
    }
}

-(SInt64) position
{
    return position;
}

-(SInt64) length
{
    return length;
}

-(BOOL) hasBytesAvailable
{
    if (fileHandle == nil)
    {
        return NO;
    }
    return position < length;
}

-(int) readIntoBuffer:(UInt8*)buffer withSize:(int)size
{
    if (fileHandle == nil || size <= 0)
    {
        return 0;
    }

    NSData* data = nil;
    @try
    {
        data = [fileHandle readDataOfLength:size];
    }
    @catch (NSException* exception)
    {
        return -1;
    }

    int read = (int)data.length;

    if (read > 0)
    {
        memcpy(buffer, data.bytes, read);
        position += read;
    }

    if (position >= length && !eofReached)
    {
        [self markEof];
    }
    else if (read > 0 && position < length)
    {
        // Keep the run loop pumping until fully drained.
        [self signalDataAvailable];
    }

    return read;
}

-(void) seekToOffset:(SInt64)offset
{
    if (fileHandle == nil)
    {
        [self open];
        if (fileHandle == nil)
        {
            return;
        }
    }

    @try
    {
        [fileHandle seekToFileOffset:(unsigned long long)offset];
        position = offset;
        eofReached = NO;
    }
    @catch (NSException* exception)
    {
        position = 0;
        [self didFailWithError:nil];
        return;
    }

    if (position < length)
    {
        [self signalDataAvailable];
    }
    else
    {
        [self markEof];
    }
}

// Local file I/O is synchronous — the base-class buffer isn't used. Feed a
// zero-byte NSData so the base scheduler still wakes the run loop; the player
// will then pull bytes directly through readIntoBuffer:.
-(void) signalDataAvailable
{
    NSRunLoop* runLoop = eventsRunLoop;
    if (runLoop == nil)
    {
        return;
    }

    CFRunLoopPerformBlock([runLoop getCFRunLoop], (__bridge CFStringRef)NSRunLoopCommonModes, ^
    {
        if (self->eventsRunLoop == nil) return;
        [self dataAvailable];
    });
    CFRunLoopWakeUp([runLoop getCFRunLoop]);
}

-(void) markEof
{
    if (eofReached)
    {
        return;
    }
    eofReached = YES;
    [self didComplete];
}

-(NSString*) description
{
    return self->filePath;
}

@end
