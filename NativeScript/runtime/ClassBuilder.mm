#include <Foundation/Foundation.h>
#include <numeric>
#include <sstream>
#include "ClassBuilder.h"
#include "TNSDerivedClass.h"
#include "NativeScriptException.h"
#include "FastEnumerationAdapter.h"
#include "ArgConverter.h"
#include "ObjectManager.h"
#include "Helpers.h"
#include "Caches.h"
#include "Interop.h"
#include "Runtime.h"

using namespace v8;

namespace tns {

Local<FunctionTemplate> ClassBuilder::GetExtendFunction(Isolate* isolate, const InterfaceMeta* interfaceMeta) {
    CacheItem* item = new CacheItem(interfaceMeta, nullptr);
    Local<External> ext = External::New(isolate, item);
    return FunctionTemplate::New(isolate, ClassBuilder::ExtendCallback, ext);
}

void ClassBuilder::ExtendCallback(const FunctionCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();

    tns::Assert(info.Length() > 0 && info[0]->IsObject() && info.This()->IsFunction(), isolate);

    try {
        Local<Context> context = isolate->GetCurrentContext();
        CacheItem* item = static_cast<CacheItem*>(info.Data().As<External>()->Value());

        Local<Object> implementationObject = info[0].As<Object>();
        Local<v8::Function> baseFunc = info.This().As<v8::Function>();
        std::string baseClassName = tns::ToString(isolate, baseFunc->GetName());

        BaseDataWrapper* baseWrapper = tns::GetValue(isolate, baseFunc);
        if (baseWrapper != nullptr && baseWrapper->Type() == WrapperType::ObjCClass) {
            ObjCClassWrapper* classWrapper = static_cast<ObjCClassWrapper*>(baseWrapper);
            if (classWrapper->ExtendedClass()) {
                throw NativeScriptException("Cannot extend an already extended class");
            }
        }

        Local<Object> nativeSignature;
        std::string staticClassName;
        if (info.Length() > 1 && info[1]->IsObject()) {
            nativeSignature = info[1].As<Object>();
            Local<Value> explicitClassName;
            tns::Assert(nativeSignature->Get(context, tns::ToV8String(isolate, "name")).ToLocal(&explicitClassName), isolate);
            if (!explicitClassName.IsEmpty() && !explicitClassName->IsNullOrUndefined()) {
                staticClassName = tns::ToString(isolate, explicitClassName);
            }
        }

        Class extendedClass = ClassBuilder::GetExtendedClass(baseClassName, staticClassName);
        class_addProtocol(extendedClass, @protocol(TNSDerivedClass));
        class_addProtocol(object_getClass(extendedClass), @protocol(TNSDerivedClass));

        if (!nativeSignature.IsEmpty()) {
            ClassBuilder::ExposeDynamicMembers(context, extendedClass, implementationObject, nativeSignature);
        } else {
            ClassBuilder::ExposeDynamicMethods(context, extendedClass, Local<Value>(), Local<Value>(), implementationObject);
        }

        auto cache = Caches::Get(isolate);
        Local<v8::Function> baseCtorFunc = cache->CtorFuncs.find(item->meta_->name())->second->Get(isolate);

        CacheItem* cacheItem = new CacheItem(nullptr, extendedClass);
        Local<External> ext = External::New(isolate, cacheItem);
        Local<FunctionTemplate> extendedClassCtorFuncTemplate = FunctionTemplate::New(isolate, ExtendedClassConstructorCallback, ext);
        extendedClassCtorFuncTemplate->InstanceTemplate()->SetInternalFieldCount(1);

        Local<v8::Function> extendClassCtorFunc;
        if (!extendedClassCtorFuncTemplate->GetFunction(context).ToLocal(&extendClassCtorFunc)) {
            tns::Assert(false, isolate);
        }

        Local<Value> baseProto;
        bool success = baseCtorFunc->Get(context, tns::ToV8String(isolate, "prototype")).ToLocal(&baseProto);
        tns::Assert(success, isolate);

        if (!implementationObject->SetPrototype(context, baseProto).To(&success) || !success) {
            tns::Assert(false, isolate);
        }
        if (!implementationObject->SetAccessor(context, tns::ToV8String(isolate, "super"), SuperAccessorGetterCallback, nullptr, ext).To(&success) || !success) {
            tns::Assert(false, isolate);
        }

        extendClassCtorFunc->SetName(tns::ToV8String(isolate, class_getName(extendedClass)));
        Local<Value> extendFuncPrototypeValue;
        success = extendClassCtorFunc->Get(context, tns::ToV8String(isolate, "prototype")).ToLocal(&extendFuncPrototypeValue);
        tns::Assert(success && extendFuncPrototypeValue->IsObject(), isolate);
        Local<Object> extendFuncPrototype = extendFuncPrototypeValue.As<Object>();
        if (!extendFuncPrototype->SetPrototype(context, implementationObject).To(&success) || !success) {
            tns::Assert(false, isolate);
        }

        if (!extendClassCtorFunc->SetPrototype(context, baseCtorFunc).To(&success) || !success) {
            tns::Assert(false, isolate);
        }

        std::string extendedClassName = class_getName(extendedClass);
        ObjCClassWrapper* wrapper = new ObjCClassWrapper(extendedClass, true);
        tns::SetValue(isolate, extendClassCtorFunc, wrapper);

        cache->CtorFuncs.emplace(extendedClassName, std::make_unique<Persistent<v8::Function>>(isolate, extendClassCtorFunc));
        cache->ClassPrototypes.emplace(extendedClassName, std::make_unique<Persistent<Object>>(isolate, extendFuncPrototype));

        info.GetReturnValue().Set(extendClassCtorFunc);
    } catch (NativeScriptException& ex) {
        ex.ReThrowToV8(isolate);
    }
}

void ClassBuilder::ExtendedClassConstructorCallback(const FunctionCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    Local<Context> context = isolate->GetCurrentContext();

    try {
        CacheItem* item = static_cast<CacheItem*>(info.Data().As<External>()->Value());
        Class klass = item->data_;

        ArgConverter::ConstructObject(context, info, klass);
    } catch (NativeScriptException& ex) {
        ex.ReThrowToV8(isolate);
    }
}

void ClassBuilder::RegisterBaseTypeScriptExtendsFunction(Local<Context> context) {
    Isolate* isolate = context->GetIsolate();
    auto cache = Caches::Get(isolate);
    if (cache->OriginalExtendsFunc.get() != nullptr) {
        return;
    }

    std::string extendsFuncScript =
        "(function() { "
        "    function __extends(d, b) { "
        "         for (var p in b) {"
        "             if (b.hasOwnProperty(p)) {"
        "                 d[p] = b[p];"
        "             }"
        "         }"
        "         function __() { this.constructor = d; }"
        "         d.prototype = b === null ? Object.create(b) : (__.prototype = b.prototype, new __());"
        "    } "
        "    return __extends;"
        "})()";

    Local<Script> script;
    tns::Assert(Script::Compile(context, tns::ToV8String(isolate, extendsFuncScript.c_str())).ToLocal(&script), isolate);

    Local<Value> extendsFunc;
    tns::Assert(script->Run(context).ToLocal(&extendsFunc) && extendsFunc->IsFunction(), isolate);

    cache->OriginalExtendsFunc = std::make_unique<Persistent<v8::Function>>(isolate, extendsFunc.As<v8::Function>());
}

void ClassBuilder::RegisterNativeTypeScriptExtendsFunction(Local<Context> context) {
    Isolate* isolate = context->GetIsolate();
    Local<Object> global = context->Global();

    Local<v8::Function> extendsFunc = v8::Function::New(context, [](const FunctionCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        tns::Assert(info.Length() == 2, isolate);
        Local<Context> context = isolate->GetCurrentContext();

        auto cache = Caches::Get(isolate);
        BaseDataWrapper* wrapper = tns::GetValue(isolate, info[1].As<Object>());
        if (!wrapper) {
            // We are not extending a native object -> call the base __extends function
            Persistent<v8::Function>* poExtendsFunc = cache->OriginalExtendsFunc.get();
            tns::Assert(poExtendsFunc != nullptr, isolate);
            Local<v8::Function> originalExtendsFunc = poExtendsFunc->Get(isolate);
            Local<Value> args[] = { info[0], info[1] };
            originalExtendsFunc->Call(context, context->Global(), info.Length(), args).ToLocalChecked();
            return;
        }

        ObjCClassWrapper* classWrapper = static_cast<ObjCClassWrapper*>(wrapper);
        Class baseClass = classWrapper->Klass();
        std::string baseClassName = class_getName(baseClass);

        Local<v8::Function> extendedClassCtorFunc = info[0].As<v8::Function>();
        std::string extendedClassName = tns::ToString(isolate, extendedClassCtorFunc->GetName());

        __block Class extendedClass = ClassBuilder::GetExtendedClass(baseClassName, extendedClassName);
        class_addProtocol(extendedClass, @protocol(TNSDerivedClass));
        class_addProtocol(object_getClass(extendedClass), @protocol(TNSDerivedClass));

        extendedClassName = class_getName(extendedClass);

        tns::SetValue(isolate, extendedClassCtorFunc, new ObjCClassWrapper(extendedClass, true));

        const Meta* baseMeta = ArgConverter::FindMeta(baseClass);
        const InterfaceMeta* interfaceMeta = static_cast<const InterfaceMeta*>(baseMeta);
        Local<v8::Function> baseCtorFunc = cache->CtorFuncs.find(interfaceMeta->name())->second->Get(isolate);

        tns::Assert(extendedClassCtorFunc->SetPrototype(context, baseCtorFunc).ToChecked(), isolate);

        Local<v8::String> prototypeProp = tns::ToV8String(isolate, "prototype");

        Local<Value> extendedClassCtorFuncPrototypeValue;
        bool success = extendedClassCtorFunc->Get(context, prototypeProp).ToLocal(&extendedClassCtorFuncPrototypeValue);
        tns::Assert(success && extendedClassCtorFuncPrototypeValue->IsObject(), isolate);
        Local<Object> extendedClassCtorFuncPrototype = extendedClassCtorFuncPrototypeValue.As<Object>();

        Local<Value> prototypePropValue;
        success = baseCtorFunc->Get(context, prototypeProp).ToLocal(&prototypePropValue);
        tns::Assert(success && prototypePropValue->IsObject(), isolate);

        success = extendedClassCtorFuncPrototype->SetPrototype(context, prototypePropValue.As<Object>()).FromMaybe(false);
        tns::Assert(success, isolate);

        cache->ClassPrototypes.emplace(extendedClassName, std::make_unique<Persistent<Object>>(isolate, extendedClassCtorFuncPrototype));

        Persistent<v8::Function>* poExtendedClassCtorFunc = new Persistent<v8::Function>(isolate, extendedClassCtorFunc);

        cache->CtorFuncs.emplace(extendedClassName, poExtendedClassCtorFunc);

        IMP newInitialize = imp_implementationWithBlock(^(id self) {
            v8::Locker locker(isolate);
            Isolate::Scope isolate_scope(isolate);
            HandleScope handle_scope(isolate);
            Local<Context> context = Caches::Get(isolate)->GetContext();
            Local<v8::Function> extendedClassCtorFunc = poExtendedClassCtorFunc->Get(isolate);

            Local<Value> exposedMethods;
            bool success = extendedClassCtorFunc->Get(context, tns::ToV8String(isolate, "ObjCExposedMethods")).ToLocal(&exposedMethods);
            tns::Assert(success, isolate);

            Local<Value> implementationObject;
            success = extendedClassCtorFunc->Get(context, tns::ToV8String(isolate, "prototype")).ToLocal(&implementationObject);
            tns::Assert(success, isolate);

            if (implementationObject.IsEmpty() || exposedMethods.IsEmpty()) {
                return;
            }

            Local<Value> exposedProtocols;
            success = extendedClassCtorFunc->Get(context, tns::ToV8String(isolate, "ObjCProtocols")).ToLocal(&exposedProtocols);
            tns::Assert(success, isolate);

            ClassBuilder::ExposeDynamicMethods(context, extendedClass, exposedMethods, exposedProtocols, implementationObject.As<Object>());
        });
        class_addMethod(object_getClass(extendedClass), @selector(initialize), newInitialize, "v@:");

        /// We swizzle the retain and release methods for the following reason:
        /// When we instantiate a native class via a JavaScript call we add it to the object instances map thus
        /// incrementing the retainCount by 1. Then, when the native object is referenced somewhere else its count will become more than 1.
        /// Since we want to keep the corresponding JavaScript object alive even if it is not used anywhere, we call GcProtect on it.
        /// Whenever the native object is released so that its retainCount is 1 (the object instances map), we unprotect the corresponding JavaScript object
        /// in order to make both of them destroyable/GC-able. When the JavaScript object is GC-ed we release the native counterpart as well.
        void (*retain)(id, SEL) = (void (*)(id, SEL))FindNotOverridenMethod(extendedClass, @selector(retain));
        IMP newRetain = imp_implementationWithBlock(^(id self) {
            if ([self retainCount] == 1) {
                auto it = cache->Instances.find(self);
                if (it != cache->Instances.end()) {
                    v8::Locker locker(isolate);
                    Isolate::Scope isolate_scope(isolate);
                    HandleScope handle_scope(isolate);
                    Local<Value> value = it->second->Get(isolate);
                    BaseDataWrapper* wrapper = tns::GetValue(isolate, value);
                    if (wrapper != nullptr && wrapper->Type() == WrapperType::ObjCObject) {
                        ObjCDataWrapper* objcWrapper = static_cast<ObjCDataWrapper*>(wrapper);
                        objcWrapper->GcProtect();
                    }
                }
            }

            return retain(self, @selector(retain));
        });
        class_addMethod(extendedClass, @selector(retain), newRetain, "@@:");

        void (*release)(id, SEL) = (void (*)(id, SEL))FindNotOverridenMethod(extendedClass, @selector(release));
        IMP newRelease = imp_implementationWithBlock(^(id self) {
            if (!Runtime::IsAlive(isolate)) {
                return;
            }

            if ([self retainCount] == 2) {
                auto it = cache->Instances.find(self);
                if (it != cache->Instances.end()) {
                    v8::Locker locker(isolate);
                    Isolate::Scope isolate_scope(isolate);
                    HandleScope handle_scope(isolate);
                    if (it->second != nullptr) {
                        Local<Value> value = it->second->Get(isolate);
                        BaseDataWrapper* wrapper = tns::GetValue(isolate, value);
                        if (wrapper != nullptr && wrapper->Type() == WrapperType::ObjCObject) {
                            ObjCDataWrapper* objcWrapper = static_cast<ObjCDataWrapper*>(wrapper);
                            objcWrapper->GcUnprotect();
                        }
                    }
                }
            }

            release(self, @selector(release));
        });
        class_addMethod(extendedClass, @selector(release), newRelease, "v@:");

        info.GetReturnValue().Set(v8::Undefined(isolate));
    }).ToLocalChecked();

    PropertyAttribute flags = static_cast<PropertyAttribute>(PropertyAttribute::DontDelete);
    bool success = global->DefineOwnProperty(context, tns::ToV8String(isolate, "__extends"), extendsFunc, flags).FromMaybe(false);
    tns::Assert(success, isolate);
}

void ClassBuilder::ExposeDynamicMembers(v8::Local<v8::Context> context, Class extendedClass, Local<Object> implementationObject, Local<Object> nativeSignature) {
    Isolate* isolate = context->GetIsolate();

    Local<Value> exposedMethods;
    bool success = nativeSignature->Get(context, tns::ToV8String(isolate, "exposedMethods")).ToLocal(&exposedMethods);
    tns::Assert(success, isolate);

    Local<Value> exposedProtocols;
    success = nativeSignature->Get(context, tns::ToV8String(isolate, "protocols")).ToLocal(&exposedProtocols);
    tns::Assert(success, isolate);

    ClassBuilder::ExposeDynamicMethods(context, extendedClass, exposedMethods, exposedProtocols, implementationObject);
}

std::string ClassBuilder::GetTypeEncoding(const TypeEncoding* typeEncoding) {
    BinaryTypeEncodingType type = typeEncoding->type;
    switch (type) {
        case BinaryTypeEncodingType::VoidEncoding: {
            return @encode(void);
        }
        case BinaryTypeEncodingType::BoolEncoding: {
            return @encode(bool);
        }
        case BinaryTypeEncodingType::UnicharEncoding:
        case BinaryTypeEncodingType::UShortEncoding: {
            return @encode(ushort);
        }
        case BinaryTypeEncodingType::ShortEncoding: {
            return @encode(short);
        }
        case BinaryTypeEncodingType::UIntEncoding: {
            return @encode(uint);
        }
        case BinaryTypeEncodingType::IntEncoding: {
            return @encode(int);
        }
#if defined(__LP64__)
        case BinaryTypeEncodingType::ULongEncoding: {
            return @encode(uint64_t);
        }
        case BinaryTypeEncodingType::LongEncoding: {
            return @encode(int64_t);
        }
#else
        case BinaryTypeEncodingType::ULongEncoding: {
            return @encode(uint32_t);
        }
        case BinaryTypeEncodingType::LongEncoding: {
            return @encode(int32_t);
        }
#endif
        case BinaryTypeEncodingType::ULongLongEncoding: {
            return @encode(unsigned long long);
        }
        case BinaryTypeEncodingType::LongLongEncoding: {
            return @encode(long long);
        }
        case BinaryTypeEncodingType::UCharEncoding: {
            return @encode(unsigned char);
        }
        case BinaryTypeEncodingType::CharEncoding: {
            return @encode(char);
        }
        case BinaryTypeEncodingType::FloatEncoding: {
            return @encode(float);
        }
        case BinaryTypeEncodingType::DoubleEncoding: {
            return @encode(double);
        }
        case BinaryTypeEncodingType::CStringEncoding: {
            return @encode(char*);
        }
        case BinaryTypeEncodingType::ClassEncoding: {
            return @encode(Class);
        }
        case BinaryTypeEncodingType::SelectorEncoding: {
            return @encode(SEL);
        }
        case BinaryTypeEncodingType::BlockEncoding: {
            return @encode(dispatch_block_t);
        }
        case BinaryTypeEncodingType::StructDeclarationReference: {
            const char* structName = typeEncoding->details.declarationReference.name.valuePtr();
            const Meta* meta = ArgConverter::GetMeta(structName);
            tns::Assert(meta != nullptr && meta->type() == MetaType::Struct);
            const StructMeta* structMeta = static_cast<const StructMeta*>(meta);
            const TypeEncoding* fieldEncoding = structMeta->fieldsEncodings()->first();

            std::stringstream ss;
            ss << "{" << structName << "=";
            for (int i = 0; i < structMeta->fieldsCount(); i++) {
                ss << GetTypeEncoding(fieldEncoding);
                fieldEncoding = fieldEncoding->next();
            }
            ss << "}";
            return ss.str();
        }
        case BinaryTypeEncodingType::PointerEncoding: {
            std::stringstream ss;
            ss << "^";
            const TypeEncoding* innerType = typeEncoding->details.pointer.getInnerType();
            ss << GetTypeEncoding(innerType);
            return ss.str();
        }
        case BinaryTypeEncodingType::ConstantArrayEncoding: {
            const TypeEncoding* innerType = typeEncoding->details.constantArray.getInnerType();
            std::stringstream ss;
            ss << "[";
            ss << typeEncoding->details.constantArray.size << GetTypeEncoding(innerType);
            ss << "]";
            return ss.str();
        }
        case BinaryTypeEncodingType::IncompleteArrayEncoding: {
            const TypeEncoding* innerType = typeEncoding->details.incompleteArray.getInnerType();
            std::stringstream ss;
            ss << "^";
            ss << GetTypeEncoding(innerType);
            return ss.str();
        }
        case BinaryTypeEncodingType::ProtocolEncoding:
        case BinaryTypeEncodingType::InterfaceDeclarationReference:
        case BinaryTypeEncodingType::InstanceTypeEncoding:
        case BinaryTypeEncodingType::IdEncoding: {
            return "@";
        }

        default:
            // TODO: Handle the other possible types
            tns::Assert(false);
            return "";
    }
}

std::string ClassBuilder::GetTypeEncoding(const TypeEncoding* typeEncoding, int argsCount) {
    std::stringstream compilerEncoding;
    compilerEncoding << GetTypeEncoding(typeEncoding);
    compilerEncoding << "@:"; // id self, SEL _cmd

    for (int i = 0; i < argsCount; i++) {
        typeEncoding = typeEncoding->next();
        compilerEncoding << GetTypeEncoding(typeEncoding);
    }

    return compilerEncoding.str();
}

BinaryTypeEncodingType ClassBuilder::GetTypeEncodingType(Isolate* isolate, Local<Value> value) {
    if (BaseDataWrapper* wrapper = tns::GetValue(isolate, value)) {
        if (wrapper->Type() == WrapperType::ObjCClass) {
            return BinaryTypeEncodingType::IdEncoding;
        } else if (wrapper->Type() == WrapperType::ObjCProtocol) {
            return BinaryTypeEncodingType::IdEncoding;
        } else if (wrapper->Type() == WrapperType::Primitive) {
            PrimitiveDataWrapper* pdw = static_cast<PrimitiveDataWrapper*>(wrapper);
            return pdw->TypeEncoding()->type;
        } else if (wrapper->Type() == WrapperType::ObjCObject) {
            return BinaryTypeEncodingType::IdEncoding;
        } else if (wrapper->Type() == WrapperType::PointerType) {
            return BinaryTypeEncodingType::PointerEncoding;
        }
    }

    //  TODO: Unknown encoding type
    tns::Assert(false, isolate);
    return BinaryTypeEncodingType::VoidEncoding;
}

void ClassBuilder::ExposeDynamicMethods(Local<Context> context, Class extendedClass, Local<Value> exposedMethods, Local<Value> exposedProtocols, Local<Object> implementationObject) {
    Isolate* isolate = context->GetIsolate();
    std::vector<const ProtocolMeta*> protocols;
    if (!exposedProtocols.IsEmpty() && exposedProtocols->IsArray()) {
        Local<v8::Array> protocolsArray = exposedProtocols.As<v8::Array>();
        for (uint32_t i = 0; i < protocolsArray->Length(); i++) {
            Local<Value> element;
            bool success = protocolsArray->Get(context, i).ToLocal(&element);
            tns::Assert(success && !element.IsEmpty() && element->IsFunction(), isolate);

            Local<v8::Function> protoObj = element.As<v8::Function>();
            BaseDataWrapper* wrapper = tns::GetValue(isolate, protoObj);
            tns::Assert(wrapper && wrapper->Type() == WrapperType::ObjCProtocol, isolate);
            ObjCProtocolWrapper* protoWrapper = static_cast<ObjCProtocolWrapper*>(wrapper);
            Protocol* proto = protoWrapper->Proto();
            if (proto != nil && !class_conformsToProtocol(extendedClass, proto)) {
                class_addProtocol(extendedClass, proto);
                class_addProtocol(object_getClass(extendedClass), proto);
            }

            protocols.push_back(protoWrapper->ProtoMeta());
        }
    }

    if (!exposedMethods.IsEmpty() && exposedMethods->IsObject()) {
        Local<v8::Array> methodNames;
        if (!exposedMethods.As<Object>()->GetOwnPropertyNames(context).ToLocal(&methodNames)) {
            tns::Assert(false, isolate);
        }

        for (int i = 0; i < methodNames->Length(); i++) {
            Local<Value> methodName;
            bool success = methodNames->Get(context, i).ToLocal(&methodName);
            tns::Assert(success, isolate);

            Local<Value> methodSignature;
            success = exposedMethods.As<Object>()->Get(context, methodName).ToLocal(&methodSignature);
            tns::Assert(success && methodSignature->IsObject(), isolate);

            Local<Value> method;
            success = implementationObject->Get(context, methodName).ToLocal(&method);
            tns::Assert(success, isolate);

            if (method.IsEmpty() || !method->IsFunction()) {
                Log(@"No implementation found for exposed method \"%s\"", tns::ToString(isolate, methodName).c_str());
                continue;
            }

            Local<Value> returnsVal;
            success = methodSignature.As<Object>()->Get(context, tns::ToV8String(isolate, "returns")).ToLocal(&returnsVal);
            tns::Assert(success, isolate);

            Local<Value> paramsVal;
            success = methodSignature.As<Object>()->Get(context, tns::ToV8String(isolate, "params")).ToLocal(&paramsVal);
            tns::Assert(success, isolate);

            if (returnsVal.IsEmpty() || !returnsVal->IsObject()) {
                // Incorrect exposedMethods definition: missing returns property
                tns::Assert(false, isolate);
            }

            int argsCount = 0;
            if (!paramsVal.IsEmpty() && paramsVal->IsArray()) {
                argsCount = paramsVal.As<v8::Array>()->Length();
            }

            BinaryTypeEncodingType returnType = GetTypeEncodingType(isolate, returnsVal);

            std::string methodNameStr = tns::ToString(isolate, methodName);
            SEL selector = sel_registerName(methodNameStr.c_str());

            TypeEncoding* typeEncoding = reinterpret_cast<TypeEncoding*>(malloc((argsCount + 1) * sizeof(TypeEncoding)));
            typeEncoding->type = returnType;

            if (!paramsVal.IsEmpty() && paramsVal->IsArray()) {
                Local<v8::Array> params = paramsVal.As<v8::Array>();
                TypeEncoding* next = typeEncoding;
                for (int i = 0; i < params->Length(); i++) {
                    next = const_cast<TypeEncoding*>(next->next());
                    Local<Value> param;
                    success = params->Get(context, i).ToLocal(&param);
                    tns::Assert(success, isolate);

                    next->type = GetTypeEncodingType(isolate, param);
                }
            }

            std::shared_ptr<Persistent<Value>> poCallback = std::make_shared<Persistent<Value>>(isolate, method);
            MethodCallbackWrapper* userData = new MethodCallbackWrapper(isolate, poCallback, 2, argsCount, typeEncoding);
            IMP methodBody = Interop::CreateMethod(2, argsCount, typeEncoding, ArgConverter::MethodCallback, userData);
            std::string typeInfo = GetTypeEncoding(typeEncoding, argsCount);
            tns::Assert(class_addMethod(extendedClass, selector, methodBody, typeInfo.c_str()), isolate);
        }
    }

    const Meta* m = ArgConverter::FindMeta(extendedClass);
    if (m == nullptr) {
        return;
    }

    const BaseClassMeta* extendedClassMeta = static_cast<const BaseClassMeta*>(m);

    Local<v8::Array> propertyNames;

    Local<Value> symbolIterator;
    bool success = implementationObject->Get(context, Symbol::GetIterator(isolate)).ToLocal(&symbolIterator);
    tns::Assert(success, isolate);

    if (!symbolIterator.IsEmpty() && symbolIterator->IsFunction()) {
        Local<v8::Function> symbolIteratorFunc = symbolIterator.As<v8::Function>();

        class_addProtocol(extendedClass, @protocol(NSFastEnumeration));
        class_addProtocol(object_getClass(extendedClass), @protocol(NSFastEnumeration));

        Persistent<v8::Function>* poIteratorFunc = new Persistent<v8::Function>(isolate, symbolIteratorFunc);
        IMP imp = imp_implementationWithBlock(^NSUInteger(id self, NSFastEnumerationState* state, __unsafe_unretained id buffer[], NSUInteger length) {
            return tns::FastEnumerationAdapter(isolate, self, state, buffer, length, poIteratorFunc);
        });

        struct objc_method_description fastEnumerationMethodDescription = protocol_getMethodDescription(@protocol(NSFastEnumeration), @selector(countByEnumeratingWithState:objects:count:), YES, YES);
        tns::Assert(class_addMethod(extendedClass, @selector(countByEnumeratingWithState:objects:count:), imp, fastEnumerationMethodDescription.types), isolate);
    }

    tns::Assert(implementationObject->GetOwnPropertyNames(context).ToLocal(&propertyNames), isolate);
    for (uint32_t i = 0; i < propertyNames->Length(); i++) {
        Local<Value> key;
        bool success = propertyNames->Get(context, i).ToLocal(&key);
        tns::Assert(success, isolate);
        if (!key->IsName()) {
            continue;
        }

        std::string methodName = tns::ToString(isolate, key);

        Local<Value> propertyDescriptor;
        tns::Assert(implementationObject->GetOwnPropertyDescriptor(context, key.As<v8::Name>()).ToLocal(&propertyDescriptor), isolate);
        if (propertyDescriptor.IsEmpty() || propertyDescriptor->IsNullOrUndefined()) {
            continue;
        }

        Local<Value> getter;
        success = propertyDescriptor.As<Object>()->Get(context, tns::ToV8String(isolate, "get")).ToLocal(&getter);
        tns::Assert(success, isolate);

        Local<Value> setter;
        success = propertyDescriptor.As<Object>()->Get(context, tns::ToV8String(isolate, "set")).ToLocal(&setter);
        tns::Assert(success, isolate);

        if ((!getter.IsEmpty() || !setter.IsEmpty()) && (getter->IsFunction() || setter->IsFunction())) {
            std::vector<const PropertyMeta*> propertyMetas;
            VisitProperties(methodName, extendedClassMeta, propertyMetas, protocols);
            ExposeProperties(isolate, extendedClass, propertyMetas, implementationObject, getter, setter);
            continue;
        }

        Local<Value> method;
        success = propertyDescriptor.As<Object>()->Get(context, tns::ToV8String(isolate, "value")).ToLocal(&method);
        tns::Assert(success, isolate);

        if (method.IsEmpty() || !method->IsFunction()) {
            continue;
        }

        std::vector<const MethodMeta*> methodMetas;
        VisitMethods(extendedClass, methodName, extendedClassMeta, methodMetas, protocols);

        for (int j = 0; j < methodMetas.size(); j++) {
            const MethodMeta* methodMeta = methodMetas[j];
            std::shared_ptr<Persistent<Value>> poCallback = std::make_shared<Persistent<Value>>(isolate, method);
            const TypeEncoding* typeEncoding = methodMeta->encodings()->first();
            uint8_t argsCount = methodMeta->encodings()->count - 1;
            MethodCallbackWrapper* userData = new MethodCallbackWrapper(isolate, poCallback, 2, argsCount, typeEncoding);
            SEL selector = methodMeta->selector();
            IMP methodBody = Interop::CreateMethod(2, argsCount, typeEncoding, ArgConverter::MethodCallback, userData);
            std::string typeInfo = GetTypeEncoding(typeEncoding, argsCount);
            class_replaceMethod(extendedClass, selector, methodBody, typeInfo.c_str());
        }
    }
}

void ClassBuilder::VisitProperties(std::string propertyName, const BaseClassMeta* meta, std::vector<const PropertyMeta*>& propertyMetas, std::vector<const ProtocolMeta*> exposedProtocols) {
    for (auto it = meta->instanceProps->begin(); it != meta->instanceProps->end(); it++) {
        const PropertyMeta* propertyMeta = (*it).valuePtr();
        if (propertyMeta->jsName() == propertyName && std::find(propertyMetas.begin(), propertyMetas.end(), propertyMeta) == propertyMetas.end()) {
            propertyMetas.push_back(propertyMeta);
        }
    }

    for (auto protoIt = meta->protocols->begin(); protoIt != meta->protocols->end(); protoIt++) {
        const char* protocolName = (*protoIt).valuePtr();
        const Meta* m = ArgConverter::GetMeta(protocolName);
        if (!m) {
            continue;
        }
        const ProtocolMeta* protocolMeta = static_cast<const ProtocolMeta*>(m);
        VisitProperties(propertyName, protocolMeta, propertyMetas, exposedProtocols);
    }

    for (auto it = exposedProtocols.begin(); it != exposedProtocols.end(); it++) {
        const ProtocolMeta* protocolMeta = *it;
        VisitProperties(propertyName, protocolMeta, propertyMetas, std::vector<const ProtocolMeta*>());
    }

    if (meta->type() == MetaType::Interface) {
        const InterfaceMeta* interfaceMeta = static_cast<const InterfaceMeta*>(meta);
        const BaseClassMeta* baseMeta = interfaceMeta->baseMeta();
        if (baseMeta != nullptr) {
            VisitProperties(propertyName, baseMeta, propertyMetas, exposedProtocols);
        }
    }
}

void ClassBuilder::VisitMethods(Class extendedClass, std::string methodName, const BaseClassMeta* meta, std::vector<const MethodMeta*>& methodMetas, std::vector<const ProtocolMeta*> exposedProtocols) {
    for (auto it = meta->instanceMethods->begin(); it != meta->instanceMethods->end(); it++) {
        const MethodMeta* methodMeta = (*it).valuePtr();
        if (methodMeta->jsName() == methodName) {
            if (std::find(methodMetas.begin(), methodMetas.end(), methodMeta) == methodMetas.end()) {
                methodMetas.push_back(methodMeta);
            }
        }
    }

    for (auto protoIt = meta->protocols->begin(); protoIt != meta->protocols->end(); protoIt++) {
        const char* protocolName = (*protoIt).valuePtr();
        const Meta* m = ArgConverter::GetMeta(protocolName);
        if (!m) {
            continue;
        }
        const ProtocolMeta* protocolMeta = static_cast<const ProtocolMeta*>(m);
        VisitMethods(extendedClass, methodName, protocolMeta, methodMetas, exposedProtocols);
    }

    for (auto it = exposedProtocols.begin(); it != exposedProtocols.end(); it++) {
        const ProtocolMeta* protocolMeta = *it;
        VisitMethods(extendedClass, methodName, protocolMeta, methodMetas, std::vector<const ProtocolMeta*>());
    }

    if (meta->type() == MetaType::Interface) {
        const InterfaceMeta* interfaceMeta = static_cast<const InterfaceMeta*>(meta);
        const BaseClassMeta* baseMeta = interfaceMeta->baseMeta();
        if (baseMeta != nullptr) {
            VisitMethods(extendedClass, methodName, interfaceMeta->baseMeta(), methodMetas, exposedProtocols);
        }
    }
}

void ClassBuilder::ExposeProperties(Isolate* isolate, Class extendedClass, std::vector<const PropertyMeta*> propertyMetas, Local<Object> implementationObject, Local<Value> getter, Local<Value> setter) {
    for (int j = 0; j < propertyMetas.size(); j++) {
        const PropertyMeta* propertyMeta = propertyMetas[j];
        std::string propertyName = propertyMeta->name();

        bool hasGetter = !getter.IsEmpty() && getter->IsFunction() && propertyMeta->hasGetter();
        bool hasSetter = !setter.IsEmpty() && setter->IsFunction() && propertyMeta->hasSetter();

        std::shared_ptr<Persistent<Object>> poImplementationObject;
        if (hasGetter || hasSetter) {
            poImplementationObject = std::make_shared<Persistent<Object>>(isolate, implementationObject);
        }

        if (hasGetter) {
            std::shared_ptr<Persistent<v8::Function>> poGetterFunc = std::make_shared<Persistent<v8::Function>>(isolate, getter.As<v8::Function>());
            PropertyCallbackContext* userData = new PropertyCallbackContext(isolate, poGetterFunc, poImplementationObject, propertyMeta);

            FFIMethodCallback getterCallback = [](ffi_cif* cif, void* retValue, void** argValues, void* userData) {
                PropertyCallbackContext* context = static_cast<PropertyCallbackContext*>(userData);
                v8::Locker locker(context->isolate_);
                Isolate::Scope isolate_scope(context->isolate_);
                HandleScope handle_scope(context->isolate_);
                Local<v8::Function> getterFunc = context->callback_->Get(context->isolate_);
                Local<Value> res;

                id thiz = *static_cast<const id*>(argValues[0]);
                auto cache = Caches::Get(context->isolate_);
                auto it = cache->Instances.find(thiz);
                Local<Object> self_ = it != cache->Instances.end()
                    ? it->second->Get(context->isolate_).As<Object>()
                    : context->implementationObject_->Get(context->isolate_);
                Local<Context> v8Context = Caches::Get(context->isolate_)->GetContext();
                tns::Assert(getterFunc->Call(v8Context, self_, 0, nullptr).ToLocal(&res), context->isolate_);

                const TypeEncoding* typeEncoding = context->meta_->getter()->encodings()->first();
                ArgConverter::SetValue(v8Context, retValue, res, typeEncoding);
            };
            const TypeEncoding* typeEncoding = propertyMeta->getter()->encodings()->first();
            IMP impGetter = Interop::CreateMethod(2, 0, typeEncoding, getterCallback , userData);

            class_addMethod(extendedClass, propertyMeta->getter()->selector(), impGetter, "@@:");
        }

        if (hasSetter) {
            std::shared_ptr<Persistent<v8::Function>> poSetterFunc = std::make_shared<Persistent<v8::Function>>(isolate, setter.As<v8::Function>());
            PropertyCallbackContext* userData = new PropertyCallbackContext(isolate, poSetterFunc, poImplementationObject, propertyMeta);

            FFIMethodCallback setterCallback = [](ffi_cif* cif, void* retValue, void** argValues, void* userData) {
                PropertyCallbackContext* context = static_cast<PropertyCallbackContext*>(userData);
                v8::Locker locker(context->isolate_);
                Isolate::Scope isolate_scope(context->isolate_);
                HandleScope handle_scope(context->isolate_);
                Local<v8::Function> setterFunc = context->callback_->Get(context->isolate_);
                Local<Value> res;

                id thiz = *static_cast<const id*>(argValues[0]);
                auto cache = Caches::Get(context->isolate_);
                auto it = cache->Instances.find(thiz);
                Local<Object> self_ = it != cache->Instances.end()
                    ? it->second->Get(context->isolate_).As<Object>()
                    : context->implementationObject_->Get(context->isolate_);

                uint8_t* argBuffer = (uint8_t*)argValues[2];
                const TypeEncoding* typeEncoding = context->meta_->setter()->encodings()->first()->next();
                BaseCall call(argBuffer);
                Local<Context> v8Context = Caches::Get(context->isolate_)->GetContext();
                Local<Value> jsWrapper = Interop::GetResult(v8Context, typeEncoding, &call, true);
                Local<Value> params[1] = { jsWrapper };

                tns::Assert(setterFunc->Call(context->isolate_->GetCurrentContext(), self_, 1, params).ToLocal(&res), context->isolate_);
            };

            const TypeEncoding* typeEncoding = propertyMeta->setter()->encodings()->first();
            IMP impSetter = Interop::CreateMethod(2, 1, typeEncoding, setterCallback, userData);

            class_addMethod(extendedClass, propertyMeta->setter()->selector(), impSetter, "v@:@");
        }
    }
}

void ClassBuilder::SuperAccessorGetterCallback(Local<v8::Name> property, const PropertyCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    Local<Context> context = isolate->GetCurrentContext();
    Local<Object> thiz = info.This();

    std::shared_ptr<Persistent<Value>> poValue = ArgConverter::CreateEmptyObject(context);
    Local<Object> superValue = poValue->Get(isolate).As<Object>();

    superValue->SetPrototype(context, thiz->GetPrototype().As<Object>()->GetPrototype().As<Object>()->GetPrototype()).ToChecked();
    superValue->SetInternalField(0, thiz->GetInternalField(0));
    superValue->SetInternalField(1, tns::ToV8String(isolate, "super"));

    info.GetReturnValue().Set(superValue);
}

IMP ClassBuilder::FindNotOverridenMethod(Class klass, SEL method) {
    while (class_conformsToProtocol(klass, @protocol(TNSDerivedClass))) {
        klass = class_getSuperclass(klass);
    }

    return class_getMethodImplementation(klass, method);
}

unsigned long long ClassBuilder::classNameCounter_ = 0;

}
