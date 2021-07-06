#include <string>
#include <chrono>
#include "Runtime.h"
#include "Caches.h"
#include "Console.h"
#include "ArgConverter.h"
#include "Interop.h"
#include "NativeScriptException.h"
#include "InlineFunctions.h"
#include "SimpleAllocator.h"
#include "ObjectManager.h"
#include "RuntimeConfig.h"
#include "PromiseProxy.h"
#include "Helpers.h"
#include "TSHelpers.h"
#include "WeakRef.h"
#include "Worker.h"
// #include "SetTimeout.h"

#define STRINGIZE(x) #x
#define STRINGIZE_VALUE_OF(x) STRINGIZE(x)

using namespace v8;
using namespace std;

#include "v8-inspector-platform.h"

namespace tns {

SimpleAllocator allocator_;
NSDictionary* AppPackageJson = nil;

void Runtime::Initialize() {
    MetaFile::setInstance(RuntimeConfig.MetadataPtr);
}

Runtime::Runtime() {
    currentRuntime_ = this;
}

Runtime::~Runtime() {
    this->isolate_->TerminateExecution();

    if (![NSThread isMainThread]) {
        Caches::Workers->Remove(this->workerId_);
        Caches::Remove(this->isolate_);
    } else {
        this->isolate_->Exit();
    }

    Runtime::isolates_.erase(std::remove(Runtime::isolates_.begin(), Runtime::isolates_.end(), this->isolate_), Runtime::isolates_.end());

    this->isolate_->Dispose();

    currentRuntime_ = nullptr;
}

Isolate* Runtime::CreateIsolate() {
    if (!mainThreadInitialized_) {
        Runtime::platform_ = RuntimeConfig.IsDebug
            ? v8_inspector::V8InspectorPlatform::CreateDefaultPlatform()
            : platform::NewDefaultPlatform();

        V8::InitializePlatform(Runtime::platform_.get());
        V8::Initialize();
        std::string flags = RuntimeConfig.IsDebug
            ? "--expose_gc --jitless"
            : "--expose_gc --jitless --no-lazy";
        V8::SetFlagsFromString(flags.c_str(), flags.size());
    }

    Isolate::CreateParams create_params;
    create_params.array_buffer_allocator = &allocator_;
    Isolate* isolate = Isolate::New(create_params);

    Runtime::isolates_.emplace_back(isolate);

    return isolate;
}

void Runtime::Init(Isolate* isolate) {
    std::shared_ptr<Caches> cache = Caches::Get(isolate);
    cache->ObjectCtorInitializer = MetadataBuilder::GetOrCreateConstructorFunctionTemplate;
    cache->StructCtorInitializer = MetadataBuilder::GetOrCreateStructCtorFunction;

    Isolate::Scope isolate_scope(isolate);
    HandleScope handle_scope(isolate);
    Local<FunctionTemplate> globalTemplateFunction = FunctionTemplate::New(isolate);
    globalTemplateFunction->SetClassName(tns::ToV8String(isolate, "NativeScriptGlobalObject"));
    Local<ObjectTemplate> globalTemplate = ObjectTemplate::New(isolate, globalTemplateFunction);
    DefineNativeScriptVersion(isolate, globalTemplate);

    Worker::Init(isolate, globalTemplate, mainThreadInitialized_);
    DefinePerformanceObject(isolate, globalTemplate);
    DefineTimeMethod(isolate, globalTemplate);
    ObjectManager::Init(isolate, globalTemplate);
//    SetTimeout::Init(isolate, globalTemplate);
    MetadataBuilder::RegisterConstantsOnGlobalObject(isolate, globalTemplate, mainThreadInitialized_);

    isolate->SetCaptureStackTraceForUncaughtExceptions(true, 100, StackTrace::kOverview);
    isolate->AddMessageListener(NativeScriptException::OnUncaughtError);

    Local<Context> context = Context::New(isolate, nullptr, globalTemplate);
    context->Enter();

    DefineGlobalObject(context);
    DefineCollectFunction(context);
//    PromiseProxy::Init(context);
    Console::Init(context);
    WeakRef::Init(context);

    this->moduleInternal_ = std::make_unique<ModuleInternal>(context);

    ArgConverter::Init(context, MetadataBuilder::StructPropertyGetterCallback, MetadataBuilder::StructPropertySetterCallback);
    Interop::RegisterInteropTypes(context);

    ClassBuilder::RegisterBaseTypeScriptExtendsFunction(context); // Register the __extends function to the global object
    ClassBuilder::RegisterNativeTypeScriptExtendsFunction(context); // Override the __extends function for native objects
    TSHelpers::Init(context);

    InlineFunctions::Init(context);

    cache->SetContext(context);

    mainThreadInitialized_ = true;

    this->isolate_ = isolate;
}

void Runtime::RunMainScript() {
    Isolate* isolate = this->GetIsolate();
    v8::Locker locker(isolate);
    Isolate::Scope isolate_scope(isolate);
    HandleScope handle_scope(isolate);
    this->moduleInternal_->RunModule(isolate, "./");
}

void Runtime::RunModule(const std::string moduleName) {
    Isolate* isolate = this->GetIsolate();
    Isolate::Scope isolate_scope(isolate);
    HandleScope handle_scope(isolate);
    this->moduleInternal_->RunModule(isolate, moduleName);
}

Isolate* Runtime::GetIsolate() {
    return this->isolate_;
}

const int Runtime::WorkerId() {
    return this->workerId_;
}

void Runtime::SetWorkerId(int workerId) {
    this->workerId_ = workerId;
}

id Runtime::GetAppConfigValue(std::string key) {
    if (AppPackageJson == nil) {
        NSString* packageJsonPath = [[NSString stringWithUTF8String:RuntimeConfig.ApplicationPath.c_str()] stringByAppendingPathComponent:@"package.json"];
        NSData* data = [NSData dataWithContentsOfFile:packageJsonPath];
        AppPackageJson = @{};
        if (data) {
            NSError* error = nil;
            AppPackageJson = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&error];
        }
    }

