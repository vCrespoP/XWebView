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
import ObjectiveC

class XWVMetaObject: Collection {
  
    enum Member {
        case method(selector: Selector, arity: Int32)
        case property(getter: Selector, setter: Selector)
        case initializer(selector: Selector, arity: Int32)

        var isMethod: Bool {
            if case .method = self { return true }
            return false
        }
        var isProperty: Bool {
            if case .property = self { return true }
            return false
        }
        var isInitializer: Bool {
            if case .initializer = self { return true }
            return false
        }
        var selector: Selector? {
            switch self {
            case let .method(selector, _):
//                assert(selector != Selector())
                return selector
            case let .initializer(selector, _):
//                assert(selector != Selector())
                return selector
            default:
                return nil
            }
        }
        var getter: Selector? {
            if case .property(let getter, _) = self {
//                assert(getter != Selector())
                return getter
            }
            return nil
        }
        var setter: Selector? {
            if case .property(let getter, let setter) = self {
//                assert(getter != Selector())
                return setter
            }
            return nil
        }
        var type: String {
            let promise: Bool
            let arity: Int32
            switch self {
            case let .method(selector, a):
                promise = selector.description.hasSuffix(":promiseObject:") ||
                          selector.description.hasSuffix("PromiseObject:")
                arity = a
            case let .initializer(_, a):
                promise = true
                arity = a < 0 ? a: a + 1
            default:
                promise = false
                arity = -1
            }
            if !promise && arity < 0 {
                return ""
            }
            return "#" + (arity >= 0 ? "\(arity)" : "") + (promise ? "p" : "a")
        }
    }

    let plugin: AnyClass
    fileprivate var members = [String: Member]()
    fileprivate static let exclusion: Set<Selector> = {
        var methods = instanceMethods(forProtocol: XWVScripting.self)
        methods.remove(#selector(XWVScripting.invokeDefaultMethodWithArguments(_:)))
        return methods.union([
            #selector(_SpecialSelectors.dealloc),
            #selector(NSObject.copy as! ()->AnyObject)
        ])
    }()

    init(plugin: AnyClass) {
        self.plugin = plugin
        enumerateExcluding(type(of: self).exclusion) {
            (name, member) -> Bool in
            var name = name
            var member = member
            switch member {
            case let .method(selector, _):
                if let cls = plugin as? XWVScripting.Type {
                    if cls.isSelectorExcludedFromScript?(selector) ?? false {
                        return true
                    }
                    if selector == #selector(XWVScripting.invokeDefaultMethodWithArguments(_:)) {
                        member = .method(selector: selector, arity: -1)
                        name = ""
                    } else {
                        name = cls.scriptNameForSelector?(selector) ?? name
                    }
                } else if name.characters.first == "_" {
                    return true
                }

            case .property(_, _):
                if let cls = plugin as? XWVScripting.Type {
                    if let isExcluded = cls.isKeyExcludedFromScript , name.withCString(isExcluded) {
                        return true
                    }
                    if let scriptNameForKey = cls.scriptNameForKey {
                        name = name.withCString(scriptNameForKey) ?? name
                    }
                } else if name.characters.first == "_" {
                    return true
                }

            case let .initializer(selector, _):
                if selector == #selector(_InitSelector.init(byScriptWithArguments:)) {
                    member = .initializer(selector: selector, arity: -1)
                    name = ""
                } else if let cls = plugin as? XWVScripting.Type {
                    name = cls.scriptNameForSelector?(selector) ?? name
                }
                if !name.isEmpty {
                    return true
                }
            }
            assert(members.index(forKey: name) == nil, "Plugin class \(plugin) has a conflict in member name '\(name)'")
            members[name] = member
            return true
        }
    }

    fileprivate func enumerateExcluding(_ selectors: Set<Selector>, callback: ((String, Member)->Bool)) -> Bool {
        var known = selectors

        // enumerate properties
        let propertyList = class_copyPropertyList(plugin, nil)
        if propertyList != nil, var prop = Optional(propertyList) {
            defer { free(propertyList) }
            while prop?.pointee != nil {
                let name = String(validatingUTF8: property_getName(prop?.pointee))!
                // get getter
                var attr = property_copyAttributeValue(prop?.pointee, "G")
                let getter = Selector(attr == nil ? name : String(validatingUTF8: attr!)!)
                free(attr)
                if known.contains(getter) {
                    prop = prop?.successor()
                    continue
                }
                known.insert(getter)

                // get setter if readwrite
                var setter = #selector() // Selector()
                attr = property_copyAttributeValue(prop?.pointee, "R")
                if attr == nil {
                    attr = property_copyAttributeValue(prop?.pointee, "S")
                    if attr == nil {
                        setter = Selector("set\(String(name.characters.first!).uppercased())\(String(name.characters.dropFirst())):")
                    } else {
                        setter = Selector(String(validatingUTF8: attr)!)
                    }
                    if known.contains(setter) {
                        setter = Selector()
                    } else {
                        known.insert(setter)
                    }
                }
                free(attr)

                let info = Member.property(getter: getter, setter: setter)
                if !callback(name, info) {
                    return false
                }
                prop = prop?.successor()
            }
        }

        // enumerate methods
        let methodList = class_copyMethodList(plugin, nil)
        if methodList != nil, var method = Optional(methodList) {
            defer { free(methodList) }
            while method?.pointee != nil {
                let sel = method_getName(method?.pointee)
                if !known.contains(sel!) && !(sel?.description.hasPrefix("."))! {
                    let arity = Int32(method_getNumberOfArguments(method?.pointee) - 2)
                    let member: Member
                    if (sel?.description.hasPrefix("init"))! {
                        member = Member.initializer(selector: sel, arity: arity)
                    } else {
                        member = Member.method(selector: sel, arity: arity)
                    }
                    var name = sel?.description
                    if let end = name?.characters.index(of: ":") {
                        name = name?[(name?.startIndex)! ..< end]
                    }
                    if !callback(name!, member) {
                        return false
                    }
                }
                method = method?.successor()
            }
        }
        return true
    }
}

extension XWVMetaObject {
    // SequenceType
    typealias Iterator = DictionaryGenerator<String, Member>
    func makeIterator() -> Iterator {
        return members.makeIterator()
    }

    // CollectionType
    typealias Index = DictionaryIndex<String, Member>
    var startIndex: Index {
        return members.startIndex
    }
    var endIndex: Index {
        return members.endIndex
    }
    subscript (position: Index) -> (String, Member) {
        return members[position]
    }
    subscript (name: String) -> Member? {
        return members[name]
    }
}

private func instanceMethods(forProtocol aProtocol: Protocol) -> Set<Selector> {
    var selectors = Set<Selector>()
    for (req, inst) in [(true, true), (false, true)] {
        let methodList = protocol_copyMethodDescriptionList(aProtocol.self, req, inst, nil)
        if methodList != nil, var desc = Optional(methodList) {
            while desc?.pointee.name != nil {
                selectors.insert((desc?.pointee.name)!)
                desc = desc?.successor()
            }
            free(methodList)
        }
    }
    return selectors
}
