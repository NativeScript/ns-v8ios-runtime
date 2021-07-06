#include <Foundation/Foundation.h>
#include <sstream>
#include "Runtime.h"
#include "Interop.h"
#include "ObjectManager.h"
#include "Helpers.h"
#include "ArgConverter.h"
#include "NativeScriptException.h"
#include "DictionaryAdapter.h"
#include "SymbolLoader.h"
#include "ArrayAdapter.h"
#include "NSDataAdapter.h"
#include "Constants.h"
#include "Caches.h"
#include "Reference.h"
#include "Pointer.h"
#include "ExtVector.h"
#include "SymbolIterator.h"
#include "UnmanagedType.h"

using namespace v8;

namespace tns {

static constexpr uint64_t kUint64AllBitsSet = static_cast<uint64_t>(int64_t{-1});
static constexpr int64_t kMinSafeInteger = static_cast<int64_t>(kUint64AllBitsSet << 53) + 1; // -9007199254740991 (-(2^53-1))
static constexpr int64_t kMaxSafeInteger = -kMinSafeInteger; // 9007199254740991 (2^53-1)

Interop::JSBlock::JSBlockDescriptor Interop::JSBlock::kJSBlockDescriptor = {
    .reserved = 0,
    .size = sizeof(JSBlock),
    .copy = [](JSBlock* dst, const JSBlock* src) {
    },
    .dispose = [](JSBlock* block) {
        if (block->descriptor == &JSBlock::kJSBlockDescriptor) {
            MethodCallbackWrapper* wrapper = static_cast<MethodCallbackWrapper*>(block->userData);
            Runtime* runtime = Runtime::GetCurrentRuntime();
            if (runtime != nullptr) {
                Isolate* runtimeIsolate = runtime->GetIsolate();
                v8::Locker locker(runtimeIsolate);
                Isolate::Scope isolate_scope(runtimeIsolate);
                HandleScope handle_scope(runtimeIsolate);
                Local<Value> callback = wrapper->callback_->Get(runtimeIsolate);
                Isolate* isolate = wrapper->isolate_;
                if (Runtime::IsAlive(isolate) && !callback.IsEmpty() && callback->IsObject()) {
                    v8::Locker locker(isolate);
                    Isolate::Scope isolate_scope(isolate);
                    HandleScope handle_scope(isolate);
                    BlockWrapper* blockWrapper = static_cast<BlockWrapper*>(tns::GetValue(isolate, callback));
                    tns::DeleteValue(isolate, callback);
                    wrapper->callback_->Reset();
                    delete blockWrapper;
                }
            }
            delete wrapper;
            ffi_closure_free(block->ffiClosure);
            block->~JSBlock();
        }
    }
};

std::pair<IMP, ffi_closure*> Interop::CreateMethodInternal(const uint8_t initialParamIndex, const uint8_t argsCount, const TypeEncoding* typeEncoding, FFIMethodCallback callback, void* userData) {
    void* functionPointer;
    ffi_closure* closure = static_cast<ffi_closure*>(ffi_closure_alloc(sizeof(ffi_closure), &functionPointer));
    ParametrizedCall* call = ParametrizedCall::Get(typeEncoding, initialParamIndex, initialParamIndex + argsCount);
    ffi_status status = ffi_prep_closure_loc(closure, call->Cif, callback, userData, functionPointer);
    tns::Assert(status == FFI_OK);

    return std::make_pair((IMP)functionPointer, closure);

}

IMP Interop::CreateMethod(const uint8_t initialParamIndex, const uint8_t argsCount, const TypeEncoding* typeEncoding, FFIMethodCallback callback, void* userData) {
    std::pair<IMP, ffi_closure*> result = Interop::CreateMethodInternal(initialParamIndex, argsCount, typeEncoding, callback, userData);
    return result.first;
}

CFTypeRef Interop::CreateBlock(const uint8_t initialParamIndex, const uint8_t argsCount, const TypeEncoding* typeEncoding, FFIMethodCallback callback, void* userData) {
    JSBlock* blockPointer = reinterpret_cast<JSBlock*>(malloc(sizeof(JSBlock)));

    std::pair<IMP, ffi_closure*> result = Interop::CreateMethodInternal(initialParamIndex, argsCount, typeEncoding, callback, userData);

    *blockPointer = {
        .isa = nullptr,
        .flags = JSBlock::BLOCK_HAS_COPY_DISPOSE | JSBlock::BLOCK_NEEDS_FREE | (1 /* ref count */ << 1),
        .reserved = 0,
        .invoke = (void*)result.first,
        .descriptor = &JSBlock::kJSBlockDescriptor,
        .userData = userData,
        .ffiClosure = result.second,
    };

    object_setClass((__bridge id)blockPointer, objc_getClass("__NSMallocBlock__"));

    return CFAutorelease(blockPointer);
}

Local<Value> Interop::CallFunction(CMethodCall& methodCall) {
    return Interop::CallFunctionInternal(methodCall);
}

Local<Value> Interop::CallFunction(ObjCMethodCall& methodCall) {
    return Interop::CallFunctionInternal(methodCall);
}

id Interop::CallInitializer(Local<Context> context, const MethodMeta* methodMeta, id target, Class clazz, V8Args& args) {
    const TypeEncoding* typeEncoding = methodMeta->encodings()->first();
    SEL selector = methodMeta->selector();
    void* functionPointer = (void*)objc_msgSend;

    int initialParameterIndex = 2;
    int argsCount = initialParameterIndex + (int)args.Length();

    ParametrizedCall* parametrizedCall = ParametrizedCall::Get(typeEncoding, initialParameterIndex, argsCount);
    FFICall call(parametrizedCall);

    Interop::SetValue(call.ArgumentBuffer(0), target);
    Interop::SetValue(call.ArgumentBuffer(1), selector);
    Interop::SetFFIParams(context, typeEncoding, &call, argsCount, initialParameterIndex, args);

    ffi_call(parametrizedCall->Cif, FFI_FN(functionPointer), call.ResultBuffer(), call.ArgsArray());

    id result = call.GetResult<id>();

    return result;
}

void Interop::SetFFIParams(Local<Context> context, const TypeEncoding* typeEncoding, FFICall* call, const int argsCount, const int initialParameterIndex, V8Args& args) {
    const TypeEncoding* enc = typeEncoding;
    for (int i = initialParameterIndex; i < argsCount; i++) {
        enc = enc->next();
        Local<Value> arg = args[i - initialParameterIndex];
        void* argBuffer = call->ArgumentBuffer(i);
        Interop::WriteValue(context, enc, argBuffer, arg);
    }
}

bool Interop::isRefTypeEqual(const TypeEncoding* typeEncoding, const char* clazz){
    std::string n(&typeEncoding->details.interfaceDeclarationReference.name.value());
    return n.compare(clazz) == 0;
}

void Interop::WriteValue(Local<Context> context, const TypeEncoding* typeEncoding, void* dest, Local<Value> arg) {
    Isolate* isolate = context->GetIsolate();

    if (arg.IsEmpty() || arg->IsNullOrUndefined()) {
        ffi_type* ffiType = FFICall::GetArgumentType(typeEncoding, true);
        size_t size = ffiType->size;
        memset(dest, 0, size);
    } else if (tns::IsBool(arg) && typeEncoding->type == BinaryTypeEncodingType::InterfaceDeclarationReference && isRefTypeEqual(typeEncoding, "NSNumber")) {
        bool value = tns::ToBool(arg);
        NSNumber *num = [NSNumber numberWithBool: value];
        Interop::SetValue(dest, num);
    } else if (tns::IsBool(arg) && typeEncoding->type == BinaryTypeEncodingType::IdEncoding) {
        bool value = tns::ToBool(arg);
        NSObject* o = @(value);
        Interop::SetValue(dest, o);
    } else if (tns::IsBool(arg)) {
        bool value = tns::ToBool(arg);
        Interop::SetValue(dest, value);
    } else if (tns::IsString(arg) && typeEncoding->type == BinaryTypeEncodingType::SelectorEncoding) {
        std::string str = tns::ToString(isolate, arg);
        NSString* selStr = [NSString stringWithUTF8String:str.c_str()];
        SEL selector = NSSelectorFromString(selStr);
        Interop::SetValue(dest, selector);
    } else if (typeEncoding->type == BinaryTypeEncodingType::CStringEncoding) {
        if (arg->IsString()) {
            v8::String::Utf8Value utf8Value(isolate, arg);
            const char* strCopy = strdup(*utf8Value);
            Interop::SetValue(dest, strCopy);
        } else {
            BaseDataWrapper* wrapper = tns::GetValue(isolate, arg);
            if (wrapper == nullptr) {
                bool isArrayBuffer = false;
                void* data = tns::TryGetBufferFromArrayBuffer(arg, isArrayBuffer);
                if (isArrayBuffer) {
                    Interop::SetValue(dest, data);
                    return;
                }
            }

            tns::Assert(wrapper != nullptr, isolate);
            if (wrapper->Type() == WrapperType::Pointer) {
                PointerWrapper* pw = static_cast<PointerWrapper*>(wrapper);
                void* data = pw->Data();
                Interop::SetValue(dest, data);
            } else if (wrapper->Type() == WrapperType::Reference) {
                ReferenceWrapper* refWrapper = static_cast<ReferenceWrapper*>(wrapper);
                tns::Assert(refWrapper->Value() != nullptr, isolate);
                Local<Value> value = refWrapper->Value()->Get(isolate);
                wrapper = tns::GetValue(isolate, value);
                tns::Assert(wrapper != nullptr && wrapper->Type() == WrapperType::Pointer, isolate);
                PointerWrapper* pw = static_cast<PointerWrapper*>(wrapper);
                void* data = pw->Data();
                Interop::SetValue(dest, data);
            } else {
                // Unsupported wrapprt type for CString
                tns::Assert(false, isolate);
            }
        }
    } else if (arg->IsString() && typeEncoding->type == BinaryTypeEncodingType::UnicharEncoding) {
        v8::String::Utf8Value utf8Value(isolate, arg);
        std::vector<uint16_t> vector = tns::ToVector(*utf8Value);
        if (vector.size() > 1) {
            throw NativeScriptException("Only one character string can be converted to unichar.");
        }
        unichar c = (vector.size() == 0) ? 0 : vector[0];
        Interop::SetValue(dest, c);
    } else if (tns::IsString(arg) && (typeEncoding->type == BinaryTypeEncodingType::InterfaceDeclarationReference || typeEncoding->type == BinaryTypeEncodingType::IdEncoding)) {
        std::string str = tns::ToString(isolate, arg);
        NSString* result = [NSString stringWithUTF8String:str.c_str()];
        Interop::SetValue(dest, result);
    } else if (Interop::IsNumbericType(typeEncoding->type) || tns::IsNumber(arg)) {
        double value = tns::ToNumber(isolate, arg);

        if (typeEncoding->type == BinaryTypeEncodingType::InterfaceDeclarationReference || typeEncoding->type == BinaryTypeEncodingType::IdEncoding) {
            // NSNumber
            NSNumber* num = [NSNumber numberWithDouble:value];
            Interop::SetValue(dest, num);
        } else if (typeEncoding->type == BinaryTypeEncodingType::UShortEncoding) {
            Interop::SetNumericValue<unsigned short>(dest, value);
        } else if (typeEncoding->type == BinaryTypeEncodingType::ShortEncoding) {
            Interop::SetNumericValue<short>(dest, value);
        } else if (typeEncoding->type == BinaryTypeEncodingType::UIntEncoding) {
            Interop::SetNumericValue<unsigned int>(dest, value);
        } else if (typeEncoding->type == BinaryTypeEncodingType::IntEncoding) {
            Interop::SetNumericValue<int>(dest, value);
        } else if (typeEncoding->type == BinaryTypeEncodingType::ULongEncoding) {
            Interop::SetNumericValue<unsigned long>(dest, value);
        } else if (typeEncoding->type == BinaryTypeEncodingType::LongEncoding) {
            Interop::SetNumericValue<long>(dest, value);
        } else if (typeEncoding->type == BinaryTypeEncodingType::ULongLongEncoding) {
            Interop::SetNumericValue<unsigned long long>(dest, value);
        } else if (typeEncoding->type == BinaryTypeEncodingType::LongLongEncoding) {
            Interop::SetNumericValue<long long>(dest, value);
        } else if (typeEncoding->type == BinaryTypeEncodingType::FloatEncoding) {
            Interop::SetNumericValue<float>(dest, value);
        } else if (typeEncoding->type == BinaryTypeEncodingType::DoubleEncoding) {
            Interop::SetNumericValue<double>(dest, value);
        } else if (typeEncoding->type == BinaryTypeEncodingType::UCharEncoding) {
            Interop::SetNumericValue<unsigned char>(dest, value);
        } else if (typeEncoding->type == BinaryTypeEncodingType::CharEncoding) {
            Interop::SetNumericValue<char>(dest, value);
        } else {
            tns::Assert(false, isolate);
        }
    } else if (typeEncoding->type == BinaryTypeEncodingType::ExtVectorEncoding) {
        BaseDataWrapper* wrapper = tns::GetValue(isolate, arg);
        tns::Assert(wrapper != nullptr && wrapper->Type() == WrapperType::ExtVector, isolate);
        ExtVectorWrapper* extVectorWrapper = static_cast<ExtVectorWrapper*>(wrapper);
        void* data = extVectorWrapper->Data();
        size_t size = extVectorWrapper->FFIType()->size;
        memcpy(dest, data, size);
    } else if (typeEncoding->type == BinaryTypeEncodingType::PointerEncoding) {
        const TypeEncoding* innerType = typeEncoding->details.pointer.getInnerType();
        BaseDataWrapper* wrapper = tns::GetValue(isolate, arg);
        if (innerType->type == BinaryTypeEncodingType::VoidEncoding) {
            bool isArrayBuffer = false;
            void* buffer = tns::TryGetBufferFromArrayBuffer(arg, isArrayBuffer);
            if (isArrayBuffer) {
                Interop::SetValue(dest, buffer);
                return;
            }

            tns::Assert(wrapper != nullptr, isolate);

            if (wrapper->Type() == WrapperType::Pointer) {
                PointerWrapper* pointerWrapper = static_cast<PointerWrapper*>(wrapper);
                void* data = pointerWrapper->Data();
                Interop::SetValue(dest, data);
            } else if (wrapper->Type() == WrapperType::Reference) {
                void* data = Reference::GetWrappedPointer(context, arg, typeEncoding);
                Interop::SetValue(dest, data);
            } else {
                // TODO:
                tns::Assert(false, isolate);
            }
        } else {
            void* data = nullptr;

            if (wrapper == nullptr && innerType->type == BinaryTypeEncodingType::StructDeclarationReference) {
                const Meta* meta = ArgConverter::GetMeta(innerType->details.declarationReference.name.valuePtr());
                tns::Assert(meta != nullptr && meta->type() == MetaType::Struct, isolate);
                const StructMeta* structMeta = static_cast<const StructMeta*>(meta);
                StructInfo structInfo = FFICall::GetStructInfo(structMeta);
                data = malloc(structInfo.FFIType()->size);
                Interop::InitializeStruct(context, data, structInfo.Fields(), arg);
            } else {
                if (wrapper == nullptr) {
                    bool isArrayBuffer = false;
                    void* data = tns::TryGetBufferFromArrayBuffer(arg, isArrayBuffer);
                    if (isArrayBuffer) {
                        Interop::SetValue(dest, data);
                        return;
                    }
                }

                tns::Assert(wrapper != nullptr, isolate);

                if (wrapper->Type() == WrapperType::Pointer) {
                    PointerWrapper* pointerWrapper = static_cast<PointerWrapper*>(wrapper);
                    data = pointerWrapper->Data();
                } else if (wrapper->Type() == WrapperType::Reference) {
                    ReferenceWrapper* referenceWrapper = static_cast<ReferenceWrapper*>(wrapper);
                    Local<Value> value = referenceWrapper->Value() != nullptr ? referenceWrapper->Value()->Get(isolate) : Local<Value>();
                    ffi_type* ffiType = FFICall::GetArgumentType(innerType);
                    data = calloc(1, ffiType->size);

                    referenceWrapper->SetData(data, true);
                    referenceWrapper->SetEncoding(innerType);

                    // Initialize the ref/out parameter value before passing it to the function call
                    if (!value.IsEmpty()) {
                        Interop::WriteValue(context, innerType, data, value);
                    }
                } else if (wrapper->Type() == WrapperType::Struct) {
                    StructWrapper* structWrapper = static_cast<StructWrapper*>(wrapper);
                    data = structWrapper->Data();
                } else {
                    tns::Assert(false, isolate);
                }
            }

            Interop::SetValue(dest, data);
        }
    } else if (arg->IsObject() && typeEncoding->type == BinaryTypeEncodingType::FunctionPointerEncoding) {
        BaseDataWrapper* wrapper = tns::GetValue(isolate, arg.As<Object>());
        tns::Assert(wrapper != nullptr, isolate);
        if (wrapper->Type() == WrapperType::Pointer) {
            PointerWrapper* pointerWrapper = static_cast<PointerWrapper*>(wrapper);
            void* data = pointerWrapper->Data();
            Interop::SetValue(dest, data);
        } else if (wrapper->Type() == WrapperType::AnonymousFunction) {
            AnonymousFunctionWrapper* functionWrapper = static_cast<AnonymousFunctionWrapper*>(wrapper);
            void* data = functionWrapper->Data();
            Interop::SetValue(dest, data);
        } else if (wrapper->Type() == WrapperType::FunctionReference) {
            tns::Assert(wrapper != nullptr && wrapper->Type() == WrapperType::FunctionReference, isolate);
            FunctionReferenceWrapper* funcWrapper = static_cast<FunctionReferenceWrapper*>(wrapper);
            const TypeEncoding* functionTypeEncoding = typeEncoding->details.functionPointer.signature.first();
            int argsCount = typeEncoding->details.functionPointer.signature.count - 1;

            Local<Value> callbackValue = funcWrapper->Function()->Get(isolate);
            tns::Assert(callbackValue->IsFunction(), isolate);
            Local<v8::Function> callback = callbackValue.As<v8::Function>();
            std::shared_ptr<Persistent<Value>> poCallback = std::make_shared<Persistent<Value>>(isolate, callback);
            MethodCallbackWrapper* userData = new MethodCallbackWrapper(isolate, poCallback, 0, argsCount, functionTypeEncoding);

            void* functionPointer = (void*)Interop::CreateMethod(0, argsCount, functionTypeEncoding, ArgConverter::MethodCallback, userData);

            funcWrapper->SetData(functionPointer);

            Interop::SetValue(dest, functionPointer);
        } else {
            tns::Assert(false, isolate);
        }
    } else if (arg->IsFunction() && typeEncoding->type == BinaryTypeEncodingType::BlockEncoding) {
        const TypeEncoding* blockTypeEncoding = typeEncoding->details.block.signature.first();
        int argsCount = typeEncoding->details.block.signature.count - 1;

        CFTypeRef blockPtr = nullptr;
        BaseDataWrapper* baseWrapper = tns::GetValue(isolate, arg);
        if (baseWrapper != nullptr && baseWrapper->Type() == WrapperType::Block) {
            BlockWrapper* wrapper = static_cast<BlockWrapper*>(baseWrapper);
            blockPtr = Block_copy(wrapper->Block());
        } else {
            std::shared_ptr<Persistent<Value>> poCallback = std::make_shared<Persistent<Value>>(isolate, arg);
            MethodCallbackWrapper* userData = new MethodCallbackWrapper(isolate, poCallback, 1, argsCount, blockTypeEncoding);
            blockPtr = Interop::CreateBlock(1, argsCount, blockTypeEncoding, ArgConverter::MethodCallback, userData);

            BlockWrapper* wrapper = new BlockWrapper((void*)blockPtr, blockTypeEncoding);
            tns::SetValue(isolate, arg.As<v8::Function>(), wrapper);
        }

        Interop::SetValue(dest, blockPtr);
    } else if (arg->IsObject() && typeEncoding->type == BinaryTypeEncodingType::StructDeclarationReference) {
        Local<Object> obj = arg.As<Object>();
        BaseDataWrapper* wrapper = tns::GetValue(isolate, arg);
        if (wrapper != nullptr) {
            if (wrapper->Type() == WrapperType::Struct) {
                StructWrapper* structWrapper = static_cast<StructWrapper*>(wrapper);
                void* buffer = structWrapper->Data();
                size_t size = structWrapper->StructInfo().FFIType()->size;
                memcpy(dest, buffer, size);
            } else if (wrapper->Type() == WrapperType::Reference) {
                void* data = Reference::GetWrappedPointer(context, arg, typeEncoding);
                tns::Assert(data != nullptr, isolate);
                ffi_type* ffiType = FFICall::GetArgumentType(typeEncoding);
                size_t size = ffiType->size;
                memcpy(dest, data, size);
            } else {
                tns::Assert(false, isolate);
            }
        } else {
            // Create the structure using the struct initializer syntax
            const char* structName = typeEncoding->details.declarationReference.name.valuePtr();
            const Meta* meta = ArgConverter::GetMeta(structName);
            tns::Assert(meta != nullptr && meta->type() == MetaType::Struct, isolate);
            const StructMeta* structMeta = static_cast<const StructMeta*>(meta);
            StructInfo structInfo = FFICall::GetStructInfo(structMeta);
            Interop::InitializeStruct(context, dest, structInfo.Fields(), obj);
        }
    } else if (arg->IsObject() && typeEncoding->type == BinaryTypeEncodingType::AnonymousStructEncoding) {
        Local<Object> obj = arg.As<Object>();
        BaseDataWrapper* wrapper = tns::GetValue(isolate, arg);
        if (wrapper != nullptr && wrapper->Type() == WrapperType::Struct) {
            size_t fieldsCount = typeEncoding->details.anonymousRecord.fieldsCount;
            const TypeEncoding* fieldEncoding = typeEncoding->details.anonymousRecord.getFieldsEncodings();
            const String* fieldNames = typeEncoding->details.anonymousRecord.getFieldNames();
            StructInfo structInfo = FFICall::GetStructInfo(fieldsCount, fieldEncoding, fieldNames);

            StructWrapper* structWrapper = static_cast<StructWrapper*>(wrapper);
            void* data = structWrapper->Data();
            size_t size = structInfo.FFIType()->size;
            memcpy(dest, data, size);
        } else {
            // Anonymous structs can only be initialized with plain javascript objects
            tns::Assert(wrapper == nullptr, isolate);
            size_t fieldsCount = typeEncoding->details.anonymousRecord.fieldsCount;
            const TypeEncoding* fieldEncoding = typeEncoding->details.anonymousRecord.getFieldsEncodings();
            const String* fieldNames = typeEncoding->details.anonymousRecord.getFieldNames();
            StructInfo structInfo = FFICall::GetStructInfo(fieldsCount, fieldEncoding, fieldNames);
            Interop::InitializeStruct(context, dest, structInfo.Fields(), obj);
        }
    } else if (arg->IsFunction() && typeEncoding->type == BinaryTypeEncodingType::ProtocolEncoding) {
        Local<Object> obj = arg.As<Object>();
        BaseDataWrapper* wrapper = tns::GetValue(isolate, obj);
        tns::Assert(wrapper != nullptr && wrapper->Type() == WrapperType::ObjCProtocol, isolate);
        ObjCProtocolWrapper* protoWrapper = static_cast<ObjCProtocolWrapper*>(wrapper);
        Protocol* proto = protoWrapper->Proto();
        Interop::SetValue(dest, proto);
    } else if (arg->IsObject() && typeEncoding->type == BinaryTypeEncodingType::ClassEncoding) {
        Local<Object> obj = arg.As<Object>();
        BaseDataWrapper* wrapper = tns::GetValue(isolate, obj);
        tns::Assert(wrapper != nullptr && wrapper->Type() == WrapperType::ObjCClass, isolate);
        ObjCClassWrapper* classWrapper = static_cast<ObjCClassWrapper*>(wrapper);
        Class clazz = classWrapper->Klass();
        Interop::SetValue(dest, clazz);
    } else if (arg->IsDate()) {
        Local<Date> date = arg.As<Date>();
        double time = date->ValueOf();
        NSDate* nsDate = [NSDate dateWithTimeIntervalSince1970:(time / 1000)];
        Interop::SetValue(dest, nsDate);
    } else if (typeEncoding->type == BinaryTypeEncodingType::IncompleteArrayEncoding) {
        void* data = nullptr;
        if (arg->IsArrayBuffer()) {
            std::shared_ptr<BackingStore> backingStore = arg.As<ArrayBuffer>()->GetBackingStore();
            data = backingStore->Data();
        } else if (arg->IsArrayBufferView()) {
            std::shared_ptr<BackingStore> backingStore = arg.As<ArrayBufferView>()->Buffer()->GetBackingStore();
            data = backingStore->Data();
        } else {
            data = Reference::GetWrappedPointer(context, arg, typeEncoding);
        }
        Interop::SetValue(dest, data);
    } else if (typeEncoding->type == BinaryTypeEncodingType::ConstantArrayEncoding) {
        if (arg->IsArray()) {
            Local<v8::Array> array = arg.As<v8::Array>();
            Local<Context> context = isolate->GetCurrentContext();
            const TypeEncoding* innerType = typeEncoding->details.constantArray.getInnerType();
            ffi_type* ffiType = FFICall::GetArgumentType(innerType);
            uint32_t length = array->Length();
            for (uint32_t i = 0; i < length; i++) {
                Local<Value> element;
                bool success = array->Get(context, i).ToLocal(&element);
                tns::Assert(success, isolate);
                void* ptr = (uint8_t*)dest + i * ffiType->size;
                Interop::WriteValue(context, innerType, ptr, element);
            }
        } else {
            void* data = Reference::GetWrappedPointer(context, arg, typeEncoding);
            Interop::SetValue(dest, data);
        }
    } else if (arg->IsObject()) {
        Local<Object> obj = arg.As<Object>();
        BaseDataWrapper* wrapper = tns::GetValue(isolate, obj);

        if (wrapper != nullptr) {
            if (wrapper->Type() == WrapperType::Enum) {
                EnumDataWrapper* enumWrapper = static_cast<EnumDataWrapper*>(wrapper);
                Local<Context> context = isolate->GetCurrentContext();
                std::string jsCode = enumWrapper->JSCode();
                Local<Script> script;
                if (!Script::Compile(context, tns::ToV8String(isolate, jsCode)).ToLocal(&script)) {
                    tns::Assert(false, isolate);
                }
                tns::Assert(!script.IsEmpty(), isolate);

                Local<Value> result;
                if (!script->Run(context).ToLocal(&result) && !result.IsEmpty()) {
                    tns::Assert(false, isolate);
                }

                tns::Assert(result->IsNumber(), isolate);

                double value = result.As<Number>()->Value();
                SetValue(dest, value);
            } else if (wrapper->Type() == WrapperType::Pointer) {
                PointerWrapper* pointerWrapper = static_cast<PointerWrapper*>(wrapper);
                void* data = pointerWrapper->Data();
                Interop::SetValue(dest, data);
            } else if (wrapper->Type() == WrapperType::ObjCObject) {
                ObjCDataWrapper* objCDataWrapper = static_cast<ObjCDataWrapper*>(wrapper);
                id data = objCDataWrapper->Data();
                Interop::SetValue(dest, data);
            } else if (wrapper->Type() == WrapperType::ObjCClass) {
                ObjCClassWrapper* classWrapper = static_cast<ObjCClassWrapper*>(wrapper);
                id data = classWrapper->Klass();
                Interop::SetValue(dest, data);
            } else {
                tns::Assert(false, isolate);
            }

            return;
        }

        bool isNSArray = false;
        if (typeEncoding->type == BinaryTypeEncodingType::InterfaceDeclarationReference) {
            std::string name = typeEncoding->details.interfaceDeclarationReference.name.valuePtr();
            isNSArray = name == "NSArray";
        }

        if ((obj->IsArrayBuffer() || obj->IsArrayBufferView()) && !isNSArray) {
            Local<ArrayBuffer> buffer = arg.As<ArrayBuffer>();
            NSDataAdapter* adapter = [[NSDataAdapter alloc] initWithJSObject:buffer isolate:isolate];
            Interop::SetValue(dest, adapter);
            CFAutorelease(adapter);
        } else if (tns::IsArrayOrArrayLike(isolate, obj)) {
            Local<v8::Array> array = Interop::ToArray(obj);
            ArrayAdapter* adapter = [[ArrayAdapter alloc] initWithJSObject:array isolate:isolate];
            Interop::SetValue(dest, adapter);
            CFAutorelease(adapter);
        } else {
            DictionaryAdapter* adapter = [[DictionaryAdapter alloc] initWithJSObject:obj isolate:isolate];
            Interop::SetValue(dest, adapter);
            CFAutorelease(adapter);
        }
    } else {
        tns::Assert(false, isolate);
    }
}

id Interop::ToObject(Local<Context> context, v8::Local<v8::Value> arg) {
    Isolate* isolate = context->GetIsolate();
    if (arg.IsEmpty() || arg->IsNullOrUndefined()) {
        return nil;
    } else if (tns::IsString(arg)) {
        std::string value = tns::ToString(isolate, arg);
        NSString* result = [NSString stringWithUTF8String:value.c_str()];
        return result;
    } else if (tns::IsNumber(arg)) {
        double value = tns::ToNumber(isolate, arg);
        return @(value);
    } else if (arg->IsDate()) {
        Local<Date> date = arg.As<Date>();
        double time = date->ValueOf();
        NSDate* nsDate = [NSDate dateWithTimeIntervalSince1970:(time / 1000)];
        return nsDate;
    } else if (tns::IsBool(arg)) {
        bool value = tns::ToBool(arg);
        return @(value);
    } else if (arg->IsArray()) {
        Local<Object> obj = arg.As<Object>();
        ArrayAdapter* adapter = [[ArrayAdapter alloc] initWithJSObject:obj isolate:isolate];
        return adapter;
    } else if (arg->IsObject()) {
        if (BaseDataWrapper* wrapper = tns::GetValue(isolate, arg)) {
            switch (wrapper->Type()) {
                case WrapperType::ObjCObject: {
                    ObjCDataWrapper* wr = static_cast<ObjCDataWrapper*>(wrapper);
                    return wr->Data();
                    break;
                }
                case WrapperType::ObjCClass: {
                    ObjCClassWrapper* wr = static_cast<ObjCClassWrapper*>(wrapper);
                    return wr->Klass();
                    break;
                }
                case WrapperType::ObjCProtocol: {
                    ObjCProtocolWrapper* wr = static_cast<ObjCProtocolWrapper*>(wrapper);
                    return wr->Proto();
                    break;
                }
                default:
                    // TODO: Unsupported object type
                    tns::Assert(false, isolate);
                    break;
            }
        } else {
            Local<Object> obj = arg.As<Object>();
            DictionaryAdapter* adapter = [[DictionaryAdapter alloc] initWithJSObject:obj isolate:isolate];
            CFAutorelease(adapter);
            return adapter;
        }
    }

    // TODO: Handle other possible types
    tns::Assert(false, isolate);
    return nil;
}

Local<Value> Interop::StructToValue(Local<Context> context, void* result, StructInfo structInfo, std::shared_ptr<Persistent<Value>> parentStruct) {
    Isolate* isolate = context->GetIsolate();
    StructWrapper* wrapper = nullptr;
    if (parentStruct == nullptr) {
        ffi_type* ffiType = structInfo.FFIType();
        void* dest = malloc(ffiType->size);
        memcpy(dest, result, ffiType->size);

        wrapper = new StructWrapper(structInfo, dest, nullptr);
    } else {
        Local<Value> parent = parentStruct->Get(isolate);
        BaseDataWrapper* parentWrapper = tns::GetValue(isolate, parent);
        if (parentWrapper != nullptr && parentWrapper->Type() == WrapperType::Struct) {
            StructWrapper* parentStructWrapper = static_cast<StructWrapper*>(parentWrapper);
            parentStructWrapper->IncrementChildren();
        }
        wrapper = new StructWrapper(structInfo, result, parentStruct);
    }

    std::shared_ptr<Caches> cache = Caches::Get(isolate);
    std::pair<void*, std::string> key = std::make_pair(wrapper->Data(), structInfo.Name());
    auto it = cache->StructInstances.find(key);
    if (it != cache->StructInstances.end()) {
        return it->second->Get(isolate);
    }

    Local<Value> res = ArgConverter::ConvertArgument(context, wrapper);
    if (parentStruct == nullptr) {
        std::shared_ptr<Persistent<Value>> poResult = ObjectManager::Register(context, res);
        cache->StructInstances.emplace(key, poResult);
    }
    return res;
}

void Interop::InitializeStruct(Local<Context> context, void* destBuffer, std::vector<StructField> fields, Local<Value> inititalizer) {
    ptrdiff_t position = 0;
    Interop::InitializeStruct(context, destBuffer, fields, inititalizer, position);
}

void Interop::InitializeStruct(Local<Context> context, void* destBuffer, std::vector<StructField> fields, Local<Value> inititalizer, ptrdiff_t& position) {
    Isolate* isolate = context->GetIsolate();
    for (auto it = fields.begin(); it != fields.end(); it++) {
        StructField field = *it;

        Local<Value> value;
        if (!inititalizer.IsEmpty() && !inititalizer->IsNullOrUndefined() && inititalizer->IsObject()) {
            bool success = inititalizer.As<Object>()->Get(context, tns::ToV8String(isolate, field.Name())).ToLocal(&value);
            tns::Assert(success, isolate);
        }

        BinaryTypeEncodingType type = field.Encoding()->type;

        if (type == BinaryTypeEncodingType::StructDeclarationReference) {
            const Meta* meta = ArgConverter::GetMeta(field.Encoding()->details.declarationReference.name.valuePtr());
            tns::Assert(meta != nullptr && meta->type() == MetaType::Struct, isolate);
            const StructMeta* structMeta = static_cast<const StructMeta*>(meta);
            StructInfo nestedStructInfo = FFICall::GetStructInfo(structMeta);
            Interop::InitializeStruct(context, destBuffer, nestedStructInfo.Fields(), value, position);
            position += nestedStructInfo.FFIType()->size;
        } else if (type == BinaryTypeEncodingType::AnonymousStructEncoding) {
            size_t fieldsCount = field.Encoding()->details.anonymousRecord.fieldsCount;
            const TypeEncoding* fieldEncoding = field.Encoding()->details.anonymousRecord.getFieldsEncodings();
            const String* fieldNames = field.Encoding()->details.anonymousRecord.getFieldNames();
            StructInfo nestedStructInfo = FFICall::GetStructInfo(fieldsCount, fieldEncoding, fieldNames);
            ptrdiff_t offset = position + field.Offset();
            uint8_t* dst = (uint8_t*)destBuffer + offset;
            Interop::InitializeStruct(context, dst, nestedStructInfo.Fields(), value, position);
            position += nestedStructInfo.FFIType()->size;
        } else if (type == BinaryTypeEncodingType::ConstantArrayEncoding) {
            const TypeEncoding* innerType = field.Encoding()->details.constantArray.getInnerType();
            ffi_type* ffiType = FFICall::GetArgumentType(innerType);
            uint32_t length = field.Encoding()->details.constantArray.size;
            ptrdiff_t offset = position + field.Offset();

            if (value.IsEmpty()) {
                position += length;
            } else if (value->IsArray()) {
                Local<v8::Array> array = value.As<v8::Array>();
                uint32_t min = std::min(length, array->Length());
                for (uint32_t index = 0; index < min; index++) {
                    Local<Value> element;
                    bool success = array->Get(context, index).ToLocal(&element);
                    tns::Assert(success, isolate);
                    uint8_t* dst = (uint8_t*)destBuffer + offset;
                    Interop::WriteValue(context, innerType, dst, element);
                    offset += ffiType->size;
                }
            } else {
                void* data = Reference::GetWrappedPointer(context, value, field.Encoding());
                if (data != nullptr) {
                    uint8_t* dst = (uint8_t*)destBuffer + offset;
                    memcpy(dst, data, length * ffiType->size);
                }
            }
        } else if (type == BinaryTypeEncodingType::FunctionPointerEncoding) {
            Interop::WriteValue(context, field.Encoding(), destBuffer, value);
        } else if (type == BinaryTypeEncodingType::PointerEncoding) {
            const TypeEncoding* innerType = field.Encoding()->details.pointer.getInnerType();
            Interop::WriteValue(context, innerType, destBuffer, value);
        } else {
            ptrdiff_t offset = position + field.Offset();

            if (type == BinaryTypeEncodingType::UCharEncoding) {
                Interop::SetStructValue<unsigned char>(value, destBuffer, offset);
            } else if (type == BinaryTypeEncodingType::UShortEncoding) {
                Interop::SetStructValue<ushort>(value, destBuffer, offset);
            } else if (type == BinaryTypeEncodingType::ShortEncoding) {
                Interop::SetStructValue<short>(value, destBuffer, offset);
            } else if (type == BinaryTypeEncodingType::UIntEncoding) {
                Interop::SetStructValue<uint>(value, destBuffer, offset);
            } else if (type == BinaryTypeEncodingType::IntEncoding) {
                Interop::SetStructValue<int>(value, destBuffer, offset);
            } else if (type == BinaryTypeEncodingType::ULongEncoding) {
                Interop::SetStructValue<unsigned long>(value, destBuffer, offset);
            } else if (type == BinaryTypeEncodingType::LongEncoding) {
                Interop::SetStructValue<long>(value, destBuffer, offset);
            } else if (type == BinaryTypeEncodingType::ULongLongEncoding) {
                Interop::SetStructValue<unsigned long long>(value, destBuffer, offset);
            } else if (type == BinaryTypeEncodingType::LongLongEncoding) {
                Interop::SetStructValue<long long>(value, destBuffer, offset);
            } else if (type == BinaryTypeEncodingType::FloatEncoding) {
                Interop::SetStructValue<float>(value, destBuffer, offset);
            } else if (type == BinaryTypeEncodingType::DoubleEncoding) {
                Interop::SetStructValue<double>(value, destBuffer, offset);
            } else {
                // TODO: Unsupported struct field encoding
                tns::Assert(false, isolate);
            }
        }
    }
}

template <typename T>
void Interop::SetStructValue(Local<Value> value, void* destBuffer, ptrdiff_t position) {
    double result = !value.IsEmpty() && !value->IsNullOrUndefined() && value->IsNumber()
        ? value.As<Number>()->Value() : 0;
    *static_cast<T*>((void*)((uint8_t*)destBuffer + position)) = result;
}

Local<Value> Interop::GetResult(Local<Context> context, const TypeEncoding* typeEncoding, BaseCall* call, bool marshalToPrimitive, std::shared_ptr<Persistent<Value>> parentStruct, bool isStructMember, bool ownsReturnedObject, bool returnsUnmanaged, bool isInitializer) {
    Isolate* isolate = context->GetIsolate();

    if (returnsUnmanaged) {
        uint8_t* data = call->GetResult<uint8_t*>();
        UnmanagedTypeWrapper* wrapper = new UnmanagedTypeWrapper(data, typeEncoding);
        Local<Value> result = UnmanagedType::Create(context, wrapper);
        return result;
    }

    if (typeEncoding->type == BinaryTypeEncodingType::ExtVectorEncoding) {
        ffi_type* ffiType = FFICall::GetArgumentType(typeEncoding, isStructMember);
        const TypeEncoding* innerTypeEncoding = typeEncoding->details.extVector.getInnerType();
        void* buffer = call->ResultBuffer();
        void* data = malloc(ffiType->size);
        memcpy(data, buffer, ffiType->size);
        Local<Value> value = ExtVector::NewInstance(isolate, data, ffiType, innerTypeEncoding);
        return value;
    }

    if (typeEncoding->type == BinaryTypeEncodingType::StructDeclarationReference) {
        const char* structName = typeEncoding->details.declarationReference.name.valuePtr();
        const Meta* meta = ArgConverter::GetMeta(structName);
        tns::Assert(meta != nullptr && meta->type() == MetaType::Struct, isolate);

        void* result = call->ResultBuffer();

        const StructMeta* structMeta = static_cast<const StructMeta*>(meta);
        StructInfo structInfo = FFICall::GetStructInfo(structMeta, structName);
        Local<Value> value = Interop::StructToValue(context, result, structInfo, parentStruct);
        return value;
    }

    if (typeEncoding->type == BinaryTypeEncodingType::AnonymousStructEncoding) {
        size_t fieldsCount = typeEncoding->details.anonymousRecord.fieldsCount;
        const TypeEncoding* fieldEncoding = typeEncoding->details.anonymousRecord.getFieldsEncodings();
        const String* fieldNames = typeEncoding->details.anonymousRecord.getFieldNames();
        StructInfo structInfo = FFICall::GetStructInfo(fieldsCount, fieldEncoding, fieldNames);
        void* result = call->ResultBuffer();
        Local<Value> value = Interop::StructToValue(context, result, structInfo, parentStruct);
        return value;
    }

    if (typeEncoding->type == BinaryTypeEncodingType::ConstantArrayEncoding) {
        const TypeEncoding* innerType = typeEncoding->details.constantArray.getInnerType();
        ffi_type* innerFFIType = FFICall::GetArgumentType(innerType, isStructMember);
        int length = typeEncoding->details.constantArray.size;
        Local<v8::Array> array = v8::Array::New(isolate, length);

        for (int i = 0; i < length; i++) {
            size_t offset = i * innerFFIType->size;
            BaseCall bc((uint8_t*)call->ResultBuffer(), offset);
            Local<Value> element = Interop::GetResult(context, innerType, &bc, false);
            bool success = array->Set(context, i, element).FromMaybe(false);
            tns::Assert(success, isolate);
        }
        return array;
    }

    if (typeEncoding->type == BinaryTypeEncodingType::SelectorEncoding) {
        SEL result = call->GetResult<SEL>();
        if (result == nil) {
            return Null(isolate);
        }

        NSString* selStr = NSStringFromSelector(result);
        return tns::ToV8String(isolate, [selStr UTF8String]);
    }

    if (typeEncoding->type == BinaryTypeEncodingType::ProtocolEncoding) {
        id result = call->GetResult<id>();
        if (result == nil) {
            return Null(isolate);
        }

        Protocol* protocol = static_cast<Protocol*>(result);
        const ProtocolMeta* protocolMeta = ArgConverter::FindProtocolMeta(protocol);
        if (protocolMeta == nullptr) {
            // Unable to find protocol metadata
            tns::Assert(false, isolate);
        }

        auto cache = Caches::Get(isolate);
        KnownUnknownClassPair pair;
        std::vector<std::string> emptyProtocols;
        cache->ObjectCtorInitializer(context, protocolMeta, pair, emptyProtocols);

        auto it = cache->ProtocolCtorFuncs.find(protocolMeta->name());
        if (it != cache->ProtocolCtorFuncs.end()) {
            return it->second->Get(isolate);
        }

        tns::Assert(false, isolate);
    }

    if (typeEncoding->type == BinaryTypeEncodingType::ClassEncoding) {
        Class result = call->GetResult<Class>();
        if (result == nil) {
            return Null(isolate);
        }

        std::shared_ptr<Caches> cache = Caches::Get(isolate);
        while (true) {
            const char* name = class_getName(result);

            const Meta* meta = ArgConverter::GetMeta(name);
            if (meta != nullptr && (meta->type() == MetaType::Interface || meta->type() == MetaType::ProtocolType)) {
                const BaseClassMeta* baseMeta = static_cast<const BaseClassMeta*>(meta);
                Class knownClass = meta->type() == MetaType::Interface ? objc_getClass(meta->name()) : nil;
                KnownUnknownClassPair pair(knownClass);
                std::vector<std::string> emptyProtocols;
                cache->ObjectCtorInitializer(context, baseMeta, pair, emptyProtocols);
            }

            auto it = cache->CtorFuncs.find(name);
            if (it != cache->CtorFuncs.end()) {
                return it->second->Get(isolate);
            }

            result = class_getSuperclass(result);
            if (!result) {
                break;
            }
        }

        tns::Assert(false, isolate);
    }

    if (typeEncoding->type == BinaryTypeEncodingType::BlockEncoding) {
        JSBlock* block = call->GetResult<JSBlock*>();

        if (block == nullptr) {
            return Null(isolate);
        }

        if (block->descriptor == &JSBlock::kJSBlockDescriptor) {
            MethodCallbackWrapper* wrapper = static_cast<MethodCallbackWrapper*>(block->userData);
            Local<v8::Function> callback = wrapper->callback_->Get(isolate).As<v8::Function>();
            return callback;
        }

        BlockWrapper* blockWrapper = new BlockWrapper(block, typeEncoding);
        Local<External> ext = External::New(isolate, blockWrapper);
        Local<v8::Function> callback;

        CFRetain(block);

        bool success = v8::Function::New(context, [](const FunctionCallbackInfo<Value>& info) {
            Local<External> ext = info.Data().As<External>();
            BlockWrapper* wrapper = static_cast<BlockWrapper*>(ext->Value());

            JSBlock* block = static_cast<JSBlock*>(wrapper->Block());

            const TypeEncoding* typeEncoding = wrapper->Encodings();
            int argsCount = typeEncoding->details.block.signature.count;
            const TypeEncoding* enc = typeEncoding->details.block.signature.first();

            ParametrizedCall* parametrizedCall = ParametrizedCall::Get(enc, 1, argsCount);
            FFICall call(parametrizedCall);

            V8FunctionCallbackArgs args(info);
            Isolate* isolate = info.GetIsolate();
            Local<Context> context = isolate->GetCurrentContext();
            Interop::SetValue(call.ArgumentBuffer(0), block);
            Interop::SetFFIParams(context, enc, &call, argsCount, 1, args);

            ffi_call(parametrizedCall->Cif, FFI_FN(block->invoke), call.ResultBuffer(), call.ArgsArray());

            Local<Value> result = Interop::GetResult(context, enc, &call, true, nullptr);

            info.GetReturnValue().Set(result);
        }, ext).ToLocal(&callback);
        tns::Assert(success, isolate);

        tns::SetValue(isolate, callback, blockWrapper);

        return callback;
    }

    if (typeEncoding->type == BinaryTypeEncodingType::FunctionPointerEncoding) {
        uint8_t* functionPointer = call->GetResult<uint8_t*>();
        if (functionPointer == nullptr) {
            return Null(isolate);
        }

        const TypeEncoding* parametersEncoding = typeEncoding->details.functionPointer.signature.first();
        size_t parametersCount = typeEncoding->details.functionPointer.signature.count;
        AnonymousFunctionWrapper* wrapper = new AnonymousFunctionWrapper(functionPointer, parametersEncoding, parametersCount);
        Local<External> ext = External::New(isolate, wrapper);

        Local<v8::Function> func;
        bool success = v8::Function::New(context, [](const FunctionCallbackInfo<Value>& info) {
            Isolate* isolate = info.GetIsolate();
            AnonymousFunctionWrapper* wrapper = static_cast<AnonymousFunctionWrapper*>(info.Data().As<External>()->Value());
            tns::Assert(wrapper != nullptr, isolate);

            V8FunctionCallbackArgs args(info);
            void* functionPointer = wrapper->Data();
            const TypeEncoding* typeEncoding = wrapper->ParametersEncoding();

            Local<Context> context = isolate->GetCurrentContext();
            CMethodCall methodCall(context, functionPointer, typeEncoding, args, false, false);
            Local<Value> result = Interop::CallFunction(methodCall);

            info.GetReturnValue().Set(result);
        }, ext).ToLocal(&func);
        tns::Assert(success, isolate);

        tns::SetValue(isolate, func, wrapper);
        ObjectManager::Register(context, func);

        return func;
    }

    if (typeEncoding->type == BinaryTypeEncodingType::PointerEncoding) {
        uint8_t* result = call->GetResult<uint8_t*>();
        if (result == nullptr) {
            return Null(isolate);
        }

        const TypeEncoding* innerType = typeEncoding->details.pointer.getInnerType();

        if (innerType->type == BinaryTypeEncodingType::VoidEncoding) {
            Local<Value> instance = Pointer::NewInstance(context, result);
            return instance;
        }

        BaseCall c(result);
        Local<Value> value = Interop::GetResult(context, innerType, &c, true);
        Local<Value> type = Interop::GetInteropType(context, innerType->type);

        std::vector<Local<Value>> args;
        args.push_back(value);
        if (!type.IsEmpty()) {
            args.insert(args.begin(), type);
        }

        Local<Object> instance;
        Local<v8::Function> interopReferenceCtorFunc = Reference::GetInteropReferenceCtorFunc(context);
        bool success = interopReferenceCtorFunc->NewInstance(context, (int)args.size(), args.data()).ToLocal(&instance);
        tns::Assert(success, isolate);

        BaseDataWrapper* wrapper = tns::GetValue(isolate, instance);
        if (wrapper != nullptr && wrapper->Type() == WrapperType::Reference) {
            ReferenceWrapper* refWrapper = static_cast<ReferenceWrapper*>(wrapper);
            refWrapper->SetData(result);
            refWrapper->SetEncoding(innerType);
        }

        return instance;
    }

    if (typeEncoding->type == BinaryTypeEncodingType::InterfaceDeclarationReference ||
        typeEncoding->type == BinaryTypeEncodingType::IdEncoding ||
        typeEncoding->type == BinaryTypeEncodingType::InstanceTypeEncoding) {

        id result = call->GetResult<id>();

        if (result == nil) {
            return Null(isolate);
        }

        if (marshalToPrimitive && result == [NSNull null]) {
            return Null(isolate);
        }

        if ([result isKindOfClass:[@YES class]]) {
            return v8::Boolean::New(isolate, [result boolValue]);
        }

        if (marshalToPrimitive && [result isKindOfClass:[NSDate class]]) {
            double time = [result timeIntervalSince1970] * 1000.0;
            Local<Value> date;
            if (Date::New(context, time).ToLocal(&date)) {
                return date;
            }

            std::ostringstream errorStream;
            errorStream << "Unable to convert " << [result description] << " to a Date object";
            std::string errorMessage = errorStream.str();
            Local<Value> error = Exception::Error(tns::ToV8String(isolate, errorMessage));
            isolate->ThrowException(error);
            return Local<Value>();
        }

        if (marshalToPrimitive && [result isKindOfClass:[NSString class]]) {
            if (typeEncoding->type == BinaryTypeEncodingType::InterfaceDeclarationReference) {
                const char* returnClassName = typeEncoding->details.declarationReference.name.valuePtr();
                Class returnClass = objc_getClass(returnClassName);
                if (returnClass != nil && returnClass == [NSMutableString class]) {
                    marshalToPrimitive = false;
                }
            }

            if (marshalToPrimitive) {
                // Convert NSString instances to javascript strings for all instance method calls
                const char* str = [result UTF8String];
                return tns::ToV8String(isolate, str);
            }
        }

        if (marshalToPrimitive && [result isKindOfClass:[NSNumber class]] && ![result isKindOfClass:[NSDecimalNumber class]]) {
            // Convert NSNumber instances to javascript numbers for all instance method calls
            double value = [result doubleValue];
            return Number::New(isolate, value);
        }

        auto cache = Caches::Get(isolate);
        auto it = cache->Instances.find(result);
        if (it != cache->Instances.end()) {
            return it->second->Get(isolate);
        }

        // For NSProxy we will try to read the metadata from typeEncoding->details.interfaceDeclarationReference.name
        // because class_getSuperclass will directly return NSProxy and thus missing to attach all instance members
        const TypeEncoding* te = [result isProxy] ? typeEncoding : nullptr;

        ObjCDataWrapper* wrapper = new ObjCDataWrapper(result, te);
        std::vector<std::string> additionalProtocols = Interop::GetAdditionalProtocols(typeEncoding);
        Local<Value> jsResult = ArgConverter::ConvertArgument(context, wrapper, false, additionalProtocols);

        if (ownsReturnedObject || isInitializer) {
            [result release];
        }

        if ([result isKindOfClass:[NSArray class]]) {
            // attach Symbol.iterator to the instance
            SymbolIterator::Set(context, jsResult);
        }

        return jsResult;
    }

    return Interop::GetPrimitiveReturnType(context, typeEncoding->type, call);
}

Local<Value> Interop::GetPrimitiveReturnType(Local<Context> context, BinaryTypeEncodingType type, BaseCall* call) {
    Isolate* isolate = context->GetIsolate();
    if (type == BinaryTypeEncodingType::CStringEncoding) {
        unsigned char* result = call->GetResult<unsigned char*>();
        if (result == nullptr) {
            return Null(isolate);
        }

        Local<Value> uint8Type = Interop::GetInteropType(context, BinaryTypeEncodingType::UCharEncoding);
        Local<Value> reference = Reference::FromPointer(context, uint8Type, result);
        return reference;
    }

    if (type == BinaryTypeEncodingType::BoolEncoding) {
        bool result = call->GetResult<bool>();
        return v8::Boolean::New(isolate, result);
    }

    if (type == BinaryTypeEncodingType::UShortEncoding) {
        unsigned short result = call->GetResult<unsigned short>();
        return Number::New(isolate, result);
    }

    if (type == BinaryTypeEncodingType::ShortEncoding) {
        short result = call->GetResult<short>();
        return Number::New(isolate, result);
    }

    if (type == BinaryTypeEncodingType::UIntEncoding) {
        unsigned int result = call->GetResult<unsigned int>();
        return Number::New(isolate, result);
    }

    if (type == BinaryTypeEncodingType::IntEncoding) {
        int result = call->GetResult<int>();
        return Number::New(isolate, result);
    }

    if (type == BinaryTypeEncodingType::ULongEncoding) {
        unsigned long result = call->GetResult<unsigned long>();
        return Number::New(isolate, result);
    }

    if (type == BinaryTypeEncodingType::LongEncoding) {
        long result = call->GetResult<long>();
        return Number::New(isolate, result);
    }

    if (type == BinaryTypeEncodingType::ULongLongEncoding) {
        unsigned long long result = call->GetResult<unsigned long long>();
        if (result > kMaxSafeInteger) {
            return BigInt::NewFromUnsigned(isolate, result);
        }

        return Number::New(isolate, result);
    }

    if (type == BinaryTypeEncodingType::LongLongEncoding) {
        long long result = call->GetResult<long long>();
        if (result < kMinSafeInteger || result > kMaxSafeInteger) {
            return BigInt::New(isolate, result);
        }

        return Number::New(isolate, result);
    }

    if (type == BinaryTypeEncodingType::FloatEncoding) {
        float result = call->GetResult<float>();
        return Number::New(isolate, result);
    }

    if (type == BinaryTypeEncodingType::DoubleEncoding) {
        double result = call->GetResult<double>();
        return Number::New(isolate, result);
    }

    if (type == BinaryTypeEncodingType::UnicharEncoding) {
        unichar result = call->GetResult<unichar>();
        char chars[2];

        if (result > 127) {
            chars[0] = (result >> 8) & (1 << 8) - 1;
            chars[1] = result & (1 << 8) - 1;
        } else {
            chars[0] = result;
            chars[1] = 0;
        }

        return tns::ToV8String(isolate, chars);
    }

    if (type == BinaryTypeEncodingType::UCharEncoding) {
        unsigned char result = call->GetResult<unsigned char>();
        return Number::New(isolate, result);
    }

    if (type == BinaryTypeEncodingType::CharEncoding) {
        char result = call->GetResult<char>();
        return Number::New(isolate, result);
    }

    if (type != BinaryTypeEncodingType::VoidEncoding) {
        tns::Assert(false, isolate);
    }

    // TODO: Handle all the possible return types https://nshipster.com/type-encodings/

    return Local<Value>();
}

std::vector<std::string> Interop::GetAdditionalProtocols(const TypeEncoding* typeEncoding) {
    std::vector<std::string> additionalProtocols;

    if (typeEncoding->type == BinaryTypeEncodingType::IdEncoding && typeEncoding->details.idDetails._protocols.offset > 0) {
        PtrTo<Array<String>> protocols = typeEncoding->details.idDetails._protocols;
        for (auto it = protocols->begin(); it != protocols->end(); it++) {
            const char* protocolName = (*it).valuePtr();
            additionalProtocols.push_back(protocolName);
        }
    } else if (typeEncoding->type == BinaryTypeEncodingType::InterfaceDeclarationReference && typeEncoding->details.interfaceDeclarationReference._protocols.offset > 0) {
        PtrTo<Array<String>> protocols = typeEncoding->details.interfaceDeclarationReference._protocols;
        for (auto it = protocols->begin(); it != protocols->end(); it++) {
            const char* protocolName = (*it).valuePtr();
            additionalProtocols.push_back(protocolName);
        }
    }

    return additionalProtocols;
}

bool Interop::IsNumbericType(BinaryTypeEncodingType type) {
    return
        type == BinaryTypeEncodingType::UCharEncoding ||
        type == BinaryTypeEncodingType::CharEncoding ||
        type == BinaryTypeEncodingType::UShortEncoding ||
        type == BinaryTypeEncodingType::ShortEncoding ||
        type == BinaryTypeEncodingType::UIntEncoding ||
        type == BinaryTypeEncodingType::IntEncoding ||
        type == BinaryTypeEncodingType::ULongEncoding ||
        type == BinaryTypeEncodingType::LongEncoding ||
        type == BinaryTypeEncodingType::ULongLongEncoding ||
        type == BinaryTypeEncodingType::LongLongEncoding ||
        type == BinaryTypeEncodingType::FloatEncoding ||
        type == BinaryTypeEncodingType::DoubleEncoding;
}

void Interop::SetStructPropertyValue(Local<Context> context, StructWrapper* wrapper, StructField field, Local<Value> value) {
    if (value.IsEmpty()) {
        return;
    }

    Isolate* isolate = context->GetIsolate();
    uint8_t* data = (uint8_t*)wrapper->Data();
    uint8_t* destBuffer = data + field.Offset();

    const TypeEncoding* fieldEncoding = field.Encoding();
    switch (fieldEncoding->type) {
        case BinaryTypeEncodingType::StructDeclarationReference: {
            Local<Object> obj = value.As<Object>();
            Local<External> ext = obj->GetInternalField(0).As<External>();
            StructWrapper* targetStruct = static_cast<StructWrapper*>(ext->Value());

            void* sourceBuffer = targetStruct->Data();
            size_t fieldSize = field.FFIType()->size;
            memcpy(destBuffer, sourceBuffer, fieldSize);
            break;
        }
        case BinaryTypeEncodingType::ConstantArrayEncoding: {
            Interop::WriteValue(context, fieldEncoding, destBuffer, value);
            break;
        }
        case BinaryTypeEncodingType::PointerEncoding: {
            BaseDataWrapper* wrapper = tns::GetValue(isolate, value);
            tns::Assert(wrapper != nullptr && wrapper->Type() == WrapperType::Struct, isolate);
            StructWrapper* structWrapper = static_cast<StructWrapper*>(wrapper);
            void* data = structWrapper->Data();
            Interop::SetValue(destBuffer, data);
            break;
        }
        case BinaryTypeEncodingType::UShortEncoding: {
            unsigned short val = value.As<Number>()->Value();
            *static_cast<unsigned short*>((void*)destBuffer) = val;
            break;
        }
        case BinaryTypeEncodingType::ShortEncoding: {
            short val = value.As<Number>()->Value();
            *static_cast<short*>((void*)destBuffer) = val;
            break;
        }
        case BinaryTypeEncodingType::UIntEncoding: {
            unsigned int val = value.As<Number>()->Value();
            *static_cast<unsigned int*>((void*)destBuffer) = val;
            break;
        }
        case BinaryTypeEncodingType::IntEncoding: {
            int val = value.As<Number>()->Value();
            *static_cast<int*>((void*)destBuffer) = val;
            break;
        }
        case BinaryTypeEncodingType::ULongEncoding: {
            unsigned long val = value.As<Number>()->Value();
            *static_cast<unsigned long*>((void*)destBuffer) = val;
            break;
        }
        case BinaryTypeEncodingType::LongEncoding: {
            long val = value.As<Number>()->Value();
            *static_cast<long*>((void*)destBuffer) = val;
            break;
        }
        case BinaryTypeEncodingType::ULongLongEncoding: {
            unsigned long long val = value.As<Number>()->Value();
            *static_cast<unsigned long long*>((void*)destBuffer) = val;
            break;
        }
        case BinaryTypeEncodingType::LongLongEncoding: {
            long long val = value.As<Number>()->Value();
            *static_cast<long long*>((void*)destBuffer) = val;
            break;
        }
        case BinaryTypeEncodingType::FloatEncoding: {
            float val = value.As<Number>()->Value();
            *static_cast<float*>((void*)destBuffer) = val;
            break;
        }
        case BinaryTypeEncodingType::DoubleEncoding: {
            double val = value.As<Number>()->Value();
            *static_cast<double*>((void*)destBuffer) = val;
            break;
        }
        default: {
            // TODO: Handle all possible cases
            tns::Assert(false, isolate);
        }
    }
}

Local<v8::Array> Interop::ToArray(Local<Object> object) {
    if (object->IsArray()) {
        return object.As<v8::Array>();
    }

    Local<Context> context = object->CreationContext();
    Isolate* isolate = context->GetIsolate();

    Local<v8::Function> sliceFunc;
    auto cache = Caches::Get(isolate);
    Persistent<v8::Function>* poSliceFunc = cache->SliceFunc.get();

    if (poSliceFunc != nullptr) {
        sliceFunc = poSliceFunc->Get(isolate);
    } else {
        std::string source = "Array.prototype.slice";
        Local<Context> context = isolate->GetCurrentContext();
        Local<Script> script;
        if (!Script::Compile(context, tns::ToV8String(isolate, source)).ToLocal(&script)) {
            tns::Assert(false, isolate);
        }
        tns::Assert(!script.IsEmpty(), isolate);

        Local<Value> tempSliceFunc;
        if (!script->Run(context).ToLocal(&tempSliceFunc)) {
            tns::Assert(false, isolate);
        }

        tns::Assert(tempSliceFunc->IsFunction(), isolate);
        sliceFunc = tempSliceFunc.As<v8::Function>();
        cache->SliceFunc = std::make_unique<Persistent<v8::Function>>(isolate, sliceFunc);
    }

    Local<Value> sliceArgs[1] { object };

    Local<Value> result;
    bool success = sliceFunc->Call(context, object, 1, sliceArgs).ToLocal(&result);
    tns::Assert(success, isolate);

    return result.As<v8::Array>();
}

Local<Value> Interop::CallFunctionInternal(MethodCall& methodCall) {
    int initialParameterIndex = methodCall.isPrimitiveFunction_ ? 0 : 2;

    int argsCount = initialParameterIndex + (int)methodCall.args_.Length();
    int cifArgsCount = methodCall.provideErrorOutParameter_ ? argsCount + 1 : argsCount;

    ParametrizedCall* parametrizedCall = ParametrizedCall::Get(methodCall.typeEncoding_, initialParameterIndex, cifArgsCount);

    FFICall call(parametrizedCall);

    objc_super sup;

    bool isInstanceMethod = (methodCall.target_ && methodCall.target_ != nil);

    if (initialParameterIndex > 1) {
#if defined(__x86_64__)
        if (methodCall.metaType_ == MetaType::Undefined || methodCall.metaType_ == MetaType::Union || methodCall.metaType_ == MetaType::Struct) {
            const unsigned UNIX64_FLAG_RET_IN_MEM = (1 << 10);

            ffi_type* returnType = FFICall::GetArgumentType(methodCall.typeEncoding_);

            if (returnType->type == FFI_TYPE_LONGDOUBLE) {
                methodCall.functionPointer_ = (void*)objc_msgSend_fpret;
            } else if (returnType->type == FFI_TYPE_STRUCT && (parametrizedCall->Cif->flags & UNIX64_FLAG_RET_IN_MEM)) {
                if (methodCall.callSuper_) {
                    methodCall.functionPointer_ = (void*)objc_msgSendSuper_stret;
                } else {
                    methodCall.functionPointer_ = (void*)objc_msgSend_stret;
                }
            }
        }
#endif

        SEL selector = methodCall.selector_;
        if (isInstanceMethod) {
            NSString* selectorStr = NSStringFromSelector(selector);
            NSString* swizzledMethodSelectorStr = [NSString stringWithFormat:@"%s%@", Constants::SwizzledPrefix.c_str(), selectorStr];
            SEL swizzledMethodSelector = NSSelectorFromString(swizzledMethodSelectorStr);
            if ([methodCall.target_ respondsToSelector:swizzledMethodSelector]) {
                selector = swizzledMethodSelector;
            }

            if (methodCall.callSuper_) {
                sup.receiver = methodCall.target_;
                sup.super_class = class_getSuperclass(object_getClass(methodCall.target_));
                Interop::SetValue(call.ArgumentBuffer(0), &sup);
            } else {
                Interop::SetValue(call.ArgumentBuffer(0), methodCall.target_);
            }
        } else {
            Interop::SetValue(call.ArgumentBuffer(0), methodCall.clazz_);
        }

        Interop::SetValue(call.ArgumentBuffer(1), selector);
    }

    bool isInstanceReturnType = methodCall.typeEncoding_->type == BinaryTypeEncodingType::InstanceTypeEncoding;
    bool marshalToPrimitive = methodCall.isPrimitiveFunction_ || !isInstanceReturnType;

    Interop::SetFFIParams(methodCall.context_, methodCall.typeEncoding_, &call, argsCount, initialParameterIndex, methodCall.args_);

    void* errorRef = nullptr;
    if (methodCall.provideErrorOutParameter_) {
        void* dest = call.ArgumentBuffer(argsCount);
        errorRef = malloc(ffi_type_pointer.size);
        Interop::SetValue(dest, errorRef);
    }

    @try {
        ffi_call(parametrizedCall->Cif, FFI_FN(methodCall.functionPointer_), call.ResultBuffer(), call.ArgsArray());
    } @catch (NSException* e) {
        std::string message = [[e description] UTF8String];
        throw NativeScriptException(message);
    }

    if (errorRef != nullptr) {
        NSError*__strong* errorPtr = (NSError*__strong*)errorRef;
        NSError* error = errorPtr[0];
        std::free(errorRef);
        if (error) {
            throw NativeScriptException([[error localizedDescription] UTF8String]);
        }
    }

    Local<Value> result = Interop::GetResult(
        methodCall.context_,
        methodCall.typeEncoding_,
        &call,
        marshalToPrimitive,
        nullptr,
        false,
        methodCall.ownsReturnedObject_,
        methodCall.returnsUnmanaged_,
        methodCall.isInitializer_);

    return result;
}

}