    id result = AppPackageJson[[NSString stringWithUTF8String:key.c_str()]];
    return result;
}

void Runtime::DefineGlobalObject(Local<Context> context) {
    Isolate* isolate = context->GetIsolate();
    Local<Object> global = context->Global();
    const PropertyAttribute readOnlyFlags = static_cast<PropertyAttribute>(PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);
    if (!global->DefineOwnProperty(context, ToV8String(context->GetIsolate(), "global"), global, readOnlyFlags).FromMaybe(false)) {
        tns::Assert(false, isolate);
    }

    if (mainThreadInitialized_ && !global->DefineOwnProperty(context, ToV8String(context->GetIsolate(), "self"), global, readOnlyFlags).FromMaybe(false)) {
        tns::Assert(false, isolate);
    }
}

void Runtime::DefineCollectFunction(Local<Context> context) {
    Isolate* isolate = context->GetIsolate();
    Local<Object> global = context->Global();
    Local<Value> value;
    bool success = global->Get(context, tns::ToV8String(isolate, "gc")).ToLocal(&value);
    tns::Assert(success, isolate);

    if (value.IsEmpty() || !value->IsFunction()) {
        return;
    }

    Local<v8::Function> gcFunc = value.As<v8::Function>();
    const PropertyAttribute readOnlyFlags = static_cast<PropertyAttribute>(PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);
    success = global->DefineOwnProperty(context, tns::ToV8String(isolate, "__collect"), gcFunc, readOnlyFlags).FromMaybe(false);
    tns::Assert(success, isolate);
}

void Runtime::DefinePerformanceObject(Isolate* isolate, Local<ObjectTemplate> globalTemplate) {
    Local<ObjectTemplate> performanceTemplate = ObjectTemplate::New(isolate);

    Local<FunctionTemplate> nowFuncTemplate = FunctionTemplate::New(isolate, PerformanceNowCallback);
    performanceTemplate->Set(tns::ToV8String(isolate, "now"), nowFuncTemplate);

    Local<v8::String> performancePropertyName = ToV8String(isolate, "performance");
    globalTemplate->Set(performancePropertyName, performanceTemplate);
}

void Runtime::PerformanceNowCallback(const FunctionCallbackInfo<Value>& args) {
    std::chrono::system_clock::time_point now = std::chrono::system_clock::now();
    std::chrono::milliseconds timestampMs = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch());
    double result = timestampMs.count();
    args.GetReturnValue().Set(result);
}

void Runtime::DefineNativeScriptVersion(Isolate* isolate, Local<ObjectTemplate> globalTemplate) {
    const PropertyAttribute readOnlyFlags = static_cast<PropertyAttribute>(PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);
    globalTemplate->Set(ToV8String(isolate, "__runtimeVersion"), ToV8String(isolate, STRINGIZE_VALUE_OF(NATIVESCRIPT_VERSION)), readOnlyFlags);
}

void Runtime::DefineTimeMethod(v8::Isolate* isolate, v8::Local<v8::ObjectTemplate> globalTemplate) {
    Local<FunctionTemplate> timeFunctionTemplate = FunctionTemplate::New(isolate, [](const FunctionCallbackInfo<Value>& info) {
        auto nano = std::chrono::time_point_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now());
        double duration = nano.time_since_epoch().count() / 1000000.0;
        info.GetReturnValue().Set(duration);
    });
    globalTemplate->Set(ToV8String(isolate, "__time"), timeFunctionTemplate);
}

bool Runtime::IsAlive(Isolate* isolate) {
    return std::find(Runtime::isolates_.begin(), Runtime::isolates_.end(), isolate) != Runtime::isolates_.end();
}

std::shared_ptr<Platform> Runtime::platform_;
std::vector<Isolate*> Runtime::isolates_;
bool Runtime::mainThreadInitialized_ = false;
thread_local Runtime* Runtime::currentRuntime_ = nullptr;

}
