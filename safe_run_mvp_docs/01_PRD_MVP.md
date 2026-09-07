# 01 — PRD: Safe Run MVP

## 1. Problem statement

Một người có tiền sử rung nhĩ vẫn muốn chạy bộ ngoài trời. Khi chạy ở nơi vắng, gia đình muốn biết nhanh nếu người đó:

- chủ động bấm SOS;
- có dấu hiệu sinh lý bất thường trong lúc chạy;
- đột ngột dừng và không phản hồi check-in;
- Watch/iPhone mất kết nối trong lúc session đang active.

MVP phải ưu tiên **phát hiện tình huống cần kiểm tra** hơn là chẩn đoán nguyên nhân y khoa.

## 2. Goals

### Must-have

- Start/stop Safe Run từ Apple Watch.
- Thu HR live bằng HealthKit trong active workout.
- Thu GPS/speed/distance trên Watch.
- Gửi telemetry Watch → iPhone gần realtime.
- iPhone upload backend khi đang ở background.
- Người thân nhận push khi có alert critical.
- Watch hỏi “Bạn ổn chứ?” cho alert tự động trước khi escalate.
- Manual SOS bỏ qua check-in và escalate ngay.
- Backend theo dõi `last_seen` để cảnh báo mất kết nối.
- Lưu audit trail: thời điểm rule trigger, phản hồi người dùng, push đã gửi.

### Should-have

- Family app xem “đang chạy / HR gần nhất / vị trí gần nhất / last seen”.
- Configurable thresholds theo người dùng.
- Local retry buffer trên Watch và iPhone.
- Idempotent API + packet sequence.
- Test mode để inject fake HR/GPS/event.

### Not in MVP

- Chẩn đoán AF từ ECG.
- Streaming ECG.
- AI/ML classifier.
- Tự động gọi cấp cứu.
- Fall Detection entitlement.
- Critical Alerts entitlement.
- Android family app.
- Web dashboard phức tạp.

## 3. Personas

### Runner

- Đeo Apple Watch, mang iPhone theo túi/chạy cùng người.
- Muốn thao tác tối thiểu.
- Cần haptic rõ và nút “Tôi ổn” lớn.

### Caregiver / Family member

- Cài app trên iPhone riêng.
- Muốn nhận cảnh báo có context, không spam.
- Khi mở app cần xem được vị trí cuối cùng, thời điểm, HR gần nhất, trạng thái phản hồi.

## 4. Core user flows

### Flow A — Start run

1. Runner mở Watch app.
2. App kiểm tra HealthKit auth, location auth, paired iPhone, WCSession reachable.
3. Runner nhấn `Bắt đầu chạy`.
4. Watch khởi tạo `HKWorkoutSession(.running)` + builder.
5. Watch gửi `SESSION_START_REQUEST` sang iPhone.
6. iPhone tạo backend run session và trả `session_id` + ingest readiness.
7. Watch hiển thị trạng thái `Đang bảo vệ`.
8. Watch gửi telemetry định kỳ.

Nếu backend chưa tạo được session nhưng workout đã chạy, Watch vẫn tiếp tục local tracking và retry; UI phải cho biết `Đang chờ kết nối`.

### Flow B — Normal run

- HR/GPS cập nhật trên Watch.
- Mỗi 10 giây Watch gửi một packet summary.
- iPhone POST packet lên backend.
- Backend update snapshot; không push người thân.

### Flow C — Automatic anomaly → check-in

1. Rule engine trigger `CHECK_IN_REQUIRED`.
2. Watch rung mạnh + hiển thị countdown 20 giây.
3. Runner chọn:
   - `Tôi ổn` → resolve, log event, cooldown rule.
   - `Gọi người thân` → critical alert ngay.
   - Không phản hồi → critical alert khi countdown hết.
4. iPhone/backend push caregiver.

### Flow D — Manual SOS

1. Runner giữ nút SOS trong ~2 giây hoặc tap + confirm nhanh.
2. Watch gửi `MANUAL_SOS` ngay, không đợi rule engine.
3. iPhone upload.
4. Backend push tất cả caregiver active.
5. Watch tiếp tục gửi HR/GPS và cho phép `Hủy cảnh báo` nếu nhấn nhầm.

### Flow E — Connectivity loss

- Watch không gửi packet lên backend được (qua iPhone) trong ngưỡng timeout.
- Backend session còn active nhưng `last_seen` quá cũ.
- Gửi alert mức `warning` kiểu “Mất cập nhật từ đồng hồ”.
- Không dùng câu “người chạy gặp nguy hiểm” chỉ dựa trên mất kết nối.

## 5. UX requirements

### Watch

Màn hình chính khi chạy chỉ nên có:

- HR lớn.
- elapsed time.
- connection indicator nhỏ.
- nút SOS rõ.

Check-in screen:

- `TÔI ỔN` — button lớn nhất.
- `GỌI NGƯỜI THÂN`.
- countdown.
- haptic lặp theo pattern nhưng không quá dày.

### Family iPhone

Alert notification nên chứa:

- “Safe Run: Bố cần được kiểm tra” / tên do gia đình đặt.
- lý do: `Không phản hồi sau check-in`, `SOS`, `Mất kết nối`.
- thời điểm.
- khi mở app: HR gần nhất, vị trí gần nhất, last_seen, phone call button.

Không để raw medical diagnosis trong notification.

## 6. Non-functional requirements

- Telemetry target: 10 s/packet; event critical gửi ngay.
- End-to-end target trong điều kiện mạng tốt: critical event đến backend trong vài giây và push ngay sau đó. Không hứa SLA y tế.
- Packet phải idempotent.
- Session phải recover sau reconnect.
- Watch battery: tránh gửi 1 packet/giây.
- Data retention mặc định: raw telemetry ngắn hạn; alert/audit dài hơn theo cấu hình.
- Test trên physical Watch + physical iPhone; simulator không đủ cho connectivity/network edge cases.

## 7. Acceptance criteria MVP

Một build được coi là MVP-ready khi hoàn thành các bài test sau:

- HR live chạy ít nhất 60 phút với màn hình Watch tắt/mở bình thường.
- iPhone khóa màn hình vẫn nhận packet từ Watch và upload backend.
- Manual SOS trong 20 lần test đạt 20/20 event được server nhận khi network bình thường.
- Duplicate packet không tạo duplicate alert.
- Rớt Bluetooth 2 phút rồi reconnect không làm session chết.
- Family app nhận 1 alert cho 1 incident, không bị spam mỗi telemetry packet.
- Khi user bấm `Tôi ổn`, incident được resolve và cooldown hoạt động.
- Khi iPhone mất mạng, local queue giữ được packet/event và flush khi có mạng lại.
