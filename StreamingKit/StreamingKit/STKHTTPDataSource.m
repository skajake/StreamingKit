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

@interface STKHTTPDataSource() <NSURLSessionDataDelegate>
{
@private
    BOOL supportsSeek;
    UInt32 httpStatusCode;
    SInt64 seekStart;
    SInt64 relativePosition;
    SInt64 fileLength;
    int discontinuous;
	int requestSerialNumber;

    NSURL* currentUrl;
    STKAsyncURLProvider asyncUrlProvider;
    NSDictionary* httpHeaders;
    AudioFileTypeID audioFileTypeHint;
    NSDictionary* requestHeaders;

    NSURLSession* urlSession;
    NSURLSessionDataTask* dataTask;
    NSOperationQueue* delegateQueue;

    // Meta data
    BOOL metaDataPresent;
    unsigned int metaDataInterval;        // how many data bytes between meta data
    unsigned int metaDataBytesRemaining;  // how many bytes of metadata remain to be read
    unsigned int dataBytesRead;           // how many bytes of data have been read
    NSMutableString *metaDataString;      //  meta data string
}
-(void) open;

@end

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

        delegateQueue = [[NSOperationQueue alloc] init];
        delegateQueue.maxConcurrentOperationCount = 1;
        delegateQueue.name = @"com.streamingkit.httpdatasource";
    }

    return self;
}

-(void) dealloc
{
    NSLog(@"STKHTTPDataSource dealloc");

    [self teardownSession];
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

-(id) headerValueForKey:(NSString*)key
{
    // NSHTTPURLResponse.allHeaderFields keys are typically canonicalised but
    // the spec says header lookup is case-insensitive; keep a defensive double
    // lookup that preserves the old dual-case behaviour.
    id value = [httpHeaders objectForKey:key];
    if (value != nil)
    {
        return value;
    }
    return [httpHeaders objectForKey:[key lowercaseString]];
}

-(void) applyResponseHeaders:(NSHTTPURLResponse*)response
{
    self->httpStatusCode = (UInt32)response.statusCode;
    self->httpHeaders = response.allHeaderFields;

    if ([self headerValueForKey:@"Accept-Ranges"] != nil)
    {
        self->supportsSeek = YES;
    }

    NSString* metaInt = [self headerValueForKey:@"icy-metaint"] ?: [self headerValueForKey:@"Icy-Metaint"];
    if (metaInt.length > 0)
    {
        metaDataPresent = YES;
        metaDataInterval = (unsigned int)[metaInt intValue];
    }

    if (self.httpStatusCode == 200)
    {
        if (seekStart == 0)
        {
            id value = [self headerValueForKey:@"Content-Length"];
            fileLength = (SInt64)[value longLongValue];
        }

        NSString* contentType = [self headerValueForKey:@"Content-Type"];
        AudioFileTypeID typeIdFromMimeType = [STKHTTPDataSource audioFileTypeHintFromMimeType:contentType];

        if (typeIdFromMimeType != 0)
        {
            audioFileTypeHint = typeIdFromMimeType;
        }
    }
    else if (self.httpStatusCode == 206)
    {
        NSString* contentRange = [self headerValueForKey:@"Content-Range"];
        NSArray* components = [contentRange componentsSeparatedByString:@"/"];

        if (components.count == 2)
        {
            fileLength = [[components objectAtIndex:1] integerValue];
        }
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

-(void) teardownSession
{
    if (dataTask)
    {
        [dataTask cancel];
        dataTask = nil;
    }

    if (urlSession)
    {
        [urlSession invalidateAndCancel];
        urlSession = nil;
    }
}

-(void) close
{
    [self teardownSession];
    [super close];
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

    int read = [super readIntoBuffer:buffer withSize:size];

    if (read <= 0)
    {
        return read;
    }

    // method will move audio bytes to the beginning of the buffer,
    // and return their number
    read = [self demultiplexMetaDataFromBuffer:buffer andLength:read];

    relativePosition += read;

    return read;
}

-(void) open
{
    return [self openForSeek:NO];
}

-(void) openForSeek:(BOOL)forSeek
{
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

        [self resetBuffer];

        NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];
        request.HTTPMethod = @"GET";
        request.networkServiceType = NSURLNetworkServiceTypeBackground;

        if (self->seekStart > 0 && self->supportsSeek)
        {
            [request setValue:[NSString stringWithFormat:@"bytes=%lld-", self->seekStart] forHTTPHeaderField:@"Range"];

            self->discontinuous = YES;
        }

        for (NSString* key in self->requestHeaders)
        {
            NSString* value = [self->requestHeaders objectForKey:key];

            [request setValue:value forHTTPHeaderField:key];
        }

        [request setValue:@"*/*" forHTTPHeaderField:@"Accept"];
        [request setValue:@"0" forHTTPHeaderField:@"Ice-MetaData"];
        [request setValue:@"1" forHTTPHeaderField:@"icy-metadata"];

        NSURLSessionConfiguration* config = [NSURLSessionConfiguration defaultSessionConfiguration];
        // Default config already picks up system proxy settings.

        self->urlSession = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:self->delegateQueue];

        self->httpStatusCode = 0;
        self->httpHeaders = nil;
        self->metaDataPresent = NO;
        self->metaDataInterval = 0;
        self->metaDataBytesRemaining = 0;
        self->dataBytesRead = 0;

        self->dataTask = [self->urlSession dataTaskWithRequest:request];
        [self->dataTask resume];

        self->isInErrorState = NO;
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

#pragma mark - NSURLSessionDataDelegate

-(void) URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)task
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler
{
    if (task != self->dataTask)
    {
        completionHandler(NSURLSessionResponseCancel);
        return;
    }

    if (![response isKindOfClass:[NSHTTPURLResponse class]])
    {
        completionHandler(NSURLSessionResponseAllow);
        return;
    }

    NSHTTPURLResponse* httpResponse = (NSHTTPURLResponse*)response;
    [self applyResponseHeaders:httpResponse];

    if (self.httpStatusCode == 416)
    {
        if (self.length >= 0)
        {
            seekStart = self.length;
        }

        completionHandler(NSURLSessionResponseCancel);
        [self didComplete];
        return;
    }

    if (self.httpStatusCode >= 300)
    {
        completionHandler(NSURLSessionResponseCancel);
        [self didFailWithError:nil];
        return;
    }

    [self didOpen];
    completionHandler(NSURLSessionResponseAllow);
}

-(void) URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)task
    didReceiveData:(NSData *)data
{
    if (task != self->dataTask)
    {
        return;
    }

    [self didReceiveData:data];
}

