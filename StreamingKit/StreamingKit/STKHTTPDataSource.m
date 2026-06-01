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

#import "STKHTTPDataSource.h"
#import "STKLocalFileDataSource.h"

@interface STKHTTPDataSource()
{
@private
    BOOL supportsSeek;
    UInt32 httpStatusCode;
    SInt64 seekStart;
    SInt64 relativePosition;
    SInt64 fileLength;
    int discontinuous;
	int requestSerialNumber;
    int prefixBytesRead;
    NSData* prefixBytes;
    NSMutableData* iceHeaderData;
    BOOL iceHeaderSearchComplete;
    BOOL iceHeaderAvailable;
    BOOL httpHeaderNotAvailable;

    NSURL* currentUrl;
    STKAsyncURLProvider asyncUrlProvider;
    NSDictionary* httpHeaders;
    AudioFileTypeID audioFileTypeHint;
    NSDictionary* requestHeaders;

    // Meta data
    BOOL metaDataPresent;
    unsigned int metaDataInterval;        // how many data bytes between meta data
    unsigned int metaDataBytesRemaining;  // how many bytes of metadata remain to be read
    unsigned int dataBytesRead;           // how many bytes of data have been read
    BOOL foundIcyStart;
    BOOL foundIcyEnd;
    NSMutableString *metaDataString;      //  meta data string
    UInt64 connectionAudioBytes;          // encoded audio bytes received in the current connection (excludes ICY metadata)
    double parsedFrameBitrate;            // exact CBR bitrate (bits/sec) read from the first MP3 frame, 0 until found
}
-(void) open;

@end

// Minimal MP3 frame-header reader, just enough to recover the constant bitrate of a CBR stream so
// we can convert "encoded audio bytes" into "seconds of audio" the same way the transcribe-service
// does (see tbapps-k8s .../transcribe-service/src/mp3.ts). We do not decode anything.
// An MP3 frame header is 4 bytes beginning with an 11-bit frame sync (all ones); the bitrate and
// sample rate are looked up from tables keyed by the MPEG version and layer in the header.
static double STKReadFirstMp3FrameBitrate(const UInt8 *buf, int length)
{
    // Layer III bitrate tables (kbps), indexed by the 4-bit bitrate field.
    static const int kBitrateKbpsMpeg1L3[16]  = {0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0};
    static const int kBitrateKbpsMpeg2L3[16]  = {0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0};

    for (int i = 0; i + 4 <= length; i++) {
        // Frame sync: 11 bits set (0xFF then top 3 bits of the next byte).
        if (buf[i] != 0xFF || (buf[i + 1] & 0xE0) != 0xE0) continue;

        int versionBits = (buf[i + 1] >> 3) & 0x03; // 3=MPEG1, 2=MPEG2, 0=MPEG2.5
        int layerBits   = (buf[i + 1] >> 1) & 0x03; // 1 = Layer III
        if (layerBits != 0x01) continue;            // Layer III only (streaming MP3)
        if (versionBits == 0x01) continue;          // reserved version

        int bitrateIndex    = (buf[i + 2] >> 4) & 0x0F;
        int sampleRateIndex = (buf[i + 2] >> 2) & 0x03;
        if (bitrateIndex == 0 || bitrateIndex == 0x0F) continue; // free/bad
        if (sampleRateIndex == 0x03) continue;                   // reserved

        int kbps = (versionBits == 3) ? kBitrateKbpsMpeg1L3[bitrateIndex] : kBitrateKbpsMpeg2L3[bitrateIndex];
        if (kbps <= 0) continue;
        return kbps * 1000.0;
    }
    return 0.0;
}

@implementation STKHTTPDataSource

-(instancetype) initWithURL:(NSURL*)urlIn
{
    return [self initWithURLProvider:^NSURL* { return urlIn; }];
}

-(instancetype) initWithURL:(NSURL *)urlIn httpRequestHeaders:(NSDictionary *)httpRequestHeaders
{
    self = [self initWithURLProvider:^NSURL* { return urlIn; }];
    self->requestHeaders = httpRequestHeaders;
    return self;
}

