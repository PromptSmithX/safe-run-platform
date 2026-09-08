# Safe Run

Safe Run là một MVP hỗ trợ an toàn cho người chạy bộ sử dụng Apple Watch và
iPhone. Apple Watch thu thập dữ liệu workout, nhịp tim và vị trí; iPhone đóng
vai trò gateway kết nối Internet để chuyển dữ liệu và sự kiện an toàn đến
backend, từ đó hỗ trợ người thân nhận thông báo khi cần.

> **Giới hạn y khoa:** Safe Run là công cụ liên lạc an toàn, không phải thiết bị
> y tế và không chẩn đoán rung nhĩ, đột quỵ hay bất kỳ bệnh lý nào. Các cảnh báo
> chỉ nên mô tả dấu hiệu bất thường, không phản hồi hoặc yêu cầu SOS.

## Trạng thái hiện tại

| Milestone | Nội dung | Trạng thái |
| --- | --- | --- |
| M0 | Bootstrap workspace, targets và domain contracts | `blocked` |
| A | Local Apple Watch workout prototype | `blocked` |
| B | Watch-to-iPhone transport | `blocked` |
| C | Firebase ingestion và iPhone uploader | `blocked` |
| D | Manual SOS và caregiver push | `blocked` |
| E | Check-in và rule sustained heart rate | `blocked` |
| F | Recovery, monitoring và beta hardening | `blocked` |

M0–F đã có source theo chế độ triển khai at-risk, nhưng chưa được xác minh đầy
đủ bằng Firebase Emulator, Xcode, staging/APNs/FCM và thiết bị Apple thật. Exact
next action là chạy `bash Scripts/verify-f.sh` trên macOS, sửa mọi lỗi, rồi hoàn
thành ma trận staging/TestFlight/device trong beta runbook.

## Kiến trúc MVP

- **Apple Watch** là nơi sở hữu vòng đời workout, thu thập HealthKit heart rate,
  GPS và chạy các safety rule.
- **iPhone của người chạy** là Internet gateway. Watch gửi packet sang iPhone;
  iPhone lưu bền vững trước khi ACK và upload lên backend.
- **WatchConnectivity** là kênh Watch → iPhone gần thời gian thực. Workout
  mirroring chỉ phục vụ lifecycle/recovery, không phải transport duy nhất cho
  critical event.
- **Firebase** là backend MVP, gồm Auth, Firestore, Cloud Functions/Cloud Run
  và FCM.
- **Critical events** phải có ID idempotent, durable queue và retry. Chỉ
  telemetry thông thường mới có thể bị coalesced hoặc loại bỏ khi storage bị
  giới hạn.

Các tính năng như Fall Detection, Critical Alerts, ECG streaming, AI/ML
diagnosis, Android caregiver support và direct cellular Watch-to-backend đều
thuộc Phase 2 hoặc ngoài MVP hiện tại.

## Đã triển khai

- Swift package dùng chung `SafeRunDomain` với các domain models Codable,
  sequence và JSON contracts.
- iOS companion tối thiểu trong `Apps/iOS`.
- watchOS app prototype trong `Apps/Watch`.
- `SafeRunWatchCore` với HealthKit workout, live heart rate và Core Location.
- Fake workout/location providers cho simulator và test.
- `RunSessionViewModel` với trạng thái idle, preparing, active, ending, ended
  và failed.
- Một Watch persistence v2 duy nhất cho sequence, durable outbox, check-in và
  crash recovery; migration từ hai file v1 được giữ an toàn.
- iPhone SQLite gateway v3, restart reconciliation, payload scrubbing,
  tombstones và một recovery/upload orchestrator.
- Firebase ingestion, SOS/check-in incident fan-out, dead-man monitor,
  retention sweep, TTL/index configuration và privacy-safe logging.
- Unit tests và source verification cho domain, Watch/iPhone core và backend.

## Chưa xác minh

- Firebase Emulator integration/rules, scheduled monitor và TTL deployment.
- Swift compilation/tests và simulator builds với toolchain Apple.
- HealthKit crash recovery, background transport và queue reconciliation trên thiết bị thật.
- APNs/FCM staging cùng toàn bộ ma trận beta 60/120 phút và 20 SOS.

## Yêu cầu môi trường

Để generate và build các Apple targets cần:

- macOS với Xcode và iOS 17/watchOS 10 SDK tương ứng.
- Swift toolchain đi kèm Xcode.
- XcodeGen `>= 2.46.0`.
- Apple Watch và iPhone thật cho các bài kiểm thử HealthKit, GPS, background
  workout và transport sau này.

Workspace Windows hiện tại chỉ phù hợp để đọc/sửa source và tài liệu. Không thể
chạy Xcode build hoặc xác nhận hành vi trên thiết bị Apple từ Windows.

