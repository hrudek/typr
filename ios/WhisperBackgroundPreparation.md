# Whisper preparation in the background

Choose Whisper Large V3 Turbo under **Speech engine** and explicitly download it
once. After that, opening Typr automatically prepares the installed, chosen model.
Typr never chooses Whisper for you, switches to another engine, or downloads its
files as part of preparation or background maintenance.

First preparation optimizes Core ML models for this iPhone and can take several
minutes. An iOS/app update or a purged system cache can require optimization again.
Typr checks free storage first. Keep enough free space; the current preparation
estimate is about 4.5 GB beyond the installed files.

## Leaving the app

- On iOS 26+, Typr requests a continued processing task while the app is active.
  Opening the app with an installed, explicitly chosen Whisper model, choosing
  that model, or tapping **Prepare/Try again** starts the work. iOS can show a system
  Live Activity with preparation status and a cancellation control.
- If iOS declines that request, or on iOS 18–25, only UIKit's limited background
  grace time is available. There is no guaranteed number of minutes.
- iOS controls admission, scheduling, memory limits and termination. Locking the
  phone, resource pressure, user cancellation or force quitting can interrupt
  preparation. A continued task is not permission to run indefinitely.
- When expiration is delivered, Typr shows that preparation paused. Reopen Typr or
  tap **Try again** to retry. Force termination cannot deliver a final status.
  Preparation starts again safely; it does not resume a Core ML call halfway
  through. Core ML may reuse completed specialization caches, but Typr cannot
  promise how much work is saved.
- The app shows real stages, not a fabricated percentage or completion time.
  The system task receives five discrete milestones (three component preparations,
  the final load, validation), not an estimate of elapsed time or equally weighted
  Core ML work. Completed stages advance system progress; a long individual Core ML
  stage remains indeterminate in the app. iOS may still stop a slow or stalled task.
- App preparation spinners are replaced by a static indicator while the scene is
  inactive/backgrounded. A continued task grants processing time, not permission to
  keep rendering GPU animation frames.

Typr also requests opportunistic **processing maintenance**, requiring external
power and no network. iOS decides whether and when to launch it (Background App
Refresh settings and system conditions can prevent execution). It only prepares
an installed, selected Whisper model and shares the foreground loader. It never
records, starts a warm microphone/audio session, or creates a second model.
There is **no immediate post-update execution guarantee**: a request must already
have been scheduled by an earlier app session, and iOS may never run it. Open Typr
after an update if you need to prepare the model now. A prepared model in RAM may
be lost when iOS terminates the app even if specialization remains cached.

## Hardware and signing limits

The model configuration uses CPU for audio features and CPU/Neural Engine for the
encoder and decoder. It never requests GPU use. Background GPU execution is a
separate iOS 26 facility requiring supported hardware, `.gpu` in the task's
resource request, and the Background GPU Access entitlement; none is enabled here.
A continued task does not itself grant unrestricted accelerator access.

Apple documents **Background Inference**
(`com.apple.developer.background-tasks.continued-processing.inference`) starting
with iOS 27. It is required for **any** background Neural Engine access, not only
continued tasks. Typr declares it for the containing app only. Distribution and
ad-hoc provisioning profiles must also permit it. The signing pipeline fails
closed if the capability would be missing or stripped. No bundle IDs, App Group,
URL scheme or team are changed. The request uses default resources (zero), **not**
all `supportedResources`. The iOS 27 SDK has no Neural Engine resource bit;
`.gpu` is separate and must not be added just because it is supported.
Core ML can still deny resources or fail; that is
reported as a preparation failure, not a request to download good files again.

Background Inference was enabled and the app profiles replaced in the previous
provisioning task. Signed TestFlight build 0.2.0 (290.1) was verified to carry the
entitlement in both app signature and embedded profile. This does not prove runtime
ANE access or completed tester availability. No capabilities, profiles or secrets
are changed by this fix. Re-provision deliberately if profiles are replaced later.

Preparation emits technical lifecycle and NSError domain/code metadata to the
`dev.rudek.typr` / `WhisperPreparation` unified-log category. It does not log error
descriptions, paths, transcripts or audio. Scoped device diagnosis is still needed
if preparation fails: submission failure, runtime expiration and Core ML failure
are different outcomes and must not be inferred from a failed system status alone.

Simulator tests cover controller lifecycle, eligibility, single-flight preparation,
expiration and engine selection with fakes. They cannot prove background runtime,
system Live Activity behavior, Neural Engine access or provisioning. WhisperKit
forces CPU-only execution in the simulator. Verify these separately on a real
signed iPhone on iOS 26 and iOS 27+, and on older iOS for the UIKit fallback.

## Apple API references checked

- [Performing long-running tasks on iOS and iPadOS](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados): foreground/user-action origin, resource requests, progress and cancellation.
- [BGContinuedProcessingTaskRequest](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequest) and its initializer: iOS 26 availability, foreground submission and concrete identifiers under the permitted wildcard prefix.
- [Task registration](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler/register(fortaskwithidentifier:using:launchhandler:)): launch-time maintenance registration; the iOS 26 SDK `BGTaskScheduler.h` explicitly exempts continued-task registrations from the launch deadline. Each concrete identifier is registered once.
- [UIKit background grace](https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(withname:expirationhandler:)): expiration runs synchronously on the main thread; end the assertion before returning.
- [Choosing background strategies](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app): bounded UIKit grace and discretionary processing tasks.
- [Background Inference](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.background-tasks.continued-processing.inference): iOS 27 availability and Neural Engine restriction.
- [Background GPU resource](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequest/resources/gpu): separate entitlement and hardware limits.
- [Finish tasks in the background, WWDC25](https://developer.apple.com/videos/play/wwdc2025/227/).

SDK header cross-check (public SDK mirror, used to inspect API declarations, not
vendored code): [iPhoneOS26.0 BGTaskScheduler.h](https://github.com/xybp888/iOS-SDKs/blob/master/iPhoneOS26.0.sdk/System/Library/Frameworks/BackgroundTasks.framework/Headers/BGTaskScheduler.h)
and `BGTaskRequest.h` in the same directory. Also cross-checked the
[iOS 27.0 headers](https://github.com/xybp888/iOS-SDKs/tree/master/iPhoneOS27.0.sdk/System/Library/Frameworks/BackgroundTasks.framework/Headers):
`BGTask.h` requires runtime NSProgress reporting and warns stalled tasks may expire;
`BGTaskRequest.h` defines only default and GPU resources. Apple's current documentation is newer
than the iOS 26 SDK; in particular, Background Inference is an iOS 27 requirement.
