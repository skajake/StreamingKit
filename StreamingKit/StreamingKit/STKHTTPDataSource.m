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
#import <Network/Network.h>

// Hard caps so a malformed server can't grow our head buffer or redirect chain
// without bound.
#define STK_HTTP_HEAD_LIMIT      (64 * 1024)
#define STK_HTTP_MAX_REDIRECTS   5
#define STK_HTTP_RECEIVE_MAX     65536

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

    NSURL* currentUrl;
    STKAsyncURLProvider asyncUrlProvider;
    NSDictionary* httpHeaders;
    AudioFileTypeID audioFileTypeHint;
    NSDictionary* requestHeaders;

    nw_connection_t connection;
    dispatch_queue_t connectionQueue;
    NSMutableData* responseHeadBuffer;
    BOOL responseHeadParsed;
    int redirectCount;

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

        connectionQueue = dispatch_queue_create("com.streamingkit.httpdatasource", DISPATCH_QUEUE_SERIAL);
    }

    return self;
}

-(void) dealloc
{
    NSLog(@"STKHTTPDataSource dealloc");

    [self teardownConnection];
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

    NSString* lookupKey = mimeType;
    NSRange semi = [mimeType rangeOfString:@";"];
    if (semi.location != NSNotFound)
    {
        lookupKey = [mimeType substringToIndex:semi.location];
    }
    lookupKey = [[lookupKey stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString];

    NSNumber* number = [fileTypesByMimeType objectForKey:lookupKey];

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
    // Headers are stored lowercase by the parser; do a case-insensitive lookup.
    return [httpHeaders objectForKey:[key lowercaseString]];
}

-(void) applyParsedStatus:(int)statusCode headers:(NSDictionary*)headers
{
    self->httpStatusCode = (UInt32)statusCode;
    self->httpHeaders = headers;

    if ([self headerValueForKey:@"Accept-Ranges"] != nil)
    {
        self->supportsSeek = YES;
    }

    NSString* metaInt = [self headerValueForKey:@"icy-metaint"];
    if (metaInt.length > 0)
    {
        metaDataPresent = YES;
        metaDataInterval = (unsigned int)[metaInt intValue];
    }

    if (statusCode == 200)
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
    else if (statusCode == 206)
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

-(void) teardownConnection
{
    nw_connection_t toCancel = self->connection;
    self->connection = nil;

    if (toCancel)
    {
        // Cancel on the connection queue so any in-flight callbacks finish
        // first; once cancelled, the state handler block is released, taking
        // the connection's last retain with it.
        dispatch_async(connectionQueue, ^
        {
            nw_connection_cancel(toCancel);
        });
    }
}

-(void) close
{
    [self teardownConnection];
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
    self->isInErrorState = NO;

    if (self->supportsSeek)
    {
        seekStart = offset;
    }
    else
    {
        // Non-seekable (live) stream. The audio player's mid-stream recovery
        // path (STKAudioPlayer readIntoBuffer == -1) issues
        // seekToOffset:currentPosition to force a reopen — honour that as a
        // reopen-from-zero rather than silently no-op'ing. Genuine user seeks
        // are gated against supportsSeek upstream and never reach here.
        seekStart = 0;
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
            NSLog(@"STKHTTPDataSource: URL callback superseded (got #%d, current #%d)", localRequestSerialNumber, self->requestSerialNumber);
			return;
		}

        if (url == nil)
        {
            // The URL provider failed (e.g. a license fetch returned nothing).
            // The audio player is waiting on us — surface the failure so it
            // doesn't sit in a buffering state forever.
            NSLog(@"STKHTTPDataSource: URL provider returned nil; emitting error");
            [self didFailWithError:nil];
            return;
        }

        // Move all setup onto the connection queue so connection state is only
        // ever touched from one thread.
        dispatch_async(self->connectionQueue, ^
        {
            if (localRequestSerialNumber != self->requestSerialNumber)
            {
                NSLog(@"STKHTTPDataSource: queued setup superseded (got #%d, current #%d)", localRequestSerialNumber, self->requestSerialNumber);
                return;
            }

            [self resetForRequest];
            self->currentUrl = url;
            NSLog(@"STKHTTPDataSource: opening %@ (forSeek=%d, seekStart=%lld)", url.absoluteString, forSeek, self->seekStart);
            [self startConnectionToURL:url];
        });
    });
}

-(void) resetForRequest
{
    [self resetBuffer];
    self->httpStatusCode = 0;
    self->httpHeaders = nil;
    self->metaDataPresent = NO;
    self->metaDataInterval = 0;
    self->metaDataBytesRemaining = 0;
    self->dataBytesRead = 0;
    self->responseHeadBuffer = [[NSMutableData alloc] init];
    self->responseHeadParsed = NO;
    self->redirectCount = 0;
    self->isInErrorState = NO;
}

