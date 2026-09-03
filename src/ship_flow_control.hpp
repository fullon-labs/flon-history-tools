// copyright defined in LICENSE.txt

#pragma once

#include <cstdint>
#include <stdexcept>

namespace state_history {

inline constexpr uint32_t default_max_messages_in_flight   = 1024;
inline constexpr uint32_t default_ack_batch_size           = 256;
inline constexpr uint32_t max_supported_messages_in_flight = 4096;

class ship_flow_control {
  public:
    ship_flow_control(uint32_t max_messages_in_flight, uint32_t ack_batch_size)
        : max_messages_in_flight_(max_messages_in_flight)
        , ack_batch_size_(ack_batch_size) {
        if (!max_messages_in_flight_ || max_messages_in_flight_ > max_supported_messages_in_flight)
            throw std::runtime_error("--fill-max-messages-in-flight must be between 1 and 4096");
        if (!ack_batch_size_ || ack_batch_size_ > max_messages_in_flight_)
            throw std::runtime_error("--fill-ack-batch-size must be between 1 and --fill-max-messages-in-flight");
    }

    uint32_t max_messages_in_flight() const { return max_messages_in_flight_; }

    uint32_t on_message_processed() {
        ++unacknowledged_messages_;
        if (unacknowledged_messages_ < ack_batch_size_)
            return 0;

        auto acknowledged        = unacknowledged_messages_;
        unacknowledged_messages_ = 0;
        return acknowledged;
    }

    void reset() { unacknowledged_messages_ = 0; }

  private:
    uint32_t max_messages_in_flight_ = {};
    uint32_t ack_batch_size_          = {};
    uint32_t unacknowledged_messages_ = {};
};

} // namespace state_history
