# Nexys 4 DDR (XC7A100T-1CSG324C) pins used by this project. Checked line by line on 2026-11-12 against
# https://github.com/Digilent/digilent-xdc/blob/master/Nexys-4-DDR-Master.xdc (E3, C12, C4, D4, H17, K15, J13, N14).

# 100 MHz system clock
set_property -dict { PACKAGE_PIN E3  IOSTANDARD LVCMOS33 } [get_ports { CLK100MHZ }]
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports { CLK100MHZ }]

# CPU_RESET push button, active low
set_property -dict { PACKAGE_PIN C12 IOSTANDARD LVCMOS33 } [get_ports { CPU_RESETN }]

# USB-UART bridge (FT2232). Names are from the PC's point of view, like the Digilent XDC:
# UART_TXD_IN is the PC's transmit = FPGA receive, UART_RXD_OUT is the FPGA transmit.
set_property -dict { PACKAGE_PIN C4  IOSTANDARD LVCMOS33 } [get_ports { UART_TXD_IN }]
set_property -dict { PACKAGE_PIN D4  IOSTANDARD LVCMOS33 } [get_ports { UART_RXD_OUT }]

# Status LEDs
set_property -dict { PACKAGE_PIN H17 IOSTANDARD LVCMOS33 } [get_ports { LED[0] }]
set_property -dict { PACKAGE_PIN K15 IOSTANDARD LVCMOS33 } [get_ports { LED[1] }]
set_property -dict { PACKAGE_PIN J13 IOSTANDARD LVCMOS33 } [get_ports { LED[2] }]
set_property -dict { PACKAGE_PIN N14 IOSTANDARD LVCMOS33 } [get_ports { LED[3] }]

# Interface timing: the UART line and the reset button are asynchronous to the clock. Both pass
# through two-flop synchronizers (uart_rx, reset_sync), so they get no input-delay requirement.
# The UART transmit line and the LEDs are read by slow external devices (115200 baud, eyes).
set_false_path -from [get_ports { UART_TXD_IN CPU_RESETN }]
set_false_path -to   [get_ports { UART_RXD_OUT LED[*] }]

set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
