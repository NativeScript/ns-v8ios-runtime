#include "Reference.h"
#include "Pointer.h"
#include "Caches.h"
#include "ObjectManager.h"
#include "Helpers.h"
#include "Interop.h"

using namespace v8;

namespace tns {

void Reference::Register(Local<Context> context, Local<Object> interop) {
    Isolate* isolate = context->GetIsolate();
    Local<v8::Function> ctorFunc = Reference::GetInteropReferenceCtorFunc(context);
    bool success = interop->Set(context, tns::ToV8String(isolate, "Reference"), ctorFunc).FromMaybe(false);
    tns::Assert(success, isolate);
}

Local<Value> Reference::FromPointer(Local<Context> context, Local<Value> type, void* handle) {
    Isolate* isolate = context->GetIsolate();
    Local<Value> pointer = Pointer::NewInstance(context, handle);
    ObjectManager::Register(context, pointer);

    Local<v8::Function> interopReferenceCtorFunc = Reference::GetInteropReferenceCtorFunc(context);
    Local<Value> args[2] = { type, pointer };
    Local<Object> instance;
    bool success = interopReferenceCtorFunc->NewInstance(context, 2, args).ToLocal(&instance);
    tns::Assert(success, isolate);
    ObjectManager::Register(context, instance);

    return instance;
}

Local<v8::Function> Reference::GetInteropReferenceCtorFunc(Local<Context> context) {
    Isolate* isolate = context->GetIsolate();
    auto cache = Caches::Get(isolate);
    Persistent<v8::Function>* interopReferenceCtor = cache->InteropReferenceCtorFunc.get();
    if (interopReferenceCtor != nullptr) {
        return interopReferenceCtor->Get(isolate);
    }

    Local<FunctionTemplate> ctorFuncTemplate = FunctionTemplate::New(isolate, ReferenceConstructorCallback);
    ctorFuncTemplate->SetClassName(tns::ToV8String(isolate, "Reference"));
    ctorFuncTemplate->InstanceTemplate()->SetInternalFieldCount(1);
    ctorFuncTemplate->InstanceTemplate()->SetHandler(IndexedPropertyHandlerConfiguration(IndexedPropertyGetCallback, IndexedPropertySetCallback));
    Local<ObjectTemplate> proto = ctorFuncTemplate->PrototypeTemplate();
    proto->SetAccessor(tns::ToV8String(isolate, "value"), GetValueCallback, SetValueCallback);

    Local<v8::Function> ctorFunc;
    if (!ctorFuncTemplate->GetFunction(context).ToLocal(&ctorFunc)) {
        tns::Assert(false, isolate);
    }

    tns::SetValue(isolate, ctorFunc, new ReferenceTypeWrapper());
    Local<Value> prototypeValue;
    bool success = ctorFunc->Get(context, tns::ToV8String(isolate, "prototype")).ToLocal(&prototypeValue);
    tns::Assert(success && prototypeValue->IsObject(), isolate);
    Local<Object> prototype = prototypeValue.As<Object>();
    Reference::RegisterToStringMethod(context, prototype);

    cache->InteropReferenceCtorFunc = std::make_unique<Persistent<v8::Function> >(isolate, ctorFunc);

    return ctorFunc;
}

void Reference::ReferenceConstructorCallback(const FunctionCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    Local<Context> context = isolate->GetCurrentContext();
    Persistent<Value>* val = nullptr;
    BaseDataWrapper* typeWrapper = nullptr;
    if (info.Length() == 1) {
        if (!info[0]->IsNullOrUndefined()) {
            val = new Persistent<Value>(isolate, info[0]);
        }
    } else if (info.Length() > 1) {
        if (!info[0]->IsNullOrUndefined() && !info[1]->IsNullOrUndefined()) {
            Local<Value> typeValue = info[0];
            typeWrapper = tns::GetValue(isolate, typeValue);
            tns::Assert(typeWrapper != nullptr, isolate);
            val = new Persistent<Value>(isolate, info[1]);
        }
    }
    
    if(val != nullptr) {
        val->SetWeak();
    }

    ReferenceWrapper* wrapper = new ReferenceWrapper(typeWrapper, val);
    Local<Object> thiz = info.This();
    tns::SetValue(isolate, thiz, wrapper);

    ObjectManager::Register(context, thiz);
}

void Reference::IndexedPropertyGetCallback(uint32_t index, const PropertyCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    Local<Object> thiz = info.This();
    Local<Context> context = isolate->GetCurrentContext();

    DataPair pair = Reference::GetTypeEncodingDataPair(thiz);
    const TypeEncoding* typeEncoding = pair.typeEncoding_;
    size_t size = pair.size_;
    void* data = pair.data_;

    void* ptr = (uint8_t*)data + index * size;
    BaseCall call((uint8_t*)ptr);
    Local<Value> result = Interop::GetResult(context, typeEncoding, &call, false);
    info.GetReturnValue().Set(result);
}

void Reference::IndexedPropertySetCallback(uint32_t index, Local<Value> value, const PropertyCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    Local<Context> context = isolate->GetCurrentContext();
    Local<Object> thiz = info.This();

    DataPair pair = Reference::GetTypeEncodingDataPair(thiz);
    const TypeEncoding* typeEncoding = pair.typeEncoding_;
    size_t size = pair.size_;
    void* data = pair.data_;

    void* ptr = (uint8_t*)data + index * size;
    Interop::WriteValue(context, typeEncoding, ptr, value);
}

void Reference::GetValueCallback(Local<v8::Name> name, const PropertyCallbackInfo<Value>& info) {
    Isolate* isolate = info.GetIsolate();
    Local<Context> context = isolate->GetCurrentContext();
    Local<Value> result = Reference::GetReferredValue(context, info.This());
    if (result.IsEmpty()) {
        info.GetReturnValue().Set(v8::Undefined(isolate));
    } else {
        info.GetReturnValue().Set(result);
    }
}

void Reference::SetValueCallback(Local<v8::Name> name, Local<Value> value, const PropertyCallbackInfo<void>& info) {
    Isolate* isolate = info.GetIsolate();
    BaseDataWrapper* baseWrapper = tns::GetValue(isolate, info.This());
    tns::Assert(baseWrapper->Type() == WrapperType::Reference, isolate);
    ReferenceWrapper* wrapper = static_cast<ReferenceWrapper*>(baseWrapper);
    Persistent<Value>* poValue = new Persistent<Value>(isolate, value);

    wrapper->SetData(nullptr);
    wrapper->SetEncoding(nullptr);
    wrapper->SetValue(poValue);
}

Local<Value> Reference::GetReferredValue(Local<Context> context, Local<Value> value) {
    Isolate* isolate = context->GetIsolate();
    BaseDataWrapper* baseWrapper = tns::GetValue(isolate, value);
    if (baseWrapper == nullptr || baseWrapper->Type() != WrapperType::Reference) {
        return value;
    }

    ReferenceWrapper* wrapper = static_cast<ReferenceWrapper*>(baseWrapper);
    if (wrapper->Data() != nullptr && wrapper->Encoding() != nullptr) {
        const TypeEncoding* encoding = wrapper->Encoding();
        uint8_t* data = (uint8_t*)wrapper->Data();

        BaseCall call(data);
        Local<Value> jsResult = Interop::GetResult(context, encoding, &call, true);
        if (wrapper->Value() != nullptr) {
            wrapper->Value()->Reset(isolate, jsResult);
        } else {
            wrapper->SetValue(new Persistent<Value>(isolate, jsResult));
        }

        wrapper->SetData(nullptr);
        wrapper->SetEncoding(nullptr);
        return jsResult;
    }

    if (wrapper->Value() == nullptr) {
        return Local<Value>();
    }

    Local<Value> innerValue = wrapper->Value()->Get(isolate);
    baseWrapper = tns::GetValue(isolate, innerValue);
    if (baseWrapper != nullptr && baseWrapper->Type() == WrapperType::Reference) {
        wrapper = static_cast<ReferenceWrapper*>(baseWrapper);
        if (wrapper->Value() != nullptr) {
            return Reference::GetReferredValue(context, wrapper->Value()->Get(isolate));
        }
    }

    BaseDataWrapper* typeWrapper = wrapper->TypeWrapper();
    if (typeWrapper != nullptr && typeWrapper->Type() == WrapperType::Primitive && baseWrapper != nullptr && baseWrapper->Type() == WrapperType::Pointer) {
        Reference::DataPair pair = GetTypeEncodingDataPair(value.As<Object>());
        if (pair.data_ != nullptr && pair.typeEncoding_ != nullptr) {
            BaseCall call((uint8_t*)pair.data_);
            Local<Value> result = Interop::GetResult(context, pair.typeEncoding_, &call, false);
            return result;
        }
    }

    return innerValue;
}

void* Reference::GetWrappedPointer(Local<Context> context, Local<Value> reference, const TypeEncoding* typeEncoding) {
    if (reference.IsEmpty() || reference->IsNullOrUndefined()) {
        return nullptr;
    }


    Isolate* isolate = context->GetIsolate();
    BaseDataWrapper* wrapper = tns::GetValue(isolate, reference);
    tns::Assert(wrapper != nullptr && wrapper->Type() == WrapperType::Reference, isolate);
    ReferenceWrapper* refWrapper = static_cast<ReferenceWrapper*>(wrapper);
    if (refWrapper->Data() != nullptr) {
        return refWrapper->Data();
    }

    Local<Value> value = refWrapper->Value()->Get(isolate);
    BaseDataWrapper* wrappedValue = tns::GetValue(isolate, value);

    if (wrappedValue == nullptr) {
        BaseDataWrapper* typeWrapper = refWrapper->TypeWrapper();
        if (typeWrapper == nullptr) {
            return nullptr;
        }

        if (typeWrapper->Type() == WrapperType::Primitive) {
            PrimitiveDataWrapper* primitiveWrapper = static_cast<PrimitiveDataWrapper*>(typeWrapper);
            const TypeEncoding* enc = primitiveWrapper->TypeEncoding();
            size_t size = primitiveWrapper->Size();
            void* data = malloc(size);
            Interop::WriteValue(context, enc, data, value);
            refWrapper->SetData(data, true);
            return data;
        }

        if (typeWrapper->Type() != WrapperType::StructType) {
            return nullptr;
        }

        StructTypeWrapper* structTypeWrapper = static_cast<StructTypeWrapper*>(refWrapper->TypeWrapper());

        StructInfo structInfo = structTypeWrapper->StructInfo();
        void* data = malloc(structInfo.FFIType()->size);
        Interop::InitializeStruct(context, data, structInfo.Fields(), value);
        refWrapper->SetData(data, true);
        refWrapper->SetEncoding(typeEncoding);
        return data;
    }

    if (wrappedValue->Type() == WrapperType::ObjCClass) {
        ObjCClassWrapper* classWrapper = static_cast<ObjCClassWrapper*>(wrappedValue);
        void* handle = malloc(sizeof(Class*));
        Class clazz = classWrapper->Klass();
        *static_cast<Class*>(handle) = clazz;
        refWrapper->SetData(handle, true);
        return (Class**)handle;
    }

    if (wrappedValue->Type() == WrapperType::ObjCProtocol) {
        ObjCProtocolWrapper* protoWrapper = static_cast<ObjCProtocolWrapper*>(wrappedValue);
        Protocol* proto = protoWrapper->Proto();
        void* handle = malloc(sizeof(Protocol**));
        *static_cast<Protocol**>(handle) = proto;
        refWrapper->SetData(handle, true);
        return (Protocol**)handle;
    }

    if (wrappedValue->Type() == WrapperType::ObjCObject) {
        ObjCDataWrapper* dataWrapper = static_cast<ObjCDataWrapper*>(wrappedValue);
        id target = dataWrapper->Data();
        void* handle = malloc(sizeof(id));
        *static_cast<id*>(handle) = target;
        refWrapper->SetData(handle, true);
        return (id)handle;
    }

    if (wrappedValue->Type() == WrapperType::Struct) {
        StructWrapper* structWrapper = static_cast<StructWrapper*>(wrappedValue);
        return structWrapper->Data();
    }

    if (wrappedValue->Type() == WrapperType::Pointer) {
        PointerWrapper* pw = static_cast<PointerWrapper*>(wrappedValue);
        void* data = pw->Data();
        return data;
    }

    return nullptr;
}

void Reference::RegisterToStringMethod(Local<Context> context, Local<Object> prototype) {
    Isolate* isolate = context->GetIsolate();
    Local<FunctionTemplate> funcTemplate = FunctionTemplate::New(isolate, [](const FunctionCallbackInfo<Value>& info) {
        Isolate* isolate = info.GetIsolate();
        BaseDataWrapper* wrapper = tns::GetValue(isolate, info.This());
        tns::Assert(wrapper != nullptr && wrapper->Type() == WrapperType::Reference, isolate);
        ReferenceWrapper* refWrapper = static_cast<ReferenceWrapper*>(wrapper);
        Persistent<Value>* value = refWrapper->Value();

        char buffer[100];
        if (value == nullptr) {
            sprintf(buffer, "<Reference: %p>", reinterpret_cast<void*>(0));
        } else {
            sprintf(buffer, "<Reference: %p>", value);
        }

        Local<v8::String> result = tns::ToV8String(isolate, buffer);
        info.GetReturnValue().Set(result);
    });

    Local<v8::Function> func;
    tns::Assert(funcTemplate->GetFunction(context).ToLocal(&func), isolate);

    bool success = prototype->Set(context, tns::ToV8String(isolate, "toString"), func).FromMaybe(false);
    tns::Assert(success, isolate);
}

Reference::DataPair Reference::GetTypeEncodingDataPair(Local<Object> obj) {
    Local<Context> context = obj->CreationContext();
    Isolate* isolate = context->GetIsolate();
    BaseDataWrapper* wrapper = tns::GetValue(isolate, obj);
    tns::Assert(wrapper != nullptr && wrapper->Type() == WrapperType::Reference, isolate);
    ReferenceWrapper* refWrapper = static_cast<ReferenceWrapper*>(wrapper);

    BaseDataWrapper* typeWrapper = refWrapper->TypeWrapper();
    if (typeWrapper == nullptr) {
        // TODO: Missing type when creating the Reference instance
        tns::Assert(false, isolate);
    }

    if (typeWrapper->Type() != WrapperType::Primitive) {
        // TODO: Currently only PrimitiveDataWrappers are supported as type parameters
        // Objective C class classes and structures should also be handled
        tns::Assert(false, isolate);
    }

    PrimitiveDataWrapper* primitiveWrapper = static_cast<PrimitiveDataWrapper*>(typeWrapper);

    Local<Value> value = refWrapper->Value()->Get(isolate);
    BaseDataWrapper* wrappedValue = tns::GetValue(isolate, value);
    if (wrappedValue != nullptr && wrappedValue->Type() == WrapperType::Pointer) {
        const TypeEncoding* typeEncoding = primitiveWrapper->TypeEncoding();
        PointerWrapper* pw = static_cast<PointerWrapper*>(wrappedValue);
        void* data = pw->Data();

        DataPair pair(typeEncoding, data, primitiveWrapper->Size());
        return pair;
    }

    if (refWrapper->Encoding() != nullptr && refWrapper->Data() != nullptr) {
        DataPair pair(refWrapper->Encoding(), refWrapper->Data(), primitiveWrapper->Size());
        return pair;
    }

    tns::Assert(false, isolate);
    return DataPair(nullptr, nullptr, 0);
}

}
