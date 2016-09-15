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

import WebKit
import XCTest
import XWebView

class XWebViewTests: XWVTestCase {
    class Plugin : NSObject {
    }

    func testWindowObject() {
        let expectation = self.expectation(description: "testWindowObject")
        loadPlugin(Plugin(), namespace: "xwvtest", script: "") {
            if let math = $0.windowObject["Math"] as? XWVScriptObject,
                let num = try? math.callMethod("sqrt", withArguments: [9]),
                let result = (num as? NSNumber)?.intValue , result == 3 {
                expectation.fulfill()
            } else {
                XCTFail("testWindowObject Failed")
            }
        }
        waitForExpectations(timeout: 2, handler: nil)
    }

    func testLoadPlugin() {
        if webview.loadPlugin(Plugin(), namespace: "xwvtest") == nil {
            XCTFail("testLoadPlugin Failed")
        }
    }

    func testLoadFileURL() {
        _ = expectation(description: "loadFileURL")
        let bundle = Bundle(identifier:"org.xwebview.XWebViewTests")
        if let root = bundle?.bundleURL.appendingPathComponent("www") {
            let url = root.appendingPathComponent("webviewTest.html")
            XCTAssert((url as NSURL).checkResourceIsReachableAndReturnError(nil), "HTML file not found")
            webview.loadFileURL(url, allowingReadAccessTo: root)
            waitForExpectations(timeout: 2, handler: nil)
        }
    }

    func testLoadFileURLWithOverlay() {
        _ = expectation(description: "loadFileURLWithOverlay")
        let bundle = Bundle(identifier:"org.xwebview.XWebViewTests")
        if let root = bundle?.bundleURL.appendingPathComponent("www") {
            // create overlay file in library directory
            let library = try! FileManager.default.url(
                for: FileManager.SearchPathDirectory.libraryDirectory,
                in: FileManager.SearchPathDomainMask.userDomainMask,
                appropriateFor: nil,
                create: true)
            var url = library.appendingPathComponent("webviewTest.html")
            let content = "<html><script type='text/javascript'>fulfill('loadFileURLWithOverlay');</script></html>"
            try! content.write(to: url, atomically: false, encoding: String.Encoding.utf8)

            url = URL(string: "webviewTest.html", relativeTo: root)!
            webview.loadFileURL(url, allowingReadAccessTo: [library])
            waitForExpectations(timeout: 2, handler: nil)
        }
    }

    func testLoadHTMLStringWithBaseURL() {
        _ = expectation(description: "loadHTMLStringWithBaseURL")
        let bundle = Bundle(identifier:"org.xwebview.XWebViewTests")
        if let baseURL = bundle?.bundleURL.appendingPathComponent("www") {
            XCTAssert((baseURL as NSURL).checkResourceIsReachableAndReturnError(nil), "Directory not found")
            webview.loadHTMLString("<html><img id='image' onload='fulfill(\"loadHTMLStringWithBaseURL\")' src='image.png'></html>", baseURL: baseURL)
            waitForExpectations(timeout: 2, handler: nil)
        }
    }
}
