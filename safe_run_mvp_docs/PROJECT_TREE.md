# Suggested project tree

```text
SafeRun/
├── SafeRun.xcworkspace
├── Shared/
│   ├── Domain/
│   │   ├── TelemetryEnvelope.swift
│   │   ├── TelemetryPayload.swift
│   │   ├── SafetyEvent.swift
│   │   ├── RunnerSafetyConfig.swift
│   │   └── RunState.swift
│   └── Tests/
├── WatchApp/
│   ├── App/
│   ├── Workout/
│   │   ├── WorkoutManager.swift
│   │   └── HealthKitAuthorizer.swift
│   ├── Location/
│   │   └── WatchLocationService.swift
│   ├── Safety/
│   │   ├── SafetyRuleEngine.swift
│   │   ├── CheckInCoordinator.swift
│   │   └── Rules/
│   ├── Transport/
│   │   ├── WatchConnectivityTransport.swift
│   │   └── WatchRetryQueue.swift
│   ├── Persistence/
│   ├── UI/
│   └── Tests/
├── iOSApp/
│   ├── App/
│   ├── WatchBridge/
│   │   ├── PhoneWatchBridge.swift
│   │   └── RemoteWorkoutCoordinator.swift
│   ├── Gateway/
│   │   ├── GatewayQueue.swift
│   │   ├── GatewayWorker.swift
│   │   └── SessionAPIClient.swift
│   ├── Auth/
│   ├── Notifications/
│   ├── Family/
│   ├── Runner/
│   └── Tests/
└── backend/
    ├── functions/
    │   ├── src/
    │   │   ├── api/
    │   │   ├── auth/
    │   │   ├── incidents/
    │   │   ├── notifications/
    │   │   └── scheduler/
    │   └── test/
    ├── firestore.rules
    └── firebase.json
```
