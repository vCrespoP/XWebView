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
import WebKit

open class XWVChannel : NSObject, WKScriptMessageHandler {
    fileprivate(set) open var identifier: String?
    open let runLoop: RunLoop?
    open let queue: DispatchQueue?
    fileprivate(set) open weak var webView: WKWebView?
    var typeInfo: XWVMetaObject!

    fileprivate var instances = [Int: XWVBindingObject]()
    fileprivate var userScript: XWVUserScript?
    fileprivate(set) var principal: XWVBindingObject {
        get { return instances[0]! }
        set { instances[0] = newValue }
    }

    fileprivate class var sequenceNumber: UInt {
        struct sequence{
            static var number: UInt = 0
        }
        sequence.number += 1
        return sequence.number
    }

    fileprivate static var defaultQueue: DispatchQueue = {
        let label = "org.xwebview.default-queue"
        return DispatchQueue(label: label, attributes: [])
    }()

    public convenience init(webView: WKWebView) {
        self.init(webView: webView, queue: XWVChannel.defaultQueue)
    }
    public convenience init(webView: WKWebView, thread: Thread) {
        let selector = #selector(RunLoop.currentRunLoop)
        let runLoop = invoke(RunLoop.self, selector: selector, withArguments: [], onThread: thread) as! RunLoop
        self.init(webView: webView, runLoop: runLoop)
    }

    public init(webView: WKWebView, queue: DispatchQueue) {
        assert(queue.label.pointee != 0, "Queue must be labeled")
        self.webView = webView
        self.queue = queue
        runLoop = nil
        webView.prepareForPlugin()
    }

    public init(webView: WKWebView, runLoop: RunLoop) {
        self.webView = webView
        self.runLoop = runLoop
        queue = nil
        webView.prepareForPlugin()
    }

    open func bindPlugin(_ object: AnyObject, toNamespace namespace: String) -> XWVScriptObject? {
        guard identifier == nil, let webView = webView else { return nil }

        let id = (object as? XWVScripting)?.channelIdentifier ?? String(XWVChannel.sequenceNumber)
        identifier = id
        webView.configuration.userContentController.add(self, name: id)
        typeInfo = XWVMetaObject(plugin: object.dynamicType)
        principal = XWVBindingObject(namespace: namespace, channel: self, object: object)

        let script = WKUserScript(source: generateStubs(),
                                  injectionTime: WKUserScriptInjectionTime.atDocumentStart,
                                  forMainFrameOnly: true)
        userScript = XWVUserScript(webView: webView, script: script)

        log("+Plugin object \(object) is bound to \(namespace) with channel \(id)")
        return principal as XWVScriptObject
    }

    open func unbind() {
        guard let id = identifier else { return }
        let namespace = principal.namespace
        let plugin = principal.plugin
        instances.removeAll(keepCapacity: false)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: id)
        userScript = nil
        identifier = nil
        log("+Plugin object \(plugin) is unbound from \(namespace)")
    }

    open func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // A workaround for crash when postMessage(undefined)
        guard unsafeBitCast(message.body, to: OpaquePointer.self) != nil else { return }

        if let body = message.body as? [String: AnyObject], let opcode = body["$opcode"] as? String {
            let target = (body["$target"] as? NSNumber)?.intValue ?? 0
            if let object = instances[target] {
                if opcode == "-" {
                    if target == 0 {
                        // Dispose plugin
                        unbind()
                    } else if let instance = instances.removeValue(forKey: target) {
                        // Dispose instance
                        log("+Instance \(target) is unbound from \(instance.namespace)")
                    } else {
                        log("?Invalid instance id: \(target)")
                    }
                } else if let member = typeInfo[opcode] where member.isProperty {
                    // Update property
                    object.updateNativeProperty(opcode, withValue: body["$operand"] ?? NSNull())
                } else if let member = typeInfo[opcode] where member.isMethod {
                    // Invoke method
                    if let args = (body["$operand"] ?? []) as? [AnyObject] {
                        object.invokeNativeMethod(opcode, withArguments: args)
                    } // else malformatted operand
                } else {
                    log("?Invalid member name: \(opcode)")
                }
            } else if opcode == "+" {
                // Create instance
                let args = body["$operand"] as? [AnyObject]
                let namespace = "\(principal.namespace)[\(target)]"
                instances[target] = XWVBindingObject(namespace: namespace, channel: self, arguments: args)
                log("+Instance \(target) is bound to \(namespace)")
            } // else Unknown opcode
        } else if let obj = principal.plugin as? WKScriptMessageHandler {
            // Plugin claims for raw messages
            obj.userContentController(userContentController, didReceive: message)
        } else {
            // discard unknown message
            log("-Unknown message: \(message.body)")
        }
    }

    fileprivate func generateStubs() -> String {
        func generateMethod(_ key: String, this: String, prebind: Bool) -> String {
            let stub = "XWVPlugin.invokeNative.bind(\(this), '\(key)')"
            return prebind ? "\(stub);" : "function(){return \(stub).apply(null, arguments);}"
        }
        func rewriteStub(_ stub: String, forKey key: String) -> String {
            return (principal.plugin as? XWVScripting)?.rewriteGeneratedStub?(stub, forKey: key) ?? stub
        }

        let prebind = !(typeInfo[""]?.isInitializer ?? false)
        let stubs = typeInfo.reduce("") {
            let key = $1.0
            let member = $1.1
            let stub: String
            if member.isMethod && !key.isEmpty {
                let method = generateMethod("\(key)\(member.type)", this: prebind ? "exports" : "this", prebind: prebind)
                stub = "exports.\(key) = \(method)"
            } else if member.isProperty {
                let value = principal.serialize(principal[key])
                stub = "XWVPlugin.defineProperty(exports, '\(key)', \(value), \(member.setter != nil));"
            } else {
                return $0
            }
            return $0 + rewriteStub(stub, forKey: key) + "\n"
        }

        let base: String
        if let member = typeInfo[""] {
            if member.isInitializer {
                base = "'\(member.type)'"
            } else {
                base = generateMethod("\(member.type)", this: "arguments.callee", prebind: false)
            }
        } else {
            base = rewriteStub("null", forKey: ".base")
        }

        return rewriteStub(
            "(function(exports) {\n" +
                rewriteStub(stubs, forKey: ".local") +
            "})(XWVPlugin.createPlugin('\(identifier!)', '\(principal.namespace)', \(base)));\n",
            forKey: ".global"
        )
    }
}