-(void) startConnectionToURL:(NSURL*)url
{
    NSString* scheme = [url.scheme lowercaseString];
    BOOL isTLS = [scheme isEqualToString:@"https"];

    if (!isTLS && ![scheme isEqualToString:@"http"])
    {
        [self didFailWithError:nil];
        return;
    }

    NSString* host = url.host;
    if (host.length == 0)
    {
        [self didFailWithError:nil];
        return;
    }

    int port = url.port ? url.port.intValue : (isTLS ? 443 : 80);
    NSString* portString = [NSString stringWithFormat:@"%d", port];

    nw_endpoint_t endpoint = nw_endpoint_create_host([host UTF8String], [portString UTF8String]);

    nw_parameters_configure_protocol_block_t tlsConfig;
    if (isTLS)
    {
        tlsConfig = ^(nw_protocol_options_t tls_options)
        {
            sec_protocol_options_t sec_options = nw_tls_copy_sec_protocol_options(tls_options);
            // Match the legacy CFStream behaviour of
            // kCFStreamSSLValidatesCertificateChain = NO. Streaming radio
            // servers commonly present self-signed or hostname-mismatched
            // certs; the original library accepted them.
            sec_protocol_options_set_verify_block(sec_options,
                ^(sec_protocol_metadata_t metadata, sec_trust_t trust_ref, sec_protocol_verify_complete_t complete)
                {
                    complete(true);
                },
                dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0));
        };
    }
    else
    {
        tlsConfig = NW_PARAMETERS_DISABLE_PROTOCOL;
    }

    nw_parameters_t parameters = nw_parameters_create_secure_tcp(tlsConfig, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_parameters_set_service_class(parameters, nw_service_class_background);

    nw_connection_t conn = nw_connection_create(endpoint, parameters);
    self->connection = conn;
    nw_connection_set_queue(conn, connectionQueue);

    __weak STKHTTPDataSource* weakSelf = self;
    nw_connection_set_state_changed_handler(conn, ^(nw_connection_state_t state, nw_error_t error)
    {
        STKHTTPDataSource* strongSelf = weakSelf;
        if (!strongSelf)
        {
            return;
        }
        if (strongSelf->connection != conn)
        {
            NSLog(@"STKHTTPDataSource: state %d on stale conn, ignoring", (int)state);
            return;
        }

        switch (state)
        {
            case nw_connection_state_waiting:
                NSLog(@"STKHTTPDataSource: waiting (likely no network) for %@", url.host);
                break;
            case nw_connection_state_preparing:
                break;
            case nw_connection_state_ready:
            {
                NSLog(@"STKHTTPDataSource: connection ready to %@", url.host);
                NSData* requestData = [strongSelf buildRequestForURL:url];
                [strongSelf sendRequest:requestData onConnection:conn];
                [strongSelf receiveOnConnection:conn];
                break;
            }
            case nw_connection_state_failed:
            {
                int errorCode = error ? nw_error_get_error_code(error) : 0;
                NSLog(@"STKHTTPDataSource: connection failed for %@ (err=%d)", url.host, errorCode);
                [strongSelf didFailWithError:nil];
                break;
            }
            case nw_connection_state_cancelled:
                // Either we cancelled (teardown) or the failure path already
                // emitted; nothing to do here.
                break;
            default:
                break;
        }
    });

    NSLog(@"STKHTTPDataSource: starting connection to %@:%@ (tls=%d)", host, portString, isTLS);
    nw_connection_start(conn);
}

-(NSData*) buildRequestForURL:(NSURL*)url
{
    // NSURL.path is percent-decoded; the wire form has to keep percent encoding.
    NSURLComponents* components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString* path = components.percentEncodedPath;
    if (path.length == 0)
    {
        path = @"/";
    }
    NSString* query = components.percentEncodedQuery;
    if (query.length > 0)
    {
        path = [path stringByAppendingFormat:@"?%@", query];
    }

    NSMutableString* request = [NSMutableString string];
    [request appendFormat:@"GET %@ HTTP/1.0\r\n", path];

    NSString* hostHeader = url.host;
    NSNumber* portNum = url.port;
    BOOL isDefaultPort = (portNum == nil) ||
        ([url.scheme.lowercaseString isEqualToString:@"http"] && portNum.intValue == 80) ||
        ([url.scheme.lowercaseString isEqualToString:@"https"] && portNum.intValue == 443);
    if (!isDefaultPort)
    {
        hostHeader = [NSString stringWithFormat:@"%@:%@", url.host, portNum];
    }
    [request appendFormat:@"Host: %@\r\n", hostHeader];

    if (self->seekStart > 0 && self->supportsSeek)
    {
        [request appendFormat:@"Range: bytes=%lld-\r\n", self->seekStart];
        self->discontinuous = YES;
    }

    BOOL hasUserAgent = NO;
    for (NSString* key in self->requestHeaders)
    {
        NSString* value = [self->requestHeaders objectForKey:key];
        [request appendFormat:@"%@: %@\r\n", key, value];
        if ([key caseInsensitiveCompare:@"User-Agent"] == NSOrderedSame)
        {
            hasUserAgent = YES;
        }
    }

    // SHOUTcast servers commonly reject requests without a User-Agent. The old
    // CFStream path got away without one; be defensive here.
    if (!hasUserAgent)
    {
        [request appendString:@"User-Agent: StreamingKit\r\n"];
    }

    [request appendString:@"Accept: */*\r\n"];
    [request appendString:@"Ice-MetaData: 0\r\n"];
    [request appendString:@"icy-metadata: 1\r\n"];
    [request appendString:@"\r\n"];

    return [request dataUsingEncoding:NSUTF8StringEncoding];
}

