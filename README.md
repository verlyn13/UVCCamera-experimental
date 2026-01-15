# uvccamera-experimental

> **⚠️ This is a SANDBOX repository for testing UVC library improvements.**
>
> This fork is used for isolated development and testing of libuvc/libusb changes
> before they are promoted to [scopecam-engine](../scopecam-engine) via patches.
>
> **This repository does NOT produce production binaries.**

---

## Purpose

This repository serves as a **testing ground** for UVC library improvements:

| What It Does | What It Does NOT Do |
|--------------|---------------------|
| ✅ Test libuvc changes in isolation | ❌ Produce binaries for scopecam-engine |
| ✅ Validate PTS/SCR timestamp extraction | ❌ Sync .so files to other projects |
| ✅ Prototype GET_INFO compliance | ❌ Serve as a build dependency |
| ✅ Debug USB camera issues | ❌ Replace scopecam-engine's native code |

## Current Development Focus

- [ ] **Phase 0**: PTS/SCR timestamp extraction in libuvc
- [ ] **Phase 1**: GET_INFO function compliance
- [ ] **Phase 2**: Clock synchronizer prototype

See [docs/status/IMPLEMENTATION-STATUS.md](docs/status/IMPLEMENTATION-STATUS.md) for detailed progress.

## Promotion Workflow

When changes are validated here, they are promoted to scopecam-engine via **patches**:

```bash
# 1. Create a patch from your changes
cd lib/src/main/jni/libuvc
git diff > ~/patches/libuvc-my-feature.patch

# 2. Document the change
# 3. Submit patch to scopecam-engine for review
```

See [docs/PROMOTION_WORKFLOW.md](docs/PROMOTION_WORKFLOW.md) for the full workflow.

---

## Upstream: UVCCamera

[![GitHub Repo stars](https://img.shields.io/github/stars/alexey-pelykh/UVCCamera?style=flat&logo=github)](https://github.com/alexey-pelykh/UVCCamera)
[![GitHub License](https://img.shields.io/github/license/alexey-pelykh/UVCCamera)](./LICENSE.md)
[![Maven Central Version](https://img.shields.io/maven-central/v/org.uvccamera/lib)](https://mvnrepository.com/artifact/org.uvccamera/lib)
[![Pub Version](https://img.shields.io/pub/v/uvccamera)](https://pub.dev/packages/uvccamera)

A USB Video Class (UVC) camera library for Android and a plugin for Flutter.

This project is a hard fork of the original [UVCCamera by saki4510t](https://github.com/saki4510t/UVCCamera) and is
brought to you by [Alexey Pelykh](https://alexey-pelykh.com) with a great gratitude to the original project's
author [saki4510t](https://github.com/saki4510t/) and its community of contributors. It includes some improvements from
the original project's forks and PRs.

## Usage

### Android library

The library is available on Maven Central. To use it in your project, add the following dependency:

either to your `build.gradle` file in the `dependencies` block:

```groovy
implementation 'org.uvccamera:lib:0.1.0'
```

or to your `build.gradle.kts` file in the `dependencies` block:

```kotlin
implementation("org.uvccamera:lib:0.1.0")
```

### Flutter plugin

The Flutter plugin is available on [pub.dev](https://pub.dev/packages/uvccamera). To use it in your Flutter project, add
the following dependency:

```yaml
dependencies:
  uvccamera: ^0.1.0
```

See the [Flutter example](https://pub.dev/packages/uvccamera/example) for an app that uses the plugin.

## Development & Contribution

This section describes how to build the Android library and the Flutter plugin from the source code locally.

See the [DEVELOPMENT.md](./DEVELOPMENT.md) for branch strategy and workflow details.

For detailed architecture and API documentation, see the [docs/](./docs/) folder.

### Building Android library

The Android library is built using Gradle. To build the library, run the following command:

```shell
./gradlew :lib:assembleRelease
```

There are number of test applications available.

### Building Flutter plugin example

A prerequisite for building the Flutter plugin example locally is to have the Android library built and published to the
machine's local Maven repository. To publish the library to the local Maven repository, run the following command:

```shell
./gradlew :lib:publishToMavenLocal
```

After that, you can build the Flutter plugin example by running the following command:

```shell
cd flutter/example
flutter build apk
```

## License

The original license applies to the relevant parts of this project as well:

> Copyright (c) 2014-2017 saki t_saki@serenegiant.com
>
> Licensed under the Apache License, Version 2.0 (the "License");
> you may not use this file except in compliance with the License.
> You may obtain a copy of the License at
>
>     http://www.apache.org/licenses/LICENSE-2.0
>
> Unless required by applicable law or agreed to in writing, software
> distributed under the License is distributed on an "AS IS" BASIS,
> WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
> See the License for the specific language governing permissions and
> limitations under the License.
>
> All files in the folder are under this Apache License, Version 2.0.
> Files in the jni/libjpeg, jni/libusb and jin/libuvc folders may have a different license,
> see the respective files.

Some dependencies may have different licenses, so please check the dependencies' licenses before using this project.

## Upstreams

Most of the contributions picked from the original project's forks and PRs are attributed to the respective authors in
the commit messages and stored or referenced in the [upstreams](./upstreams) folder.
