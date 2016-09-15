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

open class XWVInvocation {
    public final let target: AnyObject
    fileprivate let thread: Thread?

    public init(target: AnyObject, thread: Thread? = nil) {
        self.target = target
        self.thread = thread
    }

    open class func construct(_ class: AnyClass, initializer: Selector = #selector(NSObject.init), withArguments arguments: [Any?] = []) -> AnyObject? {
        let alloc = #selector(_SpecialSelectors.alloc)
        guard let obj = invoke(`class`, selector: alloc, withArguments: []) as? AnyObject else {
            return nil
        }
        return invoke(obj, selector: initializer, withArguments: arguments) as? AnyObject
    }

    open func call(_ selector: Selector, withArguments arguments: [Any?] = []) -> Any! {
        return invoke(target, selector: selector, withArguments: arguments, onThread: thread)
    }
    // No callback support, so return value is expected to lose.
    open func asyncCall(_ selector: Selector, withArguments arguments: [Any?] = []) {
        invoke(target, selector: selector, withArguments: arguments, onThread: thread, waitUntilDone: false)
    }

    // Syntactic sugar for calling method
    open subscript (selector: Selector) -> (Any?...) -> Any! {
        return { (args: Any?...) -> Any! in
            self.call(selector, withArguments: args)
        }
    }
}

extension XWVInvocation {

    // Property accessor
    public func getProperty(_ name: String) -> Any! {
        let getter = getterOfName(name)
        //assert(getter != Selector(), "Property '\(name)' does not exist")
        return getter != Selector() ? call(getter) : Void()
    }
  
    public func setValue(_ value: Any!, forProperty name: String) {
        let setter = setterOfName(name)
        assert(setter != Selector(), "Property '\(name)' " +
                (getterOfName(name) == nil ? "does not exist" : "is readonly"))
        assert(!(value is Void))
        if setter != Selector() {
            call(setter, withArguments: [value])
        }
    }

    // Syntactic sugar for accessing property
    public subscript (name: String) -> Any! {
        get {
            return getProperty(name)
        }
        set {
            setValue(newValue, forProperty: name)
        }
    }

    fileprivate func getterOfName(_ name: String) -> Selector {
        var getter = Selector()
        let property = class_getProperty(target.dynamicType, name)
        if property != nil {
            let attr = property_copyAttributeValue(property, "G")
            getter = Selector(attr == nil ? name : String(validatingUTF8: attr)!)
            free(attr)
        }
        return getter
    }
    fileprivate func setterOfName(_ name: String) -> Selector {
        var setter = Selector()
        let property = class_getProperty(target.dynamicType, name)
        if property != nil {
            var attr = property_copyAttributeValue(property, "R")
            if attr == nil {
                attr = property_copyAttributeValue(property, "S")
                if attr == nil {
                    setter = Selector("set\(String(name.characters.first!).uppercased())\(String(name.characters.dropFirst())):")
                } else {
                    setter = Selector(String(validatingUTF8: attr)!)
                }
            }
            free(attr)
        }
        return setter
    }
}


