/*
 Copyright 2015 XWebView

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
*/

import Foundation

protocol XWVHttpConnectionDelegate {
    func handleRequest(_ request: URLRequest) -> HTTPURLResponse
    func didOpenConnection(_ connection: XWVHttpConnection)
    func didCloseConnection(_ connection: XWVHttpConnection)
}

final class XWVHttpConnection : NSObject {
    fileprivate let handle: CFSocketNativeHandle
    fileprivate let delegate: XWVHttpConnectionDelegate
    fileprivate var input: InputStream!
    fileprivate var output: OutputStream!
    fileprivate let bufferMaxSize = 64 * 1024

    // input state
    fileprivate var requestQueue = [URLRequest]()
    fileprivate var inputBuffer: NSMutableData!
    fileprivate var cursor: Int = 0

    // output state
    fileprivate var outputBuffer: Data!
    fileprivate var bytesRemained: Int = 0
    fileprivate var fileHandle: FileHandle!
    fileprivate var fileSize: Int = 0

    init(handle: CFSocketNativeHandle, delegate: XWVHttpConnectionDelegate) {
        self.handle = handle
        self.delegate = delegate
        super.init()
    }

    func open() -> Bool {
        let ptr1 = UnsafeMutablePointer<Unmanaged<CFReadStream>?>.allocate(capacity: 1)
        let ptr2 = UnsafeMutablePointer<Unmanaged<CFWriteStream>?>.allocate(capacity: 1)
        defer {
            ptr1.deallocate(capacity: 1)
            ptr2.deallocate(capacity: 1)
        }
        CFStreamCreatePairWithSocket(nil, handle, ptr1, ptr2)
        if ptr1.pointee == nil || ptr2.pointee == nil { return false }

        input = ptr1.pointee!.takeRetainedValue()
        output = ptr2.pointee!.takeRetainedValue()
        CFReadStreamSetProperty(input, CFStreamPropertyKey(kCFStreamPropertyShouldCloseNativeSocket), kCFBooleanTrue)
        CFWriteStreamSetProperty(output, CFStreamPropertyKey(kCFStreamPropertyShouldCloseNativeSocket), kCFBooleanTrue)

        input.delegate = self
        output.delegate = self
        input.schedule(in: RunLoop.current, forMode: RunLoopMode.defaultRunLoopMode)
        output.schedule(in: RunLoop.current, forMode: RunLoopMode.defaultRunLoopMode)
        input.open()
        output.open()
        delegate.didOpenConnection(self)
        return true
    }

    func close() {
        input.close()
        output.close()
        input = nil
        output = nil
        delegate.didCloseConnection(self)
    }
}

extension XWVHttpConnection : StreamDelegate {
    @objc func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case Stream.Event.openCompleted:
            // Initialize input/output state.
            if aStream === input {
                inputBuffer = NSMutableData(length: 512)
                cursor = 0;
            } else {
                outputBuffer = nil
                fileHandle = nil
                fileSize = 0
            }

        case Stream.Event.hasBytesAvailable:
            let base = UnsafeMutablePointer<UInt8>(inputBuffer.mutableBytes)
            
            
            let bytesReaded = input.read(base.advanced(by: cursor), maxLength: inputBuffer.length - cursor)
            guard bytesReaded > 0 else { break }

            var bytesConsumed = 0
            var ptr = cursor > 3 ? base.advanced(by: cursor - 3): base
            for _ in 0 ..< bytesReaded {
                if UnsafePointer<UInt32>(ptr).pointee == UInt32(bigEndian: 0x0d0a0d0a) {
                    // End of request header.
                    ptr += 3
                    let data = inputBuffer.subdata(with: NSRange(bytesConsumed...base.distance(to: ptr)))
                    if let request = NSMutableURLRequest(data: data) {
                        requestQueue.insert(request, at: 0)
                    } else {
                        // Bad request
                        requestQueue.insert(URLRequest(), at: 0)
                    }
                    bytesConsumed += data.count
                }
                ptr = ptr.successor()
            }
            if bytesConsumed > 0 {
                // Move remained bytes to the begining.
                inputBuffer.replaceBytes(in: NSRange(0..<bytesConsumed), withBytes: nil, length: 0)
            } else if bytesReaded + cursor == inputBuffer.length {
                // Enlarge input buffer.
                guard inputBuffer.length < bufferMaxSize else {
                    close()
                    break
                }
                inputBuffer.length <<= 1
            }
            cursor += bytesReaded - bytesConsumed
            if output.hasSpaceAvailable { fallthrough }

        case Stream.Event.hasSpaceAvailable:
            if outputBuffer == nil {
                guard let request = requestQueue.popLast() else { break }
                let response = delegate.handleRequest(request)
                if request.httpMethod == "GET", let fileURL = response.url , fileURL.isFileURL {
                    fileHandle = try! FileHandle(forReadingFrom: fileURL)
                    fileSize = Int(fileHandle.seekToEndOfFile())
                }
                outputBuffer = response.octetsOfHeaders
                bytesRemained = outputBuffer.count + fileSize
            }

