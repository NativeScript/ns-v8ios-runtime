# Getting Started

To start diving into the v8 iOS runtime make sure you have XCode and [Homebrew](https://brew.sh/) installed, and then run the following
```bash
# Install CMake
brew install cmake

# Clone repo
git clone https://github.com/NativeScript/ns-v8ios-runtime.git

# Initialize and clone the submodules
cd ns-v8ios-runtime
git submodule update --init

# Open the runtime in XCode
open v8ios.xcodeproj
```

Select the `TestRunner` target and an emulator and hit Run (the play button).

<img width="453" alt="Screenshot 2020-09-09 at 18 25 43" src="https://user-images.githubusercontent.com/879060/92626234-ee627680-f2c9-11ea-941b-6b43600f54e4.png">

This should take a while, but once built the emulator should start and show a black screen (this is normal). In this phase the app will run all the built-in tests, and report the results to the console:
```
Runtime initialization took 55ms
2020-09-09 18:30:37.797265+0200 TestRunner[14285:1238340] CONSOLE LOG: Application Start!
2020-09-09 18:30:38.288740+0200 TestRunner[14285:1238340] No implementation found for exposed method "nonExistingSelector"
2020-09-09 18:30:49.720055+0200 TestRunner[14285:1238340] CONSOLE LOG: SUCCESS: 684 specs, 0 failures, 0 skipped, 0 disabled in 11.81s.
```

If all tests pass, everything is good! At this point you can make changes to the runtime, add breakpoints and step through with the debugger. In the next section we'll see how to attach the runtime to an existing NativeScript application allowing us to debug runtime issues in actual apps.

# Attaching the runtime to a NativeScript app

In the existing app, we need to prepare the XCode project using `ns prepare ios`. This should create a folder named `platforms/ios` and in there a `<appname>.xcworkspace` (if there is no `.xcworkspace` use the `.xcodeproj` instead). Open it in XCode and then drag the `v8ios.xcodeproj` from the `ns-v8ios-runtime` folder under the `<appname>` in the XCode sidebar.

<img width="941" alt="Screenshot 2020-09-09 at 18 46 18" src="https://user-images.githubusercontent.com/879060/92628228-c294c000-f2cc-11ea-8822-58df689d3cd3.png">

Remove the `NativeScript.xcframework` from the General tab, as we will no longer be using the framework from node_modules and instead will use the source directly:

<img width="693" alt="Screenshot 2020-09-09 at 18 47 23" src="https://user-images.githubusercontent.com/879060/92628311-e6f09c80-f2cc-11ea-8977-201517badc3b.png">

Add the `Nativescript.framework` from the v8ios workspace (only required when running on a physical device):

<img width="402" alt="Screen Shot 2021-04-12 at 11 49 10 AM" src="https://user-images.githubusercontent.com/2379994/114423589-51c8c580-9b85-11eb-9d30-eb1cbf73454a.png">


Hitting Run in XCode should start the app in the simulator, and we can now add breakpoints to the runtime and step through it with the debugger. To apply changes to the javascript, make sure you run `ns prepare ios` to re-bundle it into the `platforms/ios` folder.

# Overview

POC showing the [{N} iOS runtime](https://github.com/NativeScript/ios-runtime) running with the V8 engine.

Supported architectures:

 - x86_64
 - arm64

iOS deployment target:
 - 9.0

The `--jitless` mode in which V8 is running is explained in the following [document](https://docs.google.com/document/d/1YYU17VqFMBeSJ8whCqXknOGXtXDVDLulchsTkmi0YdI/edit#heading=h.mz26kq2dsu6k)

# Building V8

In order to build the V8 engine for iOS and produce the static libraries used in this project follow those steps:

1. Get [depot_tools](https://www.chromium.org/developers/how-tos/install-depot-tools)

```
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
export PATH=`pwd`/depot_tools:"$PATH"
```

2. `fetch v8` (this will create a `v8` repo folder automatically checking out the `master` branch)

3. `cd v8; gclient sync` (this will fetch additional dependencies for building the latest revision)

Ensure you navigate back to root of project: `cd ..`

4. Apply patches: `apply_patch.sh`

5. Run `build_v8.sh`

The compiled fat static libraries will be placed inside the `v8/dist` folder.

# Building a Distribution Package

1. Bump the version in package.json
2. Run: `npm run update-version` (*This will update the runtime headers with version info*)
3. Finally build/pack with the following:

```
npm run build
```

This will create: `dist/npm/nativescript-ios-{version}.tgz` NPM package ready for publishing.