// Notice: The target method must strictly obey the Cocoa convention.
// Do NOT call method with explicit family control or parameter attribute of ARC.
// See: http://clang.llvm.org/docs/AutomaticReferenceCounting.html
private let _NSInvocation: AnyClass = NSClassFromString("NSInvocation")!
private let _NSMethodSignature: AnyClass = NSClassFromString("NSMethodSignature")!
public func invoke(_ target: AnyObject, selector: Selector, withArguments arguments: [Any!], onThread thread: Thread? = nil, waitUntilDone wait: Bool = true) -> Any! {
    let method = class_getInstanceMethod(target.dynamicType, selector)
    if method == nil {
        // TODO: supports forwordingTargetForSelector: of NSObject?
        (target as? NSObject)?.doesNotRecognizeSelector(selector)
        // Not an NSObject, mimic the behavior of NSObject
        let reason = "-[\(target.dynamicType) \(selector)]: unrecognized selector sent to instance \(Unmanaged.passUnretained(target).toOpaque())"
        withVaList([reason]) { NSLogv("%@", $0) }
        NSException(name: NSExceptionName.invalidArgumentException, reason: reason, userInfo: nil).raise()
    }

    let sig = (_NSMethodSignature as! _NSMethodSignatureFactory).signature(withObjCTypes: method_getTypeEncoding(method))
    let inv = (_NSInvocation as! _NSInvocationFactory).invocation(with: sig)

    // Setup arguments
    precondition(arguments.count + 2 <= Int(method_getNumberOfArguments(method)),
                 "Too many arguments for calling -[\(target.dynamicType) \(selector)]")
    var args = [[Int]](repeating: [], count: arguments.count)
    for i in 0 ..< arguments.count {
        let type = sig.getArgumentTypeAtIndex(i + 2)
        let typeChar = Character(UnicodeScalar(UInt8(type[0])))

        // Convert argument type to adapte requirement of method.
        // Firstly, convert argument to appropriate object type.
        var argument: Any! = castToObjectFromAny(arguments[i])
        assert(argument != nil || arguments[i] == nil, "Can't convert '\(arguments[i].dynamicType)' to object type")
        if typeChar != "@", let obj: AnyObject = argument as? AnyObject {
            // Convert back to scalar type as method requires.
            argument = castToAnyFromObject(obj, withObjCType: type)
        }

        if typeChar == "f", let float = argument as? Float {
            // Float type shouldn't be promoted to double if it is not variadic.
            args[i] = [ Int(unsafeBitCast(float, to: Int32.self)) ]
        } else if let val = argument as? CVarArg {
            // Scalar(except float), pointer and Objective-C object types
            args[i] = val._cVarArgEncoding
        } else if let obj: AnyObject = argument as? AnyObject {
            // Pure swift object type
            args[i] = [ unsafeBitCast(Unmanaged.passUnretained(obj).toOpaque(), to: Int.self) ]
        } else {
            // Nil or unsupported type
            assert(argument == nil, "Unsupported argument type '\(String(validatingUTF8: type))'")
            var align: Int = 0
            NSGetSizeAndAlignment(type, nil, &align)
            args[i] = [Int](repeating: 0, count: align / sizeof(Int))
        }
        args[i].withUnsafeBufferPointer {
            inv.setArgument(UnsafeMutablePointer($0.baseAddress), atIndex: i + 2)
        }
    }

    if selector.family == .init_ {
        // Self should be consumed for method belongs to init famlily
        _ = Unmanaged.passRetained(target)
    }
    inv.selector = selector

    if thread == nil || (thread == Thread.current && wait) {
        inv.invokeWithTarget(target)
    } else {
        let selector = #selector(_SpecialSelectors.invoke(withTarget:)(_:))
        inv.retainArguments()
        inv.perform(selector, on: thread!, with: target, waitUntilDone: wait)
        guard wait else { return Void() }
    }
    if sig.methodReturnLength == 0 { return Void() }

    // Fetch the return value
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: sig.methodReturnLength)
    inv.getReturnValue(buffer)
    defer {
        if sig.methodReturnType[0] == 0x40 && selector.returnsRetained {
            // To balance the retained return value
            Unmanaged.passUnretained(UnsafePointer<AnyObject>(buffer).pointee).release()
        }
        buffer.deallocateCapacity(sig.methodReturnLength)
    }
    return castToAnyFromBytes(buffer, withObjCType: sig.methodReturnType)
}


// Convert byte array to specified Objective-C type
// See: https://developer.apple.com/library/mac/documentation/Cocoa/Conceptual/ObjCRuntimeGuide/Articles/ocrtTypeEncodings.html
private func castToAnyFromBytes(_ bytes: UnsafeRawPointer, withObjCType type: UnsafePointer<Int8>) -> Any! {
    switch Character(UnicodeScalar(UInt8(type[0]))) {
    case "c": return UnsafePointer<CChar>(bytes).pointee
    case "i": return UnsafePointer<CInt>(bytes).pointee
    case "s": return UnsafePointer<CShort>(bytes).pointee
    case "l": return UnsafePointer<Int32>(bytes).pointee
    case "q": return UnsafePointer<CLongLong>(bytes).pointee
    case "C": return UnsafePointer<CUnsignedChar>(bytes).pointee
    case "I": return UnsafePointer<CUnsignedInt>(bytes).pointee
    case "S": return UnsafePointer<CUnsignedShort>(bytes).pointee
    case "L": return UnsafePointer<UInt32>(bytes).pointee
    case "Q": return UnsafePointer<CUnsignedLongLong>(bytes).pointee
    case "f": return UnsafePointer<CFloat>(bytes).pointee
    case "d": return UnsafePointer<CDouble>(bytes).pointee
    case "B": return UnsafePointer<CBool>(bytes).pointee
    case "v": assertionFailure("Why cast to Void type?")
    case "*": return UnsafePointer<CChar>(bytes)
    case "@": return UnsafePointer<AnyObject!>(bytes).pointee
    case "#": return UnsafePointer<AnyClass!>(bytes).pointee
    case ":": return UnsafePointer<Selector>(bytes).pointee
    case "^": return UnsafePointer<OpaquePointer>(bytes).pointee
    default:  assertionFailure("Unknown Objective-C type encoding '\(String(validatingUTF8: type))'")
    }
    return Void()
}