-(void) sendRequest:(NSData*)data onConnection:(nw_connection_t)conn
{
    if (data.length == 0)
    {
        return;
    }

    // DISPATCH_DATA_DESTRUCTOR_DEFAULT copies the bytes, so we don't have to
    // keep `data` alive ourselves.
    dispatch_data_t payload = dispatch_data_create(data.bytes, data.length,
        connectionQueue, DISPATCH_DATA_DESTRUCTOR_DEFAULT);

    __weak STKHTTPDataSource* weakSelf = self;
    nw_connection_send(conn, payload, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true,
        ^(nw_error_t sendError)
        {
            if (sendError == NULL)
            {
                return;
            }
            STKHTTPDataSource* strongSelf = weakSelf;
            if (!strongSelf || strongSelf->connection != conn)
            {
                return;
            }
            [strongSelf didFailWithError:nil];
        });
}

-(void) receiveOnConnection:(nw_connection_t)conn
{
    __weak STKHTTPDataSource* weakSelf = self;
    nw_connection_receive(conn, 1, STK_HTTP_RECEIVE_MAX,
        ^(dispatch_data_t content, nw_content_context_t context, bool is_complete, nw_error_t receive_error)
        {
            STKHTTPDataSource* strongSelf = weakSelf;
            if (!strongSelf || strongSelf->connection != conn)
            {
                return;
            }

            if (content && dispatch_data_get_size(content) > 0)
            {
                NSData* received = [strongSelf nsDataFromDispatchData:content];
                [strongSelf processReceivedData:received];
                if (strongSelf->connection != conn)
                {
                    // processReceivedData may have torn the connection down
                    // (e.g. redirect or 4xx) — bail out before re-arming.
                    return;
                }
            }

            if (receive_error)
            {
                [strongSelf didFailWithError:nil];
                return;
            }

            if (is_complete)
            {
                if (strongSelf->responseHeadParsed)
                {
                    NSLog(@"STKHTTPDataSource: stream ended for %@", strongSelf->currentUrl.host);
                    [strongSelf didComplete];
                }
                else
                {
                    NSLog(@"STKHTTPDataSource: stream ended before head complete for %@ (head bytes so far: %lu)", strongSelf->currentUrl.host, (unsigned long)strongSelf->responseHeadBuffer.length);
                    [strongSelf didFailWithError:nil];
                }
                return;
            }

            [strongSelf receiveOnConnection:conn];
        });
}

-(NSData*) nsDataFromDispatchData:(dispatch_data_t)data
{
    size_t size = dispatch_data_get_size(data);
    NSMutableData* result = [NSMutableData dataWithCapacity:size];
    dispatch_data_apply(data, ^bool(dispatch_data_t region, size_t offset, const void* buffer, size_t blockSize)
    {
        [result appendBytes:buffer length:blockSize];
        return true;
    });
    return result;
}