-(instancetype) initWithURLProvider:(STKURLProvider)urlProviderIn
{
	urlProviderIn = [urlProviderIn copy];
    
    return [self initWithAsyncURLProvider:^(STKHTTPDataSource* dataSource, BOOL forSeek, STKURLBlock block)
    {
        block(urlProviderIn());
    }];
}

-(instancetype) initWithAsyncURLProvider:(STKAsyncURLProvider)asyncUrlProviderIn
{
    if (self = [super init])
    {
        seekStart = 0;
        relativePosition = 0;
        fileLength = -1;
        
        self->asyncUrlProvider = [asyncUrlProviderIn copy];
        
        audioFileTypeHint = [STKLocalFileDataSource audioFileTypeHintFromFileExtension:self->currentUrl.pathExtension];

        metaDataString = [NSMutableString new];
    }
    
    return self;
}

-(void) dealloc
{
    NSLog(@"STKHTTPDataSource dealloc");
}

-(NSURL*) url
{
    return self->currentUrl;
}

+(AudioFileTypeID) audioFileTypeHintFromMimeType:(NSString*)mimeType
{
    static dispatch_once_t onceToken;
    static NSDictionary* fileTypesByMimeType;
    
    dispatch_once(&onceToken, ^
    {
        fileTypesByMimeType =
        @{
            @"audio/mp3": @(kAudioFileMP3Type),
            @"audio/mpg": @(kAudioFileMP3Type),
            @"audio/mpeg": @(kAudioFileMP3Type),
            @"audio/wav": @(kAudioFileWAVEType),
            @"audio/x-wav": @(kAudioFileWAVEType),
            @"audio/vnd.wav": @(kAudioFileWAVEType),
            @"audio/aifc": @(kAudioFileAIFCType),
            @"audio/aiff": @(kAudioFileAIFFType),
            @"audio/x-m4a": @(kAudioFileM4AType),
            @"audio/x-mp4": @(kAudioFileMPEG4Type),
            @"audio/aacp": @(kAudioFileAAC_ADTSType),
            @"audio/m4a": @(kAudioFileM4AType),
            @"audio/mp4": @(kAudioFileMPEG4Type),
            @"video/mp4": @(kAudioFileMPEG4Type),
            @"audio/caf": @(kAudioFileCAFType),
            @"audio/x-caf": @(kAudioFileCAFType),
            @"audio/aac": @(kAudioFileAAC_ADTSType),
            @"audio/aacp": @(kAudioFileAAC_ADTSType),
            @"audio/ac3": @(kAudioFileAC3Type),
            @"audio/3gp": @(kAudioFile3GPType),
            @"video/3gp": @(kAudioFile3GPType),
            @"audio/3gpp": @(kAudioFile3GPType),
            @"video/3gpp": @(kAudioFile3GPType),
            @"audio/3gp2": @(kAudioFile3GP2Type),
            @"video/3gp2": @(kAudioFile3GP2Type)
        };
    });
    
    NSNumber* number = [fileTypesByMimeType objectForKey:mimeType];
    
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

-(NSDictionary*) parseIceHeader:(NSData*)headerData
{
    NSMutableDictionary* retval = [[NSMutableDictionary alloc] init];
    NSCharacterSet* characterSet = [NSCharacterSet characterSetWithCharactersInString:@"\r\n"];
    NSString* fullString = [[NSString alloc] initWithData:headerData encoding:NSUTF8StringEncoding];
    NSArray* strings = [fullString componentsSeparatedByCharactersInSet:characterSet];
    
    httpHeaders = [NSMutableDictionary dictionary];
    
    for (NSString* s in strings)
    {
        if (s.length == 0)
        {
            continue;
        }
        
        if ([s hasPrefix:@"ICY "])
        {
            NSArray* parts = [s componentsSeparatedByString:@" "];
            
            if (parts.count >= 2)
            {
                self->httpStatusCode = [parts[1] intValue];
            }
            
            continue;
        }
        
        NSRange range = [s rangeOfString:@":"];
        
        if (range.location == NSNotFound)
        {
            continue;
        }
        
        NSString* key = [s substringWithRange: (NSRange){.location = 0, .length = range.location}];
        NSString* value = [s substringFromIndex:range.location + 1];
        
        [retval setValue:value forKey:key];
    }
    
    return retval;
}

-(BOOL) parseHttpHeader
{
    if (!httpHeaderNotAvailable)
    {
        CFTypeRef response = CFReadStreamCopyProperty(stream, kCFStreamPropertyHTTPResponseHeader);
        
        if (response)
        {
            httpHeaders = (__bridge_transfer NSDictionary*)CFHTTPMessageCopyAllHeaderFields((CFHTTPMessageRef)response);
            
            if (httpHeaders.count == 0)
            {
                httpHeaderNotAvailable = YES;
            }
            else
            {
                self->httpStatusCode = (UInt32)CFHTTPMessageGetResponseStatusCode((CFHTTPMessageRef)response);
            }

            CFRelease(response);
        }
    }
    
    if (httpHeaderNotAvailable)
    {
        if (self->iceHeaderSearchComplete && !self->iceHeaderAvailable)
        {
            return YES;
        }
        
        if (!self->iceHeaderSearchComplete)
        {
            UInt8 byte;
            UInt8 terminal1[] = { '\n', '\n' };
            UInt8 terminal2[] = { '\r', '\n', '\r', '\n' };

            if (iceHeaderData == nil)
            {
                iceHeaderData = [NSMutableData dataWithCapacity:1024];
            }
            
            while (true)
            {
                if (![self hasBytesAvailable])
                {
                    break;
                }
                
                int read = [super readIntoBuffer:&byte withSize:1];
                
                if (read <= 0)
                {
                    break;
                }
                
                [iceHeaderData appendBytes:&byte length:read];
                
                if (iceHeaderData.length >= sizeof(terminal1))
                {
                    if (memcmp(&terminal1[0], [self->iceHeaderData bytes] + iceHeaderData.length - sizeof(terminal1), sizeof(terminal1)) == 0)
                    {
                        self->iceHeaderAvailable = YES;
                        self->iceHeaderSearchComplete = YES;
                        
                        break;
                    }
                }
                
                if (iceHeaderData.length >= sizeof(terminal2))
                {
                    if (memcmp(&terminal2[0], [self->iceHeaderData bytes] + iceHeaderData.length - sizeof(terminal2), sizeof(terminal2)) == 0)
                    {
                        self->iceHeaderAvailable = YES;
                        self->iceHeaderSearchComplete = YES;
                        
                        break;
                    }
                }
                
                if (iceHeaderData.length >= 4)
                {
                    if (memcmp([self->iceHeaderData bytes], "ICY ", 4) != 0 && memcmp([self->iceHeaderData bytes], "HTTP", 4) != 0)
                    {
                        self->iceHeaderAvailable = NO;
                        self->iceHeaderSearchComplete = YES;
                        prefixBytes = iceHeaderData;
                        
                        return YES;
                    }
                }
            }
            
            if (!self->iceHeaderSearchComplete)
            {
                return NO;
            }
        }

        httpHeaders = [self parseIceHeader:self->iceHeaderData];
        
        self->iceHeaderData = nil;
    }
    
    if (([httpHeaders objectForKey:@"Accept-Ranges"] ?: [httpHeaders objectForKey:@"accept-ranges"]) != nil)
    {
        self->supportsSeek = YES;
    }
    
    if (self.httpStatusCode == 200)
    {
        if (seekStart == 0)
        {
            id value = [httpHeaders objectForKey:@"Content-Length"] ?: [httpHeaders objectForKey:@"content-length"];
            
            fileLength = (SInt64)[value longLongValue];
        }
        
        NSString* contentType = [httpHeaders objectForKey:@"Content-Type"] ?: [httpHeaders objectForKey:@"content-type"] ;
        AudioFileTypeID typeIdFromMimeType = [STKHTTPDataSource audioFileTypeHintFromMimeType:contentType];
        
        if (typeIdFromMimeType != 0)
        {
            audioFileTypeHint = typeIdFromMimeType;
        }
    }
    else if (self.httpStatusCode == 206)
    {
        NSString* contentRange = [httpHeaders objectForKey:@"Content-Range"] ?: [httpHeaders objectForKey:@"content-range"];
        NSArray* components = [contentRange componentsSeparatedByString:@"/"];
        
        if (components.count == 2)
        {
            fileLength = [[components objectAtIndex:1] integerValue];
        }
    }
    else if (self.httpStatusCode == 416)
    {
        if (self.length >= 0)
        {
            seekStart = self.length;
        }
        
        [self eof];
        
        return NO;
    }
    else if (self.httpStatusCode >= 300)
    {
        [self errorOccured];
        
        return NO;
    }
    
    return YES;
}

-(void) dataAvailable
{
    if (stream == NULL)
    {
        return;
    }
    
	if (self.httpStatusCode == 0)
	{
        if ([self parseHttpHeader])
        {
            if ([self hasBytesAvailable])
            {
                [super dataAvailable];
            }
            
            return;
        }
        else
        {
            return;
        }
	}
    else
    {
        [super dataAvailable];
    }
}

-(SInt64) position
{
    return seekStart + relativePosition;
}

-(SInt64) length
{
    return fileLength >= 0 ? fileLength : 0;
}

-(void) reconnect
{
    NSRunLoop* savedEventsRunLoop = eventsRunLoop;
    
    [self close];
    
    eventsRunLoop = savedEventsRunLoop;
	
    [self seekToOffset:self->supportsSeek ? self.position : 0];
}

-(void) seekToOffset:(SInt64)offset
{
    NSRunLoop* savedEventsRunLoop = eventsRunLoop;
    
    [self close];
    
    eventsRunLoop = savedEventsRunLoop;
	
    NSAssert([NSRunLoop currentRunLoop] == eventsRunLoop, @"Seek called on wrong thread");
    
    stream = 0;
    relativePosition = 0;
    dataBytesRead = 0;
    seekStart = offset;
    
    self->isInErrorState = NO;
    
    if (!self->supportsSeek && offset != self->relativePosition)
    {
        return;
    }
    
    [self openForSeek:YES];
}

-(int) readIntoBuffer:(UInt8*)buffer withSize:(int)size
{
    return [self privateReadIntoBuffer:buffer withSize:size];
}

-(int) privateReadIntoBuffer:(UInt8*)buffer withSize:(int)size
{
    if (size == 0)
    {
        return 0;
    }
    
    if (prefixBytes != nil)
    {
        int count = MIN(size, (int)prefixBytes.length - prefixBytesRead);
        
        [prefixBytes getBytes:buffer length:count];
        
        prefixBytesRead += count;
        
        if (prefixBytesRead >= prefixBytes.length)
        {
            prefixBytes = nil;
        }
        
        return count;
    }
    
    int read = [super readIntoBuffer:buffer withSize:size];
    
    if (read < 0)
    {
        return read;
    }
    
    // method will move audio bytes to the beginning of the buffer,
    // and return their number
    read = [self checkForMetaDataInfoWithBuffer:buffer andLength:read];

    relativePosition += read;
    
    return read;
}

-(void) open
{
    return [self openForSeek:NO];
}

-(void) openForSeek:(BOOL)forSeek
{
    // Each (re)connection counts audio bytes from zero, so elapsedSeconds restarts per connection.
    self->connectionAudioBytes = 0;

    if (!forSeek)
    {
        // Fresh feed: re-detect the bitrate for this stream.
        self->parsedFrameBitrate = 0;
    }

	int localRequestSerialNumber;
	
	requestSerialNumber++;
	localRequestSerialNumber = requestSerialNumber;
	
    asyncUrlProvider(self, forSeek, ^(NSURL* url)
    {
		if (localRequestSerialNumber != self->requestSerialNumber)
		{
			return;
		}
	
        self->currentUrl = url;

        if (url == nil)
        {
            return;
        }

        CFHTTPMessageRef message = CFHTTPMessageCreateRequest(NULL, (CFStringRef)@"GET", (__bridge CFURLRef)self->currentUrl, kCFHTTPVersion1_1);

        if (seekStart > 0 && supportsSeek)
        {
            CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Range"), (__bridge CFStringRef)[NSString stringWithFormat:@"bytes=%lld-", seekStart]);

            discontinuous = YES;
        }

        for (NSString* key in self->requestHeaders)
        {
            NSString* value = [self->requestHeaders objectForKey:key];
            
            CFHTTPMessageSetHeaderFieldValue(message, (__bridge CFStringRef)key, (__bridge CFStringRef)value);
        }
        
        CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Accept"), CFSTR("*/*"));
        CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Ice-MetaData"), CFSTR("0"));
        CFHTTPMessageSetHeaderFieldValue(message, CFSTR("icy-metadata"), CFSTR("1"));

        stream = CFReadStreamCreateForHTTPRequest(NULL, message);

        if (stream == nil)
        {
            CFRelease(message);

            [self errorOccured];

            return;
        }
 
        CFReadStreamSetProperty(stream, (__bridge CFStringRef)NSStreamNetworkServiceTypeBackground, (__bridge CFStringRef)NSStreamNetworkServiceTypeBackground);

        if (!CFReadStreamSetProperty(stream, kCFStreamPropertyHTTPShouldAutoredirect, kCFBooleanTrue))
        {
            CFRelease(message);

            [self errorOccured];

            return;
        }

        // Proxy support
        CFDictionaryRef proxySettings = CFNetworkCopySystemProxySettings();
        CFReadStreamSetProperty(stream, kCFStreamPropertyHTTPProxy, proxySettings);
        CFRelease(proxySettings);

        // SSL support
        if ([self->currentUrl.scheme caseInsensitiveCompare:@"https"] == NSOrderedSame)
        {
            NSDictionary* sslSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                         (NSString*)kCFStreamSocketSecurityLevelNegotiatedSSL, kCFStreamSSLLevel,
                                         [NSNumber numberWithBool:NO], kCFStreamSSLValidatesCertificateChain,
                                         nil];
            CFReadStreamSetProperty(stream, kCFStreamPropertySSLSettings, (__bridge CFTypeRef)sslSettings);
        }

        [self reregisterForEvents];
        
		self->httpStatusCode = 0;
		
        // Open
        if (!CFReadStreamOpen(stream))
        {
            CFRelease(stream);
            CFRelease(message);
            
            stream = 0;

            [self errorOccured];

            return;
        }
        
        self->isInErrorState = NO;
        
        CFRelease(message);
    });
}

-(UInt32) httpStatusCode
{
    return self->httpStatusCode;
}

-(NSRunLoop*) eventsRunLoop
{
    return self->eventsRunLoop;
}

-(NSString*) description
{
    return [NSString stringWithFormat:@"HTTP data source with file length: %lld and position: %lld", self.length, self.position];
}

-(BOOL) supportsSeek
{
    return self->supportsSeek;
}

#pragma mark - Meta data

// This code was mostly taken from the link below
// https://code.google.com/p/audiostreamer-meta/

// Returns new length: the number of bytes from buffer that contain audio data.
// Other bytes are meta data bytes and this method "consumes" them.
-(int) checkForMetaDataInfoWithBuffer:(UInt8 *)buffer andLength:(int)length
{
    CFHTTPMessageRef response = (CFHTTPMessageRef)CFReadStreamCopyProperty(stream, kCFStreamPropertyHTTPResponseHeader);

    NSString *bufferString = [[NSString alloc] initWithBytes:buffer length:length encoding:NSUTF8StringEncoding];
    
    if (foundIcyStart == NO && metaDataPresent == NO) {
        // check if this is a ICY 200 OK response
        NSString *icyCheck = [[NSString alloc] initWithBytes:buffer length:10 encoding:NSUTF8StringEncoding];
        if (icyCheck != nil && [icyCheck caseInsensitiveCompare:@"ICY 200 OK"] == NSOrderedSame) {
            foundIcyStart = YES;
        } else {
            NSString *metaInt = (__bridge NSString *) CFHTTPMessageCopyHeaderFieldValue(response, CFSTR("Icy-Metaint"));

            if (metaInt) {
                metaDataPresent = YES;
                metaDataInterval = [metaInt intValue];
            }
        }
    }

    int streamStart = 0;

    if (foundIcyStart == YES && foundIcyEnd == NO) {
        char c[4] = {};

        for (int lineStart = 0; streamStart + 3 < length; ++streamStart) {

            memcpy(c, buffer + streamStart, 4);

            if (c[0] == '\r' && c[1] == '\n') {
                NSString *fullString = [[NSString alloc] initWithBytes:buffer length:streamStart encoding:NSUTF8StringEncoding];

                int length = streamStart - lineStart;
                if (streamStart > lineStart && length > 0 && (lineStart + length) <= [fullString length]) {
                    NSString *line = [fullString substringWithRange:NSMakeRange(lineStart, length)];

                    NSArray *lineItems = [line componentsSeparatedByString:@":"];
                    if (lineItems.count > 1) {
                        if ([lineItems[0] caseInsensitiveCompare:@"icy-metaint"] == NSOrderedSame) {
                            metaDataInterval = [lineItems[1] intValue];
                        } else if ([lineItems[0] caseInsensitiveCompare:@"content-type"] == NSOrderedSame) {
                            AudioFileTypeID idFromMime = [STKHTTPDataSource audioFileTypeHintFromMimeType:lineItems[1]];
                            if (idFromMime != 0) {
                                audioFileTypeHint = idFromMime;
                            }
                        }
                    }

                    // this is the end of a line, the new line starts in 2
                    lineStart = streamStart + 2;

                    if (c[2] == '\r' && c[3] == '\n') {
                        foundIcyEnd = YES;
                        metaDataPresent = YES;
                        streamStart += 4; // skip double new line
                        break;
                    }
                }
            }
        }
    }

    if (metaDataPresent == YES) {
        int audioDataByteCount = 0;

        for (int i = streamStart; i < length; ++i) {
            // is this a metadata byte?
            if (metaDataBytesRemaining > 0) {

                [metaDataString appendFormat:@"%c", buffer[i]];

                if (--metaDataBytesRemaining == 0) {
                    dataBytesRead = 0;

                    // Encoded audio-byte offset of this metadata marker within the current connection
                    // (metadata bytes excluded). Divided by the byte rate this is the seconds into the
                    // stream the marker aligns with, the same way the transcribe-service computes it.
                    UInt64 audioByteOffset = connectionAudioBytes + (UInt64)audioDataByteCount;

                    // Recover the stream's exact CBR bitrate from the first interval of audio so the
                    // offset can be converted to seconds the same way the server does.
                    if (parsedFrameBitrate <= 0 && audioDataByteCount > 0) {
                        parsedFrameBitrate = STKReadFirstMp3FrameBitrate(buffer, audioDataByteCount);
                    }

                    NSMutableDictionary *metaDataDictionary = [[self dictionaryFromMetaData:metaDataString] mutableCopy];
                    metaDataDictionary[@"__audioByteOffset"] = @(audioByteOffset);
                    if (parsedFrameBitrate > 0) {
                        metaDataDictionary[@"__frameBitrate"] = @(parsedFrameBitrate);
                    }
                    [self.delegate dataSource:self didUpdateMetaData:metaDataDictionary bytes:(i - streamStart)];
                }

                continue;
            }

            // is this the interval byte?
            if (metaDataInterval > 0 && dataBytesRead == metaDataInterval) {

                metaDataBytesRemaining = buffer[i] * 16;

                metaDataString.string = @"";

                if (metaDataBytesRemaining == 0) {
                    dataBytesRead = 0;
                }

                continue;
            }

            // this is a data byte
            ++dataBytesRead;

            // overwrite beginning of the buffer with the real audio data
            // we don't need those bytes any more, since we already examined them
            buffer[audioDataByteCount++] = buffer[i];
        }

        // Track audio bytes for this connection so markers in later buffers get the right offset.
        connectionAudioBytes += (UInt64)audioDataByteCount;

        return audioDataByteCount;

    } else if (foundIcyStart == YES) { // still parsing icy response

        return 0;

    } else { // no meta data in stream

        return length;

    }
}

-(NSDictionary *) dictionaryFromMetaData:(NSString *)metaData
{
    NSArray *components = [metaData componentsSeparatedByString:@";"];

    NSMutableDictionary *dictionary = [NSMutableDictionary new];

    for (NSString *entry in components) {
        NSInteger equalitySignPosition = [entry rangeOfString:@"="].location;
        if (equalitySignPosition != NSNotFound) {
            NSString *key = [entry substringToIndex:equalitySignPosition];
            NSString *value = [entry substringFromIndex:equalitySignPosition + 1];
            u_long length = value.length - 2;
            if (value.length > 2 && length > 0 && (1 + length) <= value.length) {
                NSString *valueWithoutQuotes = [value substringWithRange:NSMakeRange(1, length)];

                dictionary[key] = valueWithoutQuotes;
            }
        }
    }

    return dictionary;
}


@end