Kiểm tra phần source/backend có thể chạy bằng `powershell -File
Scripts/verify-f-source.ps1`. Full Firebase Emulator verification trên Windows
cần Node 22 và Java.

## Bắt đầu nhanh trên macOS

### 1. Generate Xcode project

`project.yml` là nguồn cấu hình chính. `SafeRun.xcodeproj` được sinh tự động và
không commit vào repository.

```bash
xcodegen generate --spec project.yml
```

Hoặc dùng script kiểm tra đầy đủ M0:

```bash
bash Scripts/verify-m0.sh
```

### 2. Mở workspace

```bash
open SafeRun.xcworkspace
```

Các scheme chính là `SafeRunApp`, `SafeRunWatchApp` và `SafeRunWatchCore`.

### 3. Chạy domain tests

```bash
swift test --package-path Packages/SafeRunDomain
```

### 4. Kiểm tra Milestone A

Script này chạy kiểm chứng M0 trước, sau đó chạy WatchCore tests và build Watch
app cho watchOS Simulator:

```bash
bash Scripts/verify-a.sh
```

Nếu cần chọn simulator cụ thể:

```bash
SAFERUN_WATCH_DESTINATION="platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)" \
  bash Scripts/verify-a.sh
```

Các script sẽ dừng ngay khi thiếu XcodeGen, Swift/Xcode hoặc khi một bước kiểm
tra thất bại; chúng không tự cài dependency.

## Fake-data mode

Trong Debug, Watch Simulator tự động dùng `FakeWorkoutProvider` và
`FakeLocationProvider`. Khi cần bật rõ ràng bằng launch argument, thêm:

```text
-SafeRunFakeData
```

Release luôn dùng provider thật. Fake mode chỉ phục vụ phát triển và kiểm thử,
không đại diện cho dữ liệu HealthKit hoặc GPS thực tế.

## Cấu trúc repository

```text
.
├── Apps/
│   ├── iOS/                  # iPhone companion
│   └── Watch/                # watchOS composition/UI
├── Apps/WatchCore/           # HealthKit, Core Location, providers, view model
├── Packages/SafeRunDomain/   # Shared Codable domain contracts và tests
├── Scripts/                  # Bootstrap và verification scripts
├── safe_run_mvp_docs/        # Product, architecture, API và test specifications
├── IMPLEMENTATION_PLAN.md    # Execution control plane cho AI/developer
├── SafeRun.xcworkspace       # Workspace được commit
└── project.yml               # XcodeGen source of truth
```

## Tài liệu quan trọng

- [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) — trạng thái milestone,
  locked decisions, exit criteria và handoff cho phiên làm việc tiếp theo.
- [`safe_run_mvp_docs/00_README.md`](safe_run_mvp_docs/00_README.md) — tổng quan
  sản phẩm và bộ tài liệu MVP.
- [`safe_run_mvp_docs/01_PRD_MVP.md`](safe_run_mvp_docs/01_PRD_MVP.md) — product
  requirements và acceptance criteria.
- [`safe_run_mvp_docs/02_ARCHITECTURE.md`](safe_run_mvp_docs/02_ARCHITECTURE.md) —
  kiến trúc và data flow.
- [`safe_run_mvp_docs/04_DATA_CONTRACTS.md`](safe_run_mvp_docs/04_DATA_CONTRACTS.md) —
  DTO, envelope, sequencing và idempotency.
- [`safe_run_mvp_docs/05_API_SPEC.md`](safe_run_mvp_docs/05_API_SPEC.md) — API
  contract.
- [`safe_run_mvp_docs/11_TEST_PLAN.md`](safe_run_mvp_docs/11_TEST_PLAN.md) — test
  matrix và failure injection.
- [`safe_run_mvp_docs/13_ROADMAP.md`](safe_run_mvp_docs/13_ROADMAP.md) — roadmap
  MVP, beta và Phase 2.

## Quy tắc phát triển

Mỗi phiên implement phải làm theo thứ tự:

1. Đọc [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) từ đầu đến cuối.
2. Đọc toàn bộ tài liệu `Read first` của milestone hiện tại.
3. Kiểm tra working tree, source và tests thực tế trước khi thay đổi.
4. Chỉ triển khai đúng milestone hiện tại; không scaffold milestone sau.
5. Chạy verification tương ứng với milestone.
6. Chỉ đổi status sau khi có bằng chứng build, unit test hoặc physical-device
   test đúng với exit criteria.
7. Ghi changed files, verification result, blocker và một exact next action vào
   handoff log.

README này giúp định hướng nhanh; các tài liệu trong `safe_run_mvp_docs/` vẫn là
nguồn sự thật cho product requirements, technical contracts, API và test detail.
