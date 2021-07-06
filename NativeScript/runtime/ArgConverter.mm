#include <Foundation/Foundation.h>
#include <sstream>
#include "ArgConverter.h"
#include "NativeScriptException.h"
#include "DictionaryAdapter.h"
#include "ObjectManager.h"
#include "Interop.h"
#include "Helpers.h"
#include "Runtime.h"

using namespace v8;
using namespace std;

namespace tns {

void ArgConverter::Init(Local<Context> context, GenericNamedPropertyGetterCallback structPropertyGetter, GenericNamedPropertySetterCallback structPropertySetter) {
    Isolate* isolate = context->GetIsolate();
    auto cache = Caches::Get(isolate);
    cache->EmptyObjCtorFunc = std::make_unique<Persistent<v8::Function>>(isolate, ArgConverter::CreateEmptyInstanceFunction(context));
    cache->EmptyStructCtorFunc = std::make_unique<Persistent<v8::Function>>(isolate, ArgConverter::CreateEmptyInstanceFunction(context, structPropertyGetter, structPropertySetter));
}

Local<Value> ArgConverter::Invoke(Local<Context> context, Class klass, Local<Object> receiver, V8Args& args, const MethodMeta* meta, bool isMethodCallback) {
    Isolate* isolate = context->GetIsolate();
    id target = nil;
    bool instanceMethod = !receiver.IsEmpty();
    bool callSuper = false;
    if (instanceMethod) {
        BaseDataWrapper* wrapper = tns::GetValue(isolate, receiver);
        tns::Assert(wrapper != nullptr, isolate);

        if (wrapper->Type() == WrapperType::ObjCAllocObject) {
            ObjCAllocDataWrapper* allocWrapper = static_cast<ObjCAllocDataWrapper*>(wrapper);
            Class klass = allocWrapper->Klass();
            target = [klass alloc];
        } else if (wrapper->Type() == WrapperType::ObjCObject) {
            ObjCDataWrapper* objcWrapper = static_cast<ObjCDataWrapper*>(wrapper);
            target = objcWrapper->Data();

            std::string className = object_getClassName(target);
            auto cache = Caches::Get(isolate);
            auto it = cache->ClassPrototypes.find(className);
            // For extended classes we will call the base method
            callSuper = isMethodCallback && it != cache->ClassPrototypes.end();
        } else {
            tns::Assert(false, isolate);
        }
    }

    if (args.Length() != meta->encodings()->count - 1) {
        // Arguments number mismatch -> search for a possible method overload in the class hierarchy
        std::string methodName = meta->jsName();
        std::string className = class_getName(klass);
        MemberType type = instanceMethod ? MemberType::InstanceMethod : MemberType::StaticMethod;
        std::vector<const MethodMeta*> overloads;
        ArgConverter::FindMethodOverloads(klass, methodName, type, overloads);
        if (overloads.size() > 0) {
            for (auto it = overloads.begin(); it != overloads.end(); it++) {
                const MethodMeta* methodMeta = (*it);
                if (args.Length() == methodMeta->encodings()->count - 1) {
                    meta = methodMeta;
                    break;
                }
            }
        }
    }

    int argsCount = meta->encodings()->count - 1;
    if ((!meta->hasErrorOutParameter() && args.Length() != argsCount) ||
        (meta->hasErrorOutParameter() && args.Length() != argsCount && args.Length() != argsCount - 1)) {
        std::ostringstream errorStream;
        errorStream << "Actual arguments count: \"" << argsCount << ". Expected: \"" << args.Length() << "\".";
        std::string errorMessage = errorStream.str();
        throw NativeScriptException(errorMessage);
    }

    ObjCMethodCall methodCall(context, meta, target, klass, args, callSuper);
    return Interop::CallFunction(methodCall);
}

Local<Value> ArgConverter::ConvertArgument(Local<Context> context, BaseDataWrapper* wrapper, bool skipGCRegistration, const std::vector<std::string>& additionalProtocols) {
    Isolate* isolate = context->GetIsolate();
    if (wrapper == nullptr) {
        return Null(isolate);
    }

    Local<Value> result = CreateJsWrapper(context, wrapper, Local<Object>(), skipGCRegistration, additionalProtocols);
    return result;
}

void ArgConverter::MethodCallback(ffi_cif* cif, void* retValue, void** argValues, void* userData) {
    MethodCallbackWrapper* data = static_cast<MethodCallbackWrapper*>(userData);

    Isolate* isolate = data->isolate_;

    if (!Runtime::IsAlive(isolate)) {
        memset(retValue, 0, cif->rtype->size);
        return;
    }

    v8::Locker locker(isolate);
    Isolate::Scope isolate_scope(isolate);
    HandleScope handle_scope(isolate);
    std::shared_ptr<Caches> cache = Caches::Get(isolate);

    Local<Context> context = cache->GetContext();
    std::shared_ptr<Persistent<Value>> poCallback = data->callback_;

    bool hasErrorOutParameter = false;

    std::vector<Local<Value>> v8Args;
    v8Args.reserve(data->paramsCount_);
    const TypeEncoding* typeEncoding = data->typeEncoding_;
    for (int i = 0; i < data->paramsCount_; i++) {
        typeEncoding = typeEncoding->next();
        if (i == data->paramsCount_ - 1 && ArgConverter::IsErrorOutParameter(typeEncoding)) {
            hasErrorOutParameter = true;
            // No need to provide the NSError** parameter to the javascript callback
            continue;
        }

        int argIndex = i + data->initialParamIndex_;

        uint8_t* argBuffer = (uint8_t*)argValues[argIndex];
        BaseCall call(argBuffer);
        Local<Value> jsWrapper = Interop::GetResult(context, typeEncoding, &call, true);

        if (!jsWrapper.IsEmpty()) {
            v8Args.push_back(jsWrapper);
        } else {
            v8Args.push_back(v8::Undefined(isolate));
        }
    }

    Local<Object> thiz = context->Global();
    if (data->initialParamIndex_ > 1) {
        id self_ = *static_cast<const id*>(argValues[0]);
        auto it = cache->Instances.find(self_);
        if (it != cache->Instances.end()) {
            thiz = it->second->Get(data->isolate_).As<Object>();
        } else {
            ObjCDataWrapper* wrapper = new ObjCDataWrapper(self_);
            thiz = ArgConverter::CreateJsWrapper(context, wrapper, Local<Object>(), true).As<Object>();
        }
    }

    Local<Value> result;
    Local<v8::Function> callback = poCallback->Get(isolate).As<v8::Function>();

    bool success = false;
    if (hasErrorOutParameter) {
        // We don't want the global error handler (NativeScriptException::OnUncaughtError) to be called for javascript exceptions occuring inside
        // methods that have NSError* parameters. Those js errors will be marshalled to NSError* and sent
        // directly to the calling native code. The v8::TryCatch statement prevents the global handler to be called.
        TryCatch tc(isolate);
        success = callback->Call(context, thiz, (int)v8Args.size(), v8Args.data()).ToLocal(&result);
        if (!success && tc.HasCaught()) {
            Local<Value> exception = tc.Exception();
            std::string message = tns::ToString(isolate, exception);

            int errorParamIndex = data->initialParamIndex_ + data->paramsCount_ - 1;
            void* errorParam = argValues[errorParamIndex];
            NSError*__strong** outPtr = static_cast<NSError*__strong**>(errorParam);
            if (outPtr && *outPtr) {
                NSError* error = [NSError errorWithDomain:@"TNSErrorDomain" code:164 userInfo:@{ @"TNSJavaScriptError": [NSString stringWithUTF8String:message.c_str()] }];
                **static_cast<NSError*__strong**>(outPtr) = error;
            }
        }
    } else {
        success = callback->Call(context, thiz, (int)v8Args.size(), v8Args.data()).ToLocal(&result);
    }

    if (!success) {
        memset(retValue, 0, cif->rtype->size);
        return;
    }

    ArgConverter::SetValue(context, retValue, result, data->typeEncoding_);
}

void ArgConverter::SetValue(Local<Context> context, void* retValue, Local<Value> value, const TypeEncoding* typeEncoding) {
    if (typeEncoding->type == BinaryTypeEncodingType::VoidEncoding) {
        return;
    }

    if (value.IsEmpty() || value->IsNullOrUndefined()) {
        void* nullPtr = nullptr;
        *(ffi_arg *)retValue = (unsigned long)nullPtr;
        return;
    }

    Isolate* isolate = context->GetIsolate();

    // TODO: Refactor this to reuse some existing logic in Interop::SetFFIParams
    BinaryTypeEncodingType type = typeEncoding->type;

    if (tns::IsBool(value)) {
        bool boolValue = value.As<v8::Boolean>()->Value();
        *(ffi_arg *)retValue = (bool)boolValue;
        return;
    } else if (tns::IsNumber(value)) {
        double numValue = tns::ToNumber(isolate, value);
        switch (type) {
            case BinaryTypeEncodingType::UShortEncoding: {
                *static_cast<unsigned short*>(retValue) = (unsigned short)numValue;
                return;
            }
            case BinaryTypeEncodingType::ShortEncoding: {
                *static_cast<short*>(retValue) = (short)numValue;
                return;
            }
            case BinaryTypeEncodingType::UIntEncoding: {
                *static_cast<unsigned int*>(retValue) = (unsigned int)numValue;
                return;
            }
            case BinaryTypeEncodingType::IntEncoding: {
                *static_cast<int*>(retValue) = (int)numValue;
                return;
            }
            case BinaryTypeEncodingType::ULongEncoding: {
                *static_cast<unsigned long*>(retValue) = (unsigned long)numValue;
                return;
            }
            case BinaryTypeEncodingType::LongEncoding: {
                *static_cast<long*>(retValue) = (long)numValue;
                return;
            }
            case BinaryTypeEncodingType::ULongLongEncoding: {
                *static_cast<unsigned long long*>(retValue) = (unsigned long long)numValue;
                return;
            }
            case BinaryTypeEncodingType::LongLongEncoding: {
                *static_cast<long long*>(retValue) = (long long)numValue;
                return;
            }
            case BinaryTypeEncodingType::FloatEncoding: {
                *static_cast<float*>(retValue) = (float)numValue;
                return;
            }
            case BinaryTypeEncodingType::DoubleEncoding: {
                *static_cast<double*>(retValue) = numValue;
                return;
            }
            default:
                return;
        }
    } else if (value->IsString()) {
        if (type == BinaryTypeEncodingType::IdEncoding ||
            type == BinaryTypeEncodingType::InterfaceDeclarationReference) {
            std::string strValue = tns::ToString(isolate, value);
            id data = [NSString stringWithUTF8String:strValue.c_str()];
            *(CFTypeRef*)retValue = CFBridgingRetain(data);
            return;
        }
    } else if (value->IsObject()) {
        if (type == BinaryTypeEncodingType::InterfaceDeclarationReference ||
            type == BinaryTypeEncodingType::InstanceTypeEncoding ||
            type == BinaryTypeEncodingType::IdEncoding) {
            BaseDataWrapper* baseWrapper = tns::GetValue(isolate, value);
            if (baseWrapper != nullptr && baseWrapper->Type() == WrapperType::ObjCObject) {
                ObjCDataWrapper* wrapper = static_cast<ObjCDataWrapper*>(baseWrapper);
                id data = wrapper->Data();
                memset(retValue, 0, sizeof(id));
                *static_cast<id __strong *>(retValue) = data;
                return;
            } else {
                id adapter = [[DictionaryAdapter alloc] initWithJSObject:value.As<Object>() isolate:isolate];
                memset(retValue, 0, sizeof(id));
                *static_cast<id __strong *>(retValue) = adapter;
                CFAutorelease(adapter);
                return;
            }
        } else if (type == BinaryTypeEncodingType::StructDeclarationReference) {
            BaseDataWrapper* baseWrapper = tns::GetValue(isolate, value);
            if (baseWrapper == nullptr) {
                const char* structName = typeEncoding->details.declarationReference.name.valuePtr();
                const Meta* meta = ArgConverter::GetMeta(structName);
                tns::Assert(meta != nullptr && meta->type() == MetaType::Struct, isolate);
                const StructMeta* structMeta = static_cast<const StructMeta*>(meta);
                StructInfo structInfo = FFICall::GetStructInfo(structMeta);
                Interop::InitializeStruct(context, retValue, structInfo.Fields(), value);
                return;
            } else if (baseWrapper->Type() == WrapperType::Struct) {
                StructWrapper* structWrapper = static_cast<StructWrapper*>(baseWrapper);
                size_t size = structWrapper->StructInfo().FFIType()->size;
                void* data = structWrapper->Data();
                memcpy(retValue, data, size);
                return;
            }
        }
    }

    // TODO: Handle other return types, i.e. assign the retValue parameter from the v8 result
    tns::Assert(false, isolate);
}

void ArgConverter::ConstructObject(Local<Context> context, const FunctionCallbackInfo<Value>& info, Class klass, const InterfaceMeta* interfaceMeta) {
    Isolate* isolate = context->GetIsolate();
    tns::Assert(klass != nullptr, isolate);

    id result = nil;

    if (info.Length() == 1) {
        BaseDataWrapper* wrapper = tns::GetValue(isolate, info[0]);
        if (wrapper != nullptr && wrapper->Type() == WrapperType::Pointer) {
            PointerWrapper* pointerWrapper = static_cast<PointerWrapper*>(wrapper);
            result = CFBridgingRelease(pointerWrapper->Data());
        }
    }

    if (result == nil && interfaceMeta == nullptr) {
        const Meta* meta = ArgConverter::FindMeta(klass);
        if (meta != nullptr && meta->type() == MetaType::Interface) {
            interfaceMeta = static_cast<const InterfaceMeta*>(meta);
        }
    }

    if (result == nil && interfaceMeta != nullptr && info.Length() > 0) {
        std::vector<Local<Value>> args;
        const MethodMeta* initializer = ArgConverter::FindInitializer(context, klass, interfaceMeta, info, args);
        result = [klass alloc];

        V8VectorArgs vectorArgs(args);
        result = Interop::CallInitializer(context, initializer, result, klass, vectorArgs);
    }

    if (result == nil) {
        result = [[klass alloc] init];
    }

    auto cache = Caches::Get(isolate);
    auto it = cache->Instances.find(result);
    if (it != cache->Instances.end()) {
        Local<Value> obj = it->second->Get(isolate);
        info.GetReturnValue().Set(obj);
    } else {
        ObjCDataWrapper* wrapper = new ObjCDataWrapper(result);
        Local<Object> thiz = info.This();
        Local<Context> context = cache->GetContext();
        tns::SetValue(isolate, thiz, wrapper);
        std::shared_ptr<Persistent<Value>> poThiz = ObjectManager::Register(context, thiz);
        cache->Instances.emplace(result, poThiz);
        [result retain];
    }
}

const MethodMeta* ArgConverter::FindInitializer(Local<Context> context, Class klass, const InterfaceMeta* interfaceMeta, const FunctionCallbackInfo<Value>& info, std::vector<Local<Value>>& args) {
    Isolate* isolate = context->GetIsolate();
    std::vector<const MethodMeta*> candidates;
    args = tns::ArgsToVector(info);
    std::vector<Local<Value>> initializerArgs;
    std::string constructorTokens;
    if (info.Length() == 1 && info[0]->IsObject() && tns::GetValue(isolate, info[0]) == nullptr) {
        initializerArgs = GetInitializerArgs(info[0].As<Object>(), constructorTokens);
    }

    std::shared_ptr<Caches> cache = Caches::Get(isolate);
    bool found = false;
    do {
        std::vector<const MethodMeta*> initializers = ArgConverter::GetInitializers(cache.get(), klass, interfaceMeta);
        for (const MethodMeta* candidate: initializers) {
            if (constructorTokens != "") {
                const char* expectedTokens = candidate->constructorTokens();
                if (strcmp(expectedTokens, constructorTokens.c_str()) == 0) {
                    candidates.clear();
                    candidates.push_back(candidate);
                    args = initializerArgs;
                    found = true;
                    break;
                }
            }

            if (ArgConverter::CanInvoke(context, candidate, info)) {
                candidates.push_back(candidate);
            }
        }

        if (found) {
            break;
        }

        interfaceMeta = interfaceMeta->baseMeta();
    } while (interfaceMeta);

    if (candidates.size() == 0) {
        throw NativeScriptException("No initializer found that matches constructor invocation.");
    } else if (candidates.size() > 1) {
        if (info.Length() == 0) {
            auto it = std::find_if(candidates.begin(), candidates.end(), [](const MethodMeta* c) -> bool { return strcmp(c->name(), "init") == 0; });
            if (it != candidates.end()) {
                return (*it);
            }
        }

        std::stringstream ss;
        ss << "More than one initializer found that matches constructor invocation:";
        for (int i = 0; i < candidates.size(); i++) {
            ss << " ";
            ss << candidates[i]->selectorAsString();
        }
        std::string errorMessage = ss.str();
        throw NativeScriptException(errorMessage);
    }

    return candidates[0];
}

bool ArgConverter::CanInvoke(Local<Context> context, const MethodMeta* candidate, const FunctionCallbackInfo<Value>& info) {
    if (candidate->encodings()->count - 1 != info.Length()) {
        return false;
    }

    if (info.Length() == 0) {
        return true;
    }

    const TypeEncoding* typeEncoding = candidate->encodings()->first();
    for (int i = 0; i < info.Length(); i++) {
        typeEncoding = typeEncoding->next();
        Local<Value> arg = info[i];

        if (!CanInvoke(context, typeEncoding, arg)) {
            return false;
        }
    }

    return true;
}

bool ArgConverter::CanInvoke(Local<Context> context, const TypeEncoding* typeEncoding, Local<Value> arg) {
    if (arg.IsEmpty() || arg->IsNullOrUndefined()) {
        return true;
    }

    Isolate* isolate = context->GetIsolate();
    if (typeEncoding->type == BinaryTypeEncodingType::InterfaceDeclarationReference) {
        const char* name = typeEncoding->details.declarationReference.name.valuePtr();
        if (strcmp(name, "NSNumber") == 0 && tns::IsNumber(arg)) {
            return true;
        }

        if (strcmp(name, "NSString") == 0 && tns::IsString(arg)) {
            return true;
        }

        if (strcmp(name, "NSArray") == 0 && arg->IsArray()) {
            return true;
        }

        if (BaseDataWrapper* wrapper = tns::GetValue(isolate, arg)) {
            if (wrapper->Type() == WrapperType::ObjCObject) {
                ObjCDataWrapper* objcWrapper = static_cast<ObjCDataWrapper*>(wrapper);
                Class candidateClass = objc_getClass(name);
                if (candidateClass != nil && [objcWrapper->Data() isKindOfClass:candidateClass]) {
                    return true;
                }
            }
        }
    }

    if (typeEncoding->type == BinaryTypeEncodingType::StructDeclarationReference) {
        return arg->IsObject();
    }

    if (tns::IsBool(arg)) {
        return typeEncoding->type == BinaryTypeEncodingType::BoolEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::IdEncoding;
    }

    if (tns::IsNumber(arg)) {
        return typeEncoding->type == BinaryTypeEncodingType::IdEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::UShortEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::ShortEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::UIntEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::IntEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::ULongEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::LongEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::ULongLongEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::LongLongEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::FloatEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::DoubleEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::UCharEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::CharEncoding;
    }

    if (tns::IsString(arg)) {
        return typeEncoding->type == BinaryTypeEncodingType::SelectorEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::UnicharEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::IdEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::CStringEncoding;
    }

    if (arg->IsFunction()) {
        return typeEncoding->type == BinaryTypeEncodingType::BlockEncoding ||
            typeEncoding->type == BinaryTypeEncodingType::ProtocolEncoding;
    }

    if (arg->IsArrayBuffer() || arg->IsArrayBufferView()) {
        return typeEncoding->type == BinaryTypeEncodingType::IncompleteArrayEncoding;
    }

    return false;
}

std::vector<Local<Value>> ArgConverter::GetInitializerArgs(Local<Object> obj, std::string& constructorTokens) {
    std::vector<Local<Value>> args;
    constructorTokens = "";
    Local<Context> context = obj->CreationContext();
    Isolate* isolate = context->GetIsolate();
    Local<v8::Array> properties;
    if (obj->GetOwnPropertyNames(context).ToLocal(&properties)) {
        std::stringstream ss;
        for (uint32_t i = 0; i < properties->Length(); i++) {
            Local<Value> propertyName;
            if (properties->Get(context, i).ToLocal(&propertyName)) {
                std::string name = tns::ToString(isolate, propertyName);
                ss << name << ":";
                Local<Value> propertyValue;
                bool ok = obj->Get(context, propertyName).ToLocal(&propertyValue);
                tns::Assert(ok, isolate);
                args.push_back(propertyValue);
            }
        }
        constructorTokens = ss.str();
    }

    return args;
}

Local<Value> ArgConverter::CreateJsWrapper(Local<Context> context, BaseDataWrapper* wrapper, Local<Object> receiver, bool skipGCRegistration, const std::vector<std::string>& additionalProtocols) {
    Isolate* isolate = context->GetIsolate();

    if (wrapper == nullptr) {
        return Null(isolate);
    }

    if (wrapper->Type() == WrapperType::Struct) {
        if (receiver.IsEmpty()) {
            std::shared_ptr<Persistent<Value>> poStruct = CreateEmptyStruct(context);
            receiver = poStruct->Get(isolate).As<Object>();
        }

        StructWrapper* structWrapper = static_cast<StructWrapper*>(wrapper);
        StructInfo structInfo = structWrapper->StructInfo();
        auto cache = Caches::Get(isolate);
        Local<v8::Function> structCtorFunc = cache->StructCtorInitializer(context, structInfo);
        Local<Value> proto;
        bool success = structCtorFunc->Get(context, tns::ToV8String(isolate, "prototype")).ToLocal(&proto);

        if (success && !proto.IsEmpty()) {
            success = receiver->SetPrototype(context, proto).FromMaybe(false);
            tns::Assert(success, isolate);
        }

        tns::SetValue(isolate, receiver, structWrapper);

        return receiver;
    }

    if (wrapper->Type() == WrapperType::ObjCAllocObject) {
        ObjCAllocDataWrapper* allocDataWrapper = static_cast<ObjCAllocDataWrapper*>(wrapper);
        Class klass = allocDataWrapper->Klass();

        std::shared_ptr<Persistent<Value>> poValue = CreateEmptyObject(context, false);
        receiver = poValue->Get(isolate).As<Object>();

        const Meta* meta = FindMeta(klass);
        if (meta != nullptr) {
            auto cache = Caches::Get(isolate);
            KnownUnknownClassPair pair(objc_getClass(meta->name()));
            std::vector<std::string> emptyProtocols;
            cache->ObjectCtorInitializer(context, static_cast<const BaseClassMeta*>(meta), pair, emptyProtocols);
            auto it = cache->Prototypes.find(meta);
            if (it != cache->Prototypes.end()) {
                Local<Value> prototype = it->second->Get(isolate);
                bool success;
                if (!receiver->SetPrototype(context, prototype).To(&success) || !success) {
                    tns::Assert(false, isolate);
                }
            }
        }

        tns::SetValue(isolate, receiver, wrapper);

        return receiver;
    }

    id target = nil;
    const TypeEncoding* typeEncoding = nullptr;
    if (wrapper->Type() == WrapperType::ObjCObject) {
        ObjCDataWrapper* dataWrapper = static_cast<ObjCDataWrapper*>(wrapper);
        target = dataWrapper->Data();
        typeEncoding = dataWrapper->TypeEncoding();
    }

    if (target == nil) {
        return Null(isolate);
    }

    auto cache = Caches::Get(isolate);
    if (receiver.IsEmpty()) {
        auto it = cache->Instances.find(target);
        if (it != cache->Instances.end()) {
            receiver = it->second->Get(isolate).As<Object>();
        } else {
            std::shared_ptr<Persistent<Value>> poValue = CreateEmptyObject(context, skipGCRegistration);
            receiver = poValue->Get(isolate).As<Object>();
            tns::SetValue(isolate, receiver, wrapper);
            cache->Instances.emplace(target, poValue);
            [target retain];
        }
    } else {
        tns::SetValue(isolate, receiver, wrapper);
    }

    Class klass = [target class];
    const Meta* meta = FindMeta(klass, typeEncoding);
    if (meta != nullptr) {
        std::string className = object_getClassName(target);
        auto it = cache->ClassPrototypes.find(className);
        if (it != cache->ClassPrototypes.end()) {
            Local<Value> prototype = it->second->Get(isolate);
            bool success;
            if (!receiver->SetPrototype(context, prototype).To(&success) || !success) {
                tns::Assert(false, isolate);
            }
        } else {
            Class knownClass = objc_getClass(meta->name());
            KnownUnknownClassPair pair(knownClass, klass);
            Local<FunctionTemplate> ctorFuncTemplate = cache->ObjectCtorInitializer(context, static_cast<const BaseClassMeta*>(meta), pair, additionalProtocols);
            Local<v8::Function> ctorFunc;
            bool success = ctorFuncTemplate->GetFunction(context).ToLocal(&ctorFunc);
            tns::Assert(success, isolate);

            Local<Value> prototypeValue;
            success = ctorFunc->Get(context, tns::ToV8String(isolate, "prototype")).ToLocal(&prototypeValue);
            tns::Assert(success, isolate);
            Local<Object> prototype = prototypeValue.As<Object>();

            if (!receiver->SetPrototype(context, prototype).To(&success) || !success) {
                tns::Assert(false, isolate);
            }
        }
    }

    Class metaClass = object_getClass(target);
    if (class_isMetaClass(metaClass)) {
        if (tns::GetValue(isolate, receiver) == nullptr) {
            ObjCClassWrapper* wrapper = new ObjCClassWrapper(klass);
            tns::SetValue(isolate, receiver, wrapper);
        }
    }

    return receiver;
}

const Meta* ArgConverter::FindMeta(Class klass, const TypeEncoding* typeEncoding) {
    if (typeEncoding != nullptr && typeEncoding->type == BinaryTypeEncodingType::InterfaceDeclarationReference) {
        const char* name = typeEncoding->details.interfaceDeclarationReference.name.valuePtr();
        const Meta* result = GetMeta(name);
        if (result != nullptr && result->type() == MetaType::Interface) {
            return result;
        }
    }

    std::string origClassName = class_getName(klass);
    const Meta* meta = Caches::Metadata->Get(origClassName);
    if (meta != nullptr) {
        return meta;
    }

    std::string className = origClassName;

    while (true) {
        const Meta* result = GetMeta(className);
        if (result != nullptr && result->type() == MetaType::Interface) {
            Caches::Metadata->Insert(origClassName, result);
            return result;
        }

        klass = class_getSuperclass(klass);
        if (klass == nullptr) {
            break;
        }

        className = class_getName(klass);
    }

    return nullptr;
}

const Meta* ArgConverter::GetMeta(std::string name) {
    bool found;
    const Meta* meta = Caches::Metadata->Get(name, found);
    if (meta != nullptr || found) {
        return meta;
    }

    const GlobalTable<GlobalTableType::ByJsName>* globalTable = MetaFile::instance()->globalTableJs();
    const Meta* result = globalTable->findMeta(name.c_str(), false /** onlyIfAvailable **/);

    if (result == nullptr) {
        const GlobalTable<GlobalTableType::ByNativeName>* globalTableInterfaceNames = MetaFile::instance()->globalTableNativeInterfaces();
        result = globalTableInterfaceNames->findMeta(name.c_str(), false /** onlyIfAvailable **/);

        if (result == nullptr) {
            const GlobalTable<GlobalTableType::ByNativeName>* globalTableProtocolNames = MetaFile::instance()->globalTableNativeProtocols();
            result = globalTableProtocolNames->findMeta(name.c_str(), false /** onlyIfAvailable **/);
        }
    }

    Caches::Metadata->Insert(name, result);

    return result;
}

const ProtocolMeta* ArgConverter::FindProtocolMeta(Protocol* protocol) {
    std::string protocolName = protocol_getName(protocol);
    const Meta* meta = ArgConverter::GetMeta(protocolName);
    if (meta != nullptr && meta->type() != MetaType::ProtocolType) {
        std::string newProtocolName = protocolName + "Protocol";

        size_t protocolIndex = 2;
        while (objc_getProtocol(newProtocolName.c_str())) {
            newProtocolName = protocolName + "Protocol" + std::to_string(protocolIndex++);
        }

        meta = ArgConverter::GetMeta(newProtocolName);
    }

    if (meta == nullptr) {
        return nullptr;
    }

    tns::Assert(meta->type() == MetaType::ProtocolType);
    const ProtocolMeta* protocolMeta = static_cast<const ProtocolMeta*>(meta);
    return protocolMeta;
}

std::shared_ptr<Persistent<Value>> ArgConverter::CreateEmptyObject(Local<Context> context, bool skipGCRegistration) {
    Isolate* isolate = context->GetIsolate();
    Persistent<v8::Function>* ctorFunc = Caches::Get(isolate)->EmptyObjCtorFunc.get();
    tns::Assert(ctorFunc != nullptr, isolate);
    return ArgConverter::CreateEmptyInstance(context, ctorFunc, skipGCRegistration);
}

std::shared_ptr<Persistent<Value>> ArgConverter::CreateEmptyStruct(Local<Context> context) {
    Isolate* isolate = context->GetIsolate();
    Persistent<v8::Function>* ctorFunc = Caches::Get(isolate)->EmptyStructCtorFunc.get();
    tns::Assert(ctorFunc != nullptr, isolate);
    return ArgConverter::CreateEmptyInstance(context, ctorFunc);
}

std::shared_ptr<Persistent<Value>> ArgConverter::CreateEmptyInstance(Local<Context> context, Persistent<v8::Function>* ctorFunc, bool skipGCRegistration) {
    Isolate* isolate = context->GetIsolate();
    Local<v8::Function> emptyCtorFunc = ctorFunc->Get(isolate);
    Local<Value> value;
    if (!emptyCtorFunc->CallAsConstructor(context, 0, nullptr).ToLocal(&value) || value.IsEmpty() || !value->IsObject()) {
        tns::Assert(false, isolate);
    }
    Local<Object> result = value.As<Object>();

    std::shared_ptr<Persistent<Value>> poValue;
    if (!skipGCRegistration) {
        poValue = ObjectManager::Register(context, result);
    } else {
        poValue = std::make_shared<Persistent<Value>>(isolate, result);
    }

    return poValue;
}

Local<v8::Function> ArgConverter::CreateEmptyInstanceFunction(Local<Context> context, GenericNamedPropertyGetterCallback propertyGetter, GenericNamedPropertySetterCallback propertySetter) {
    Isolate* isolate = context->GetIsolate();
    Local<FunctionTemplate> emptyInstanceCtorFuncTemplate = FunctionTemplate::New(isolate, nullptr);
    Local<ObjectTemplate> instanceTemplate = emptyInstanceCtorFuncTemplate->InstanceTemplate();
    instanceTemplate->SetInternalFieldCount(2);

    if (propertyGetter != nullptr || propertySetter != nullptr) {
        NamedPropertyHandlerConfiguration config(propertyGetter, propertySetter);
        instanceTemplate->SetHandler(config);
    }

    instanceTemplate->SetIndexedPropertyHandler(IndexedPropertyGetterCallback, IndexedPropertySetterCallback);

    Local<v8::Function> emptyInstanceCtorFunc;
    if (!emptyInstanceCtorFuncTemplate->GetFunction(context).ToLocal(&emptyInstanceCtorFunc)) {
        tns::Assert(false, isolate);
    }
    return emptyInstanceCtorFunc;
}

void ArgConverter::IndexedPropertyGetterCallback(uint32_t index, const PropertyCallbackInfo<Value>& args) {
    Local<Object> thiz = args.This();
    Isolate* isolate = args.GetIsolate();
    BaseDataWrapper* wrapper = tns::GetValue(isolate, thiz);
    if (wrapper == nullptr || wrapper->Type() != WrapperType::ObjCObject) {
        return;
    }

    ObjCDataWrapper* objcDataWrapper = static_cast<ObjCDataWrapper*>(wrapper);
    id target = objcDataWrapper->Data();
    if (![target isKindOfClass:[NSArray class]]) {
        return;
    }

    NSArray* array = (NSArray*)target;
    if (index >= [array count]) {
        return;
    }

    id obj = [array objectAtIndex:index];

    std::shared_ptr<Caches> cache = Caches::Get(isolate);
    auto it = cache->Instances.find(obj);
    if (it != cache->Instances.end()) {
        args.GetReturnValue().Set(it->second->Get(isolate));
        return;
    }

    if (obj == nil || obj == [NSNull null]) {
        args.GetReturnValue().Set(Null(isolate));
        return;
    }

    if ([obj isKindOfClass:[@YES class]]) {
        args.GetReturnValue().Set(v8::Boolean::New(isolate, [obj boolValue]));
        return;
    }

    if ([obj isKindOfClass:[NSDate class]]) {
        Local<Context> context = isolate->GetCurrentContext();
        double time = [obj timeIntervalSince1970] * 1000.0;
        Local<Value> date;
        if (Date::New(context, time).ToLocal(&date)) {
            args.GetReturnValue().Set(date);
            return;
        }

        std::ostringstream errorStream;
        errorStream << "Unable to convert " << [obj description] << " to a Date object";
        std::string errorMessage = errorStream.str();
        Local<Value> error = Exception::Error(tns::ToV8String(isolate, errorMessage));
        isolate->ThrowException(error);
        return;
    }

    if ([obj isKindOfClass:[NSString class]]) {
        const char* str = [obj UTF8String];
        args.GetReturnValue().Set(tns::ToV8String(isolate, str));
        return;
    }

    if ([obj isKindOfClass:[NSNumber class]] && ![obj isKindOfClass:[NSDecimalNumber class]]) {
        double value = [obj doubleValue];
        args.GetReturnValue().Set(Number::New(isolate, value));
        return;
    }

    Local<Context> context = isolate->GetCurrentContext();
    Local<Value> result = ArgConverter::ConvertArgument(context, new ObjCDataWrapper(obj));
    args.GetReturnValue().Set(result);
}

void ArgConverter::IndexedPropertySetterCallback(uint32_t index, Local<Value> value, const PropertyCallbackInfo<Value>& args) {
    Local<Object> thiz = args.This();
    Isolate* isolate = args.GetIsolate();
    BaseDataWrapper* wrapper = tns::GetValue(isolate, thiz);
    if (wrapper == nullptr && wrapper->Type() != WrapperType::ObjCObject) {
        return;
    }

    ObjCDataWrapper* objcDataWrapper = static_cast<ObjCDataWrapper*>(wrapper);
    id target = objcDataWrapper->Data();
    if (![target isKindOfClass:[NSMutableArray class]]) {
        return;
    }

    NSMutableArray* array = (NSMutableArray*)target;
    if (index >= [array count]) {
        return;
    }

    BaseDataWrapper* itemWrapper = tns::GetValue(isolate, value);
    if (itemWrapper == nullptr || itemWrapper->Type() != WrapperType::ObjCObject) {
        return;
    }

    ObjCDataWrapper* objcItemDataWrapper = static_cast<ObjCDataWrapper*>(itemWrapper);
    id item = objcItemDataWrapper->Data();
    [target replaceObjectAtIndex:index withObject:item];
}

void ArgConverter::FindMethodOverloads(Class klass, std::string methodName, MemberType type, std::vector<const MethodMeta*>& overloads) {
    const Meta* meta = ArgConverter::FindMeta(klass);
    if (klass == nullptr || meta == nullptr || meta->type() != MetaType::Interface) {
        return;
    }

    const InterfaceMeta* interfaceMeta = static_cast<const InterfaceMeta*>(meta);
    MembersCollection members = interfaceMeta->members(methodName.c_str(), methodName.length(), type, true, true, ProtocolMetas());
    for (auto it = members.begin(); it != members.end(); it++) {
        const MethodMeta* methodMeta = static_cast<const MethodMeta*>(*it);
        overloads.push_back(methodMeta);
    }

    if (interfaceMeta->baseName() != nullptr) {
        Class baseClass = objc_getClass(interfaceMeta->baseName());
        ArgConverter::FindMethodOverloads(baseClass, methodName, type, overloads);
    }
}

bool ArgConverter::IsErrorOutParameter(const TypeEncoding* typeEncoding) {
    if (typeEncoding->type != BinaryTypeEncodingType::PointerEncoding) {
        return false;
    }

    const TypeEncoding* innerTypeEncoding = typeEncoding->details.pointer.getInnerType();
    if (innerTypeEncoding->type != BinaryTypeEncodingType::InterfaceDeclarationReference) {
        return false;
    }

    const char* name = innerTypeEncoding->details.declarationReference.name.valuePtr();
    if (name == nullptr) {
        return false;
    }

    return strcmp(name, "NSError") == 0;
}

std::vector<const MethodMeta*> ArgConverter::GetInitializers(Caches* cache, Class klass, const InterfaceMeta* interfaceMeta) {
    auto it = cache->Initializers.find(interfaceMeta);
    if (it != cache->Initializers.end()) {
        return it->second;
    }

    KnownUnknownClassPair klasses(klass);
    std::vector<const MethodMeta*> initializers = interfaceMeta->initializersWithProtocols(klasses, ProtocolMetas());

    cache->Initializers.emplace(interfaceMeta, initializers);

    return initializers;
}

}
