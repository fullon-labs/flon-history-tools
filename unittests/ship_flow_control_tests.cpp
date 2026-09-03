#define BOOST_TEST_MODULE ship_flow_control
#include <boost/test/included/unit_test.hpp>

#include "ship_flow_control.hpp"

using state_history::ship_flow_control;

BOOST_AUTO_TEST_CASE(replenishes_credits_during_long_stream) {
    constexpr uint32_t window     = 1024;
    constexpr uint32_t batch_size = 256;
    constexpr uint32_t messages   = 10'000;

    ship_flow_control control{window, batch_size};
    uint32_t available_credits = window;
    uint32_t acknowledged      = 0;

    for (uint32_t i = 0; i < messages; ++i) {
        BOOST_REQUIRE(available_credits > 0u);
        --available_credits;

        auto ack = control.on_message_processed();
        available_credits += ack;
        acknowledged += ack;

        BOOST_TEST(available_credits <= window);
    }

    BOOST_TEST(acknowledged == (messages / batch_size) * batch_size);
    BOOST_TEST(available_credits == window - (messages % batch_size));
}

BOOST_AUTO_TEST_CASE(acknowledges_only_complete_batches) {
    ship_flow_control control{8, 3};

    BOOST_TEST(control.on_message_processed() == 0u);
    BOOST_TEST(control.on_message_processed() == 0u);
    BOOST_TEST(control.on_message_processed() == 3u);
    BOOST_TEST(control.on_message_processed() == 0u);

    control.reset();
    BOOST_TEST(control.on_message_processed() == 0u);
}

BOOST_AUTO_TEST_CASE(rejects_invalid_configuration) {
    BOOST_CHECK_THROW(ship_flow_control(0, 1), std::runtime_error);
    BOOST_CHECK_THROW(ship_flow_control(4097, 1), std::runtime_error);
    BOOST_CHECK_THROW(ship_flow_control(1024, 0), std::runtime_error);
    BOOST_CHECK_THROW(ship_flow_control(1024, 1025), std::runtime_error);
}