-(void) processReceivedData:(NSData*)data
{
    if (responseHeadParsed)
    {
        [self didReceiveData:data];
        return;
    }

    [responseHeadBuffer appendData:data];

    static NSData* terminator = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^
    {
        terminator = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    });

    NSRange range = [responseHeadBuffer rangeOfData:terminator
                                            options:0
                                              range:NSMakeRange(0, responseHeadBuffer.length)];

    if (range.location == NSNotFound)
    {
        if (responseHeadBuffer.length > STK_HTTP_HEAD_LIMIT)
        {
            [self didFailWithError:nil];
        }
        return;
    }

    NSUInteger headEnd = range.location + range.length;
    NSData* headData = [responseHeadBuffer subdataWithRange:NSMakeRange(0, range.location)];
    NSData* bodyTail = nil;
    if (headEnd < responseHeadBuffer.length)
    {
        bodyTail = [responseHeadBuffer subdataWithRange:NSMakeRange(headEnd, responseHeadBuffer.length - headEnd)];
    }

    NSString* headStr = [[NSString alloc] initWithData:headData encoding:NSUTF8StringEncoding];
    if (!headStr)
    {
        // Fall back to a permissive 8-bit encoding — header bytes should be
        // ASCII but some misbehaving servers slip in non-UTF-8 characters.
        headStr = [[NSString alloc] initWithData:headData encoding:NSISOLatin1StringEncoding];
    }
    if (!headStr)
    {
        [self didFailWithError:nil];
        return;
    }

    int statusCode = 0;
    NSMutableDictionary* headers = [NSMutableDictionary new];
    if (![self parseHeadString:headStr statusCode:&statusCode headers:headers])
    {
        NSLog(@"STKHTTPDataSource: failed to parse response head: %@", [headStr length] > 200 ? [headStr substringToIndex:200] : headStr);
        [self didFailWithError:nil];
        return;
    }

    NSLog(@"STKHTTPDataSource: %@ -> %d", currentUrl.host, statusCode);

    responseHeadParsed = YES;
    responseHeadBuffer = nil;

    // Redirect handling. Per RFC, only 3xx with a Location header redirects;
    // we follow up to STK_HTTP_MAX_REDIRECTS to mirror CFNetwork's behaviour.
    if (statusCode >= 300 && statusCode < 400)
    {
        NSString* location = headers[@"location"];
        if (location.length > 0 && redirectCount < STK_HTTP_MAX_REDIRECTS)
        {
            redirectCount++;
            NSURL* nextUrl = [NSURL URLWithString:location relativeToURL:currentUrl];
            if (nextUrl != nil)
            {
                // Reuse this same data source; tear down the current
                // connection and start the next one.
                nw_connection_t toCancel = self->connection;
                self->connection = nil;
                if (toCancel)
                {
                    nw_connection_cancel(toCancel);
                }

                self->httpStatusCode = 0;
                self->httpHeaders = nil;
                self->metaDataPresent = NO;
                self->metaDataInterval = 0;
                self->metaDataBytesRemaining = 0;
                self->dataBytesRead = 0;
                self->responseHeadBuffer = [[NSMutableData alloc] init];
                self->responseHeadParsed = NO;

                self->currentUrl = nextUrl;
                [self startConnectionToURL:nextUrl];
                return;
            }
        }

        [self applyParsedStatus:statusCode headers:headers];
        [self didFailWithError:nil];
        return;
    }

    [self applyParsedStatus:statusCode headers:headers];

    if (statusCode == 416)
    {
        if (self.length >= 0)
        {
            seekStart = self.length;
        }
        [self didComplete];
        return;
    }

    if (statusCode >= 400)
    {
        [self didFailWithError:nil];
        return;
    }

    [self didOpen];

    if (bodyTail.length > 0)
    {
        [self didReceiveData:bodyTail];
    }
}

-(BOOL) parseHeadString:(NSString*)headStr
             statusCode:(int*)outStatus
                headers:(NSMutableDictionary*)outHeaders
{
    NSArray* lines = [headStr componentsSeparatedByString:@"\r\n"];
    if (lines.count == 0)
    {
        return NO;
    }

    NSString* statusLine = lines[0];
    // First token is the protocol — "HTTP/1.x" for normal HTTP, or "ICY" for
    // SHOUTcast 1.x servers. Accept both.
    NSRange firstSpace = [statusLine rangeOfString:@" "];
    if (firstSpace.location == NSNotFound)
    {
        return NO;
    }
    NSString* protocol = [statusLine substringToIndex:firstSpace.location];
    NSString* rest = [statusLine substringFromIndex:firstSpace.location + 1];

    BOOL validProtocol = [protocol hasPrefix:@"HTTP/"] ||
        [protocol caseInsensitiveCompare:@"ICY"] == NSOrderedSame;
    if (!validProtocol)
    {
        return NO;
    }

    NSRange secondSpace = [rest rangeOfString:@" "];
    NSString* codeString = secondSpace.location == NSNotFound ? rest : [rest substringToIndex:secondSpace.location];
    int code = [codeString intValue];
    if (code == 0)
    {
        return NO;
    }
    *outStatus = code;

    for (NSUInteger i = 1; i < lines.count; i++)
    {
        NSString* line = lines[i];
        if (line.length == 0)
        {
            continue;
        }
        NSRange colonRange = [line rangeOfString:@":"];
        if (colonRange.location == NSNotFound)
        {
            continue;
        }
        NSString* key = [[line substringToIndex:colonRange.location] lowercaseString];
        NSString* value = [[line substringFromIndex:colonRange.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        outHeaders[key] = value;
    }

    return YES;
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
