# Safe Run MVP — bộ tài liệu để vibe code

Phiên bản tài liệu: 0.1 — 07/09/2026

## Mục tiêu

Safe Run là một hệ thống an toàn khi chạy bộ cho người dùng Apple Watch + iPhone. Watch thu thập nhịp tim và vị trí trong lúc workout, phát hiện các **dấu hiệu bất thường theo rule** (không chẩn đoán rung nhĩ hay đột quỵ), hỏi người đeo xác nhận và khi cần sẽ gửi cảnh báo đến iPhone của người thân.

Use case gốc của MVP này:

- Người chạy có Apple Watch Series 10 bản GPS.
- Người chạy mang iPhone theo khi chạy, nên Watch có thể dùng WatchConnectivity để gửi dữ liệu sang iPhone.
- Người thân cài app iOS và nhận push notification khi có alert.
- Ưu tiên độ tin cậy, khả năng kiểm thử và giảm false positive hơn là “AI phát hiện bệnh”.

## Quyết định kiến trúc quan trọng

1. **Watch là nguồn dữ liệu và nơi chạy rule engine.** `HKWorkoutSession` + `HKLiveWorkoutBuilder` được dùng để lấy heart rate tần suất cao trong workout.
2. **WatchConnectivity `sendMessage` là kênh near-realtime Watch → iPhone.** Apple ghi rõ lời gọi từ Watch app đang active/high-priority (ví dụ workout) có thể đánh thức iOS app ở background.
3. **Workout mirroring là kênh lifecycle/recovery, không phải kênh alert chính.** Apple cảnh báo dữ liệu mirrored có thể được iOS nhận theo batch, có lúc cách nhau vài phút khi app bị suspend.
4. **iPhone là Internet gateway.** Nó nhận packet từ Watch rồi gửi HTTPS nhỏ lên backend.
5. **Backend chịu trách nhiệm dedupe, trạng thái session, dead-man timeout và push đến người thân.**
6. **Không dùng ECG streaming.** Public API không cho app bên thứ ba stream ECG liên tục.
7. **Fall Detection và Critical Alerts để Phase 2**, vì cần entitlement riêng từ Apple.

## Bộ tài liệu

| File | Dùng để làm gì |
|---|---|
| `01_PRD_MVP.md` | Product requirements, scope, user stories, acceptance criteria |
| `02_ARCHITECTURE.md` | Kiến trúc tổng thể, data flow, quyết định kỹ thuật |
| `03_STATE_MACHINES.md` | State machine của run, alert, connectivity |
| `04_DATA_CONTRACTS.md` | DTO, telemetry/event schemas, sequencing, idempotency |
| `05_API_SPEC.md` | REST endpoints và auth model |
| `06_WATCHOS_GUIDE.md` | Cấu trúc watchOS app, HealthKit, GPS, WatchConnectivity |
| `07_IOS_GATEWAY_GUIDE.md` | iOS runner gateway + family receiver app |
| `08_BACKEND_FIREBASE.md` | Firebase-oriented backend blueprint |
| `09_ALERT_ENGINE.md` | Rule engine, check-in, escalation, chống false positive |
| `10_SECURITY_PRIVACY.md` | Security, privacy, retention, threat model |
| `11_TEST_PLAN.md` | Test matrix trên thiết bị thật, failure injection |
| `12_VIBE_CODING_PROMPTS.md` | Prompt theo từng milestone để giao cho coding agent |
| `13_ROADMAP.md` | MVP → beta → Phase 2 |
| `14_SOURCE_NOTES.md` | Các nguồn Apple Developer dùng để chốt kiến trúc |
| `openapi.yaml` | Spec máy đọc được cho backend API |
| `schemas/*.json` | JSON Schema cho packet/event/alert |

## Stack khuyến nghị

- watchOS: Swift, SwiftUI, HealthKit, CoreLocation, WatchConnectivity.
- iOS: Swift, SwiftUI, WatchConnectivity, UserNotifications, Firebase SDK.
- Backend: Firebase Auth + Firestore + Cloud Functions 2nd gen (TypeScript) + FCM.
- API ingestion: HTTPS Cloud Function hoặc Cloud Run endpoint.
- Logging/observability: Firebase Crashlytics + structured server logs.

## Cách dùng bộ tài liệu khi vibe code

Đừng yêu cầu agent “build cả app”. Làm theo thứ tự:

1. Tạo workspace/targets và domain models.
2. Làm Watch workout + HR hiển thị tại chỗ.
3. Làm Watch → iPhone connectivity và fake telemetry trước.
4. Làm backend ingestion + simulator endpoint.
5. Nối real HR/GPS.
6. Làm family push.
7. Sau cùng mới bật auto-alert rule.

Mỗi milestone phải có test harness và log rõ ràng trước khi sang bước tiếp theo.

## Giới hạn y khoa

Safe Run MVP **không phải thiết bị y tế**, không tuyên bố phát hiện AF, đột quỵ hay biến cố tim mạch. Alert nên dùng ngôn ngữ như “có dấu hiệu bất thường / không phản hồi / SOS” thay vì “đang rung nhĩ” hay “đang đột quỵ”. Các ngưỡng nhịp tim nên do người dùng/bác sĩ cấu hình, không hard-code một ngưỡng y khoa chung.