// Convert AnyObject to specified Objective-C type
private func castToAnyFromObject(_ object: AnyObject, withObjCType type: UnsafePointer<Int8>) -> Any! {
    let num = object as? NSNumber
    switch Character(UnicodeScalar(UInt8(type[0]))) {
    case "c": return num?.int8Value
    case "i": return num?.int32Value
    case "s": return num?.int16Value
    case "l": return num?.int32Value
    case "q": return num?.int64Value
    case "C": return num?.uint8Value
    case "I": return num?.uint32Value
    case "S": return num?.uint16Value
    case "L": return num?.uint32Value
    case "Q": return num?.uint64Value
    case "f": return num?.floatValue
    case "d": return num?.doubleValue
    case "B": return num?.boolValue
    case "v": return Void()
    case "*": return (object as? String)?.nulTerminatedUTF8.withUnsafeBufferPointer{ OpaquePointer($0.baseAddress) }
    case ":": return object is String ? Selector(object as! String) : Selector()
    case "@": return object
    case "#": return object as? AnyClass
    case "^": return (object as? NSValue)?.pointerValue
    default:  assertionFailure("Unknown Objective-C type encoding '\(String(validatingUTF8: type))'")
    }
    return nil
}

// Convert Any value to appropriate Objective-C object
public func castToObjectFromAny(_ value: Any!) -> AnyObject! {
    if value == nil || value is AnyObject {
        // Some scalar types (Int, UInt, Bool, Float and Double) can be converted automatically by runtime.
        return value as? AnyObject
    }

    switch value {
    case let v as Int8:           return NSNumber(value: v as Int8)
    case let v as Int16:          return NSNumber(value: v as Int16)
    case let v as Int32:          return NSNumber(value: v as Int32)
    case let v as Int64:          return NSNumber(value: v as Int64)
    case let v as UInt8:          return NSNumber(value: v as UInt8)
    case let v as UInt16:         return NSNumber(value: v as UInt16)
    case let v as UInt32:         return NSNumber(value: v as UInt32)
    case let v as UInt64:         return NSNumber(value: v as UInt64)
    case let v as UnicodeScalar:  return NSNumber(value: v.value as UInt32)
    case let s as Selector:       return String(s)
    case let p as OpaquePointer: return NSValue(pointer: UnsafeRawPointer(p))
    default:
        assert(value is Void, "Can't convert '\(value.dynamicType)' to AnyObject")
    }
    return nil
}

// Additional Swift types which can be represented in C type.
extension Bool: CVarArg {
    public var _cVarArgEncoding: [Int] {
        return [ Int(self) ]
    }
}
extension UnicodeScalar: CVarArg {
    public var _cVarArgEncoding: [Int] {
        return [ Int(self.value) ]
    }
}
extension Selector: CVarArg {
    public var _cVarArgEncoding: [Int] {
        return [ unsafeBitCast(self, to: Int.self) ]
    }
}

private extension Selector {
    enum Family : Int8 {
        case none        = 0
        case alloc       = 97
        case copy        = 99
        case mutableCopy = 109
        case init_       = 105
        case new         = 110
    }
    static var prefixes : [[CChar]] = [
        /* alloc */       [97, 108, 108, 111, 99],
        /* copy */        [99, 111, 112, 121],
        /* mutableCopy */ [109, 117, 116, 97, 98, 108, 101, 67, 111, 112, 121],
        /* init */        [105, 110, 105, 116],
        /* new */         [110, 101, 119]
    ]
    var family: Family {
        // See: http://clang.llvm.org/docs/AutomaticReferenceCounting.html#id34
        var s = unsafeBitCast(self, to: UnsafePointer<Int8>.self)
        while s.pointee == 0x5f { s += 1 }  // skip underscore
        for p in Selector.prefixes {
            let lowercase: CountableRange<CChar> = 97...122
            let l = p.count
            if strncmp(s, p, l) == 0 && !lowercase.contains(s.advancedBy(l).pointee) {
                return Family(rawValue: s.pointee)!
            }
        }
        return .none
    }
    var returnsRetained: Bool {
        return family != .none
    }
}