            var bytesSent = 0
            repeat {
                let off: Int
                if bytesRemained > fileSize {
                    // Send response header
                    off = outputBuffer.count - (bytesRemained - fileSize)
                } else {
                    // Send file content
                    off = (fileSize - bytesRemained) % bufferMaxSize
                    if off == 0 {
                        fileHandle.seek(toFileOffset: UInt64(fileSize - bytesRemained))
                        outputBuffer = fileHandle.readData(ofLength: bufferMaxSize)
                    }
                }
                let ptr = outputBuffer.bytes.bindMemory(to: UInt8.self, capacity: outputBuffer.count)
                bytesSent = output.write(ptr.advancedBy(off), maxLength: outputBuffer.count - off)
                bytesRemained -= bytesSent
            } while bytesRemained > 0 && output.hasSpaceAvailable && bytesSent > 0
            if bytesRemained == 0 {
                // Response has been sent completely.
                fileHandle = nil
                fileSize = 0
                outputBuffer = nil
            }
            if bytesSent < 0 { fallthrough }

        case Stream.Event.errorOccurred:
            let error = aStream.streamError?.localizedDescription ?? "Unknown"
            log("!HTTP connection error: \(error)")
            fallthrough

        case Stream.Event.endEncountered:
            fileHandle = nil
            inputBuffer = nil
            outputBuffer = nil
            close()

        default:
            break
        }
    }
}

private extension String {
    mutating func trim(_ predicate: (Character) -> Bool) {
        if !isEmpty {
            var start = startIndex
            while start != endIndex && predicate(self[start]) {
                start = self.index(after: start)
            }
            if start < endIndex {
                var end = endIndex
                repeat {
                  end  = self.index(before: end)
                } while predicate(self[end])
                self = self[start ... end]
            } else {
                self = ""
            }
        }
    }
}

private extension NSMutableURLRequest {
    enum Version : String {
        case v1_0 = "HTTP/1.0"
        case v1_1 = "HTTP/1.1"
    }
    enum Method : String {
        case Get     = "GET"
        case Head    = "HEAD"
        case Post    = "POST"
        case Put     = "PUT"
        case Delete  = "DELETE"
        case Connect = "CONNECT"
        case Options = "OPTIONS"
        case Trace   = "TRACE"
    }
    var CRLF: Data {
        var CRLF: [UInt8] = [ 0x0d, 0x0a ]
//        return Data(bytes: &CRLF, count: 2)
        return Data(bytes: UnsafePointer<UInt8>(&CRLF), count: 2)
        //TODO maybe like this
    }

    convenience init?(data: Data) {
        self.init()
        var cursor = 0
        repeat {
            let range = Range<Int>(cursor..<data.count)
          
            guard let end = data.range(of: CRLF, options: NSData.SearchOptions(rawValue: 0), in: range)?.lowerBound,
                  let line = String(data: data.subdata(in: range), encoding: .ascii) else {
                return nil
            }
          
            if cursor == 0 {
                // request line
                var method: Method?
                var target: String = ""
                var version: Version?
                if let sp = line.characters.index(of: " ") {
                    method = Method(rawValue: line[line.startIndex ..< sp])
                  
                    target = line[line.characters.index(after: sp) ..< line.endIndex]
                    if method != nil, let sp = target.characters.index(of: " ") {
                      
                        version = Version(rawValue: target[line.characters.index(after: sp) ..< target.endIndex])
                        target = target[target.startIndex ..< sp]
                    }
                }
                guard version != nil else { return nil }
                httpMethod = method!.rawValue
                url = URL(string: target)
            } else if !line.isEmpty {
                // header field
                guard let colon = line.characters.index(of: ":") else { return nil }
                let name = line[line.startIndex ..< colon]
              
              
                var value = line[line.characters.index(after: colon) ..< line.endIndex]
                value.trim { $0 == " " || $0 == "\t" }
                if self.value(forHTTPHeaderField: name) != nil {
                    addValue(value, forHTTPHeaderField:name)
                } else {
                    setValue(value, forHTTPHeaderField:name)
                }
            }
            cursor = end + 2
        } while cursor < data.count
    }
}

private extension HTTPURLResponse {
    var octetsOfHeaders: Data {
        assert(statusCode > 100 && statusCode < 600)
        let reason = HTTPURLResponse.localizedString(forStatusCode: statusCode).capitalized
        let statusLine = "HTTP/1.1 \(statusCode) \(reason)\r\n"
      
        var data = allHeaderFields.reduce(NSData(data: statusLine.data(using: String.Encoding.ascii)!) as Data) {
            var result = $0
        
            result.append(($1.0 as! NSString).data(using: String.Encoding.ascii.rawValue)!)
            result.append(": ".data(using: String.Encoding.ascii)!)
            result.append(($1.1 as! NSString).data(using: String.Encoding.ascii.rawValue)!)
            result.append("\r\n".data(using: String.Encoding.ascii)!)
          
            return result
        }
        data.append("\r\n".data(using: String.Encoding.ascii)!)
        return data
    }
}