-(void) URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error
{
    if (task != self->dataTask)
    {
        return;
    }

    if (error)
    {
        // -999 is NSURLErrorCancelled — we cancelled ourselves for seek/reconnect.
        if (error.code == NSURLErrorCancelled && [error.domain isEqualToString:NSURLErrorDomain])
        {
            return;
        }

        [self didFailWithError:error];
    }
    else
    {
        [self didComplete];
    }
}

-(void) URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler
{
    if (task != self->dataTask)
    {
        completionHandler(nil);
        return;
    }

    self->currentUrl = request.URL;
    completionHandler(request);
}

-(void) URLSession:(NSURLSession *)session
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable))completionHandler
{
    // Match the legacy behaviour of kCFStreamSSLValidatesCertificateChain = NO:
    // trust whatever the server presents.
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust])
    {
        SecTrustRef serverTrust = challenge.protectionSpace.serverTrust;
        if (serverTrust != NULL)
        {
            NSURLCredential* credential = [NSURLCredential credentialForTrust:serverTrust];
            completionHandler(NSURLSessionAuthChallengeUseCredential, credential);
            return;
        }
    }

    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}

#pragma mark - Meta data

// This code was mostly taken from the link below
// https://code.google.com/p/audiostreamer-meta/

// Returns new length: the number of bytes from buffer that contain audio data.
// Other bytes are meta data bytes and this method "consumes" them.
-(int) demultiplexMetaDataFromBuffer:(UInt8 *)buffer andLength:(int)length
{
    if (!metaDataPresent || metaDataInterval == 0)
    {
        return length;
    }

    int audioDataByteCount = 0;

    for (int i = 0; i < length; ++i) {
        // is this a metadata byte?
        if (metaDataBytesRemaining > 0) {

            [metaDataString appendFormat:@"%c", buffer[i]];

            if (--metaDataBytesRemaining == 0) {
                dataBytesRead = 0;

                NSDictionary *metaDataDictionary = [self dictionaryFromMetaData:metaDataString];
                [self.delegate dataSource:self didUpdateMetaData:metaDataDictionary bytes:i];
            }

            continue;
        }

        // is this the interval byte?
        if (dataBytesRead == metaDataInterval) {

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

    return audioDataByteCount;
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
