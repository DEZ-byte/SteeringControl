#include "hid_task.h"

#include <atomic>

#include "esp_timer.h"
#include "freertos/task.h"

#include "config.h"
#include "hid_joystick.h"
#include "status_led.h"

namespace osteer {

OpenSteerJoystick& joystick() {
    static OpenSteerJoystick instance;
    return instance;
}

namespace {

// One slot. `xQueueOverwrite` requires length 1 and never blocks, which is what
// lets the lwIP callback post without any possibility of waiting.
QueueHandle_t gMailbox = nullptr;
TaskHandle_t gTaskHandle = nullptr;

std::atomic<uint32_t> gReportsSent{0};
std::atomic<uint32_t> gReportsFailed{0};
std::atomic<uint32_t> gFailsafeCount{0};
std::atomic<uint8_t> gState{0};

// A ring of packet-to-report intervals, for the console. Fixed size, never
// reallocated.
//
// Recording is one store. The percentile is computed only when somebody asks for
// it, which is a human typing `stats`. Sorting 256 numbers on the report path to
// keep a diagnostic current between two keystrokes would be a poor trade.
constexpr size_t kJitterWindow = 256;
uint32_t gJitter[kJitterWindow];
std::atomic<size_t> gJitterCount{0};
size_t gJitterIndex = 0;

void recordJitter(uint32_t deltaUs) {
    gJitter[gJitterIndex] = deltaUs;
    gJitterIndex = (gJitterIndex + 1) % kJitterWindow;
    const size_t seen = gJitterCount.load(std::memory_order_relaxed);
    if (seen < kJitterWindow) {
        gJitterCount.store(seen + 1, std::memory_order_relaxed);
    }
}

/// Nearest rank, the same rule the Windows daemon's histogram uses, so the two
/// ends of the link report percentiles that can be compared.
///
/// Reads the ring while the HID task may be writing it. That is accepted: every
/// element is a naturally aligned 32-bit word, so a reader sees old or new values
/// but never half of one, and this is a console line rather than a control input.
uint32_t jitterP99Us() {
    const size_t count = gJitterCount.load(std::memory_order_relaxed);
    if (count == 0) {
        return 0;
    }

    uint32_t sorted[kJitterWindow];
    for (size_t i = 0; i < count; i++) {
        sorted[i] = gJitter[i];
    }

    for (size_t i = 1; i < count; i++) {
        const uint32_t key = sorted[i];
        size_t j = i;
        while (j > 0 && sorted[j - 1] > key) {
            sorted[j] = sorted[j - 1];
            j--;
        }
        sorted[j] = key;
    }

    size_t rank = (count * 99 + 99) / 100;
    if (rank > 0) {
        rank -= 1;
    }
    return sorted[rank];
}

void hidTask(void* /*arg*/) {
    Watchdog watchdog;
    ControlState out{};
    JoyReport report{};
    int64_t lastPacketUs = 0;

    for (;;) {
        const int64_t deadlineMs = watchdog.nextDeadlineMs(esp_timer_get_time());
        const TickType_t wait = deadlineMs < 0
                                    ? portMAX_DELAY
                                    : pdMS_TO_TICKS(static_cast<uint32_t>(deadlineMs));

        MailMsg msg;
        const bool gotMail = xQueueReceive(gMailbox, &msg, wait) == pdTRUE;
        const int64_t now = esp_timer_get_time();

        if (gotMail) {
            if (msg.kind == MsgKind::Packet) {
                watchdog.onPacket(now, msg.packet);
                lastPacketUs = now;
            } else {
                watchdog.onLinkDown(now);
            }
        }

        const bool dirty = watchdog.evaluate(now, out);
        gState.store(static_cast<uint8_t>(watchdog.state()), std::memory_order_relaxed);

        WdEvent event;
        if (watchdog.takeEvent(event)) {
            setLedForState(static_cast<uint8_t>(event.to));
            if (event.to == WdState::FailSafe) {
                gFailsafeCount.fetch_add(1, std::memory_order_relaxed);
            }
        }

        if (!dirty) {
            continue;
        }

        report.x = out.steer;
        report.y = out.throttle;
        report.z = out.brake;
        report.rx = out.clutch;
        report.buttons = out.buttons;

        if (joystick().send(report, cfg::kHidSendTimeoutMs)) {
            gReportsSent.fetch_add(1, std::memory_order_relaxed);
            if (gotMail && msg.kind == MsgKind::Packet && lastPacketUs != 0) {
                recordJitter(static_cast<uint32_t>(esp_timer_get_time() - lastPacketUs));
            }
        } else {
            // Not an error worth reacting to. The host may simply not have the
            // interface open yet, and the next report is 8 ms away.
            gReportsFailed.fetch_add(1, std::memory_order_relaxed);
        }
    }
}

}  // namespace

void postMail(const MailMsg& msg) {
    if (gMailbox == nullptr) {
        return;
    }
    // Overwrite, not send. A packet waiting behind another packet is already out
    // of date: it says where the wheel was, not where it is.
    xQueueOverwrite(gMailbox, &msg);
}

bool startHidTask() {
    static_assert(configTICK_RATE_HZ == 1000,
                  "the watchdog deadlines are in milliseconds and need a 1 kHz tick");

    if (gTaskHandle != nullptr) {
        return true;
    }

    gMailbox = xQueueCreate(1, sizeof(MailMsg));
    if (gMailbox == nullptr) {
        return false;
    }

    // Core 1, and near the top of the priority range. Core 0 carries Wi-Fi and
    // lwIP; sharing a core with them is what puts millisecond gaps into a stream
    // that is supposed to arrive every eight.
    const BaseType_t ok = xTaskCreatePinnedToCore(
        hidTask, "osteer-hid", cfg::kHidTaskStackBytes, nullptr,
        configMAX_PRIORITIES - 2, &gTaskHandle, cfg::kHidTaskCore);

    return ok == pdPASS;
}

HidStats readHidStats() {
    HidStats s;
    s.reportsSent = gReportsSent.load(std::memory_order_relaxed);
    s.reportsFailed = gReportsFailed.load(std::memory_order_relaxed);
    s.jitterP99Us = jitterP99Us();
    s.failsafeCount = gFailsafeCount.load(std::memory_order_relaxed);
    s.state = gState.load(std::memory_order_relaxed);
    return s;
}

}  // namespace osteer
