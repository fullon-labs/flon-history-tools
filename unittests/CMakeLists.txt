
find_package(Boost  REQUIRED COMPONENTS unit_test_framework)
add_executable(abieos_sql_converter_tests abieos_sql_converter_tests.cpp ${CMAKE_CURRENT_SOURCE_DIR}/../src/abieos_sql_converter.cpp)
target_include_directories( abieos_sql_converter_tests PRIVATE
                            ${CMAKE_CURRENT_SOURCE_DIR}/../src)
target_link_libraries(abieos_sql_converter_tests flon_abi Boost::unit_test_framework pqxx_static)
add_test(NAME abieos_sql_converter_tests
         COMMAND abieos_sql_converter_tests)

add_executable(ship_flow_control_tests ship_flow_control_tests.cpp)
target_include_directories(ship_flow_control_tests PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../src)
add_test(NAME ship_flow_control_tests
         COMMAND ship_flow_control_tests)
