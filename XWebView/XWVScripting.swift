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

@objc public protocol XWVScripting : class {
    @objc optional var channelIdentifier: String { get }
    @objc optional func rewriteGeneratedStub(_ stub: String, forKey: String) -> String
    @objc optional func invokeDefaultMethodWithArguments(_ args: [AnyObject]!) -> AnyObject!
    @objc optional func finalizeForScript()

    @objc optional static func scriptNameForKey(_ name: UnsafePointer<Int8>) -> String?
    @objc optional static func scriptNameForSelector(_ selector: Selector) -> String?
    @objc optional static func isSelectorExcludedFromScript(_ selector: Selector) -> Bool
    @objc optional static func isKeyExcludedFromScript(_ name: UnsafePointer<Int8>) -> Bool
}
