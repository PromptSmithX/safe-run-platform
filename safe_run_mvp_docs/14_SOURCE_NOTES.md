# 14 — Apple API Source Notes

Checked 07/09/2026. These sources are the key reasons behind the architecture.

## HealthKit workout session

Apple Developer — `HKWorkoutSession`

https://developer.apple.com/documentation/healthkit/hkworkoutsession

Key points used:

- workout session tunes sensors for activity;
- all workout sessions generate high-frequency heart-rate samples;
- supports mirroring to companion iOS device and remote-session data.

## Running workout sessions

https://developer.apple.com/documentation/healthkit/running-workout-sessions

Key points:

- active workout session can continue in background;
- watch target needs Workout processing background mode;
- `HKLiveWorkoutBuilderDelegate` receives live metric updates.

## Multidevice workout app

https://developer.apple.com/documentation/healthkit/building-a-multidevice-workout-app

Key point:

- official pattern for mirroring a workout from watchOS to companion iOS app.

## iPhone mirrored-workout launch handler

https://developer.apple.com/documentation/healthkit/hkhealthstore/workoutsessionmirroringstarthandler

Key points:

- system can launch companion iPhone app in background when mirrored workout starts;
- handler may fire multiple times after reconnect, each with a new `HKWorkoutSession` instance.

## Remote workout data delivery caveat

https://developer.apple.com/documentation/healthkit/hkworkoutsessiondelegate/workoutsession(_:didreceivedatafromremoteworkoutsession:)

Key point:

- on iOS, app may be suspended; HealthKit caches incoming data and periodically wakes app, and there may be several minutes between delegate calls.

This is why critical alert traffic should not depend only on workout mirroring.

## WatchConnectivity reachability

https://developer.apple.com/documentation/watchconnectivity/wcsession/isreachable

Key point:

- during workout/high-priority background execution, Watch can be reachable to paired iPhone for live messaging.

## WatchConnectivity sendMessage

https://developer.apple.com/documentation/watchconnectivity/wcsession/sendmessage(_:replyhandler:errorhandler:)

Key point:

- Watch-side call while active can wake corresponding iOS app in background and make it reachable;
- call fails if counterpart is not reachable.

This is why the design includes an explicit persistent retry queue.

## Fall Detection

https://developer.apple.com/documentation/coremotion/cmfalldetectionmanager

https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.health.fall-detection

Key point:

- requires an Apple-granted entitlement and usage description.

## Critical Alerts

https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.usernotifications.critical-alerts

Key point:

- requires entitlement; permits critical sound even when muted/Focus, after app authorization.

## Workout route / CoreLocation

https://developer.apple.com/documentation/healthkit/creating-a-workout-route

Key point:

- route uses CoreLocation and requires location permission; route can be associated with workout if desired.

## watchOS networking testing note

https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos

Key point:

- test watch networking on real devices and varied network environments; simulator can mislead.

## Important interpretation note

Apple APIs provide health/workout data and communication primitives. They do not turn this MVP into a validated arrhythmia/stroke detector. Product language and rule naming should reflect that distinction.
