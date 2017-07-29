-- This file is part of the ethernet_mac project.
--
-- For the full copyright and license information, please read the
-- LICENSE.md file that was distributed with this source code.

-- Simple testbench for playing around with the CRC calculation code

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.ethernet_types.all;
use work.axi_types.all;


ENTITY axi_ctrl_tb IS
END axi_ctrl_tb;
 
ARCHITECTURE behavior OF axi_ctrl_tb IS 
 
    -- Component Declaration for the Unit Under Test (UUT)
 
    COMPONENT axi_ctrl
    PORT(
		reset					: in    std_ulogic;
		clk						: in std_logic;					-- clock for AXI TX and RX
		-- MAC Transmitter
		mac_tx		     	    : in axi_t;						-- data to tx
		mac_tx_ready			: out std_logic;				-- mac is ready to accept data
		-- MAC Receiver
		mac_rx		         	: out axi_t;					-- data received
		mac_rx_ready			: in  std_logic;				-- tells mac that we have taken data
		-- ethernet MAC layer signals
		-- RX FIFO
		rx_data			       	: in t_ethernet_data;
		rx_rd					: out std_ulogic;
		rx_empty	      		: in std_ulogic;
		-- TX FIFO
		tx_data					: out t_ethernet_data;
		tx_wr					: out std_ulogic
       );
    END COMPONENT;
    

   --Inputs
	signal clk 					: std_logic := '0';
	signal reset 				: std_logic := '0';
	signal mac_tx		   	    : axi_t;
	signal mac_rx_ready			: std_logic := '0';
	signal rx_data		   	    : t_ethernet_data;
	signal rx_empty				: std_logic := '0';
 	--Outputs
	signal mac_tx_ready			: std_logic;
	signal mac_rx 				: axi_t;
	signal rx_rd				: std_logic;
	signal tx_data				: t_ethernet_data;
	signal tx_wr				: std_logic;

   -- Clock period definitions
	constant clk_period : time := 10 ns;

 	type test_t is (RST,T1,T2,T3,T4,T5,T6,T7,T8,T9,T10,T11,T12,T13,DONE);
	signal test				: test_t;

BEGIN
 
	-- Instantiate the Unit Under Test (UUT)
   uut: axi_ctrl PORT MAP (
		reset 				=> reset,
		clk 				=> clk,
		mac_tx 				=> mac_tx,
		mac_tx_ready 		=> mac_tx_ready,
		mac_rx 				=> mac_rx,
		mac_rx_ready		=> mac_rx_ready,
		rx_data		 		=> rx_data,
		rx_rd		 		=> rx_rd,
		rx_empty		 	=> rx_empty,
		tx_data		 		=> tx_data,
		tx_wr		 		=> tx_wr
        );

   -- Clock process definitions
   clk_process :process
   begin
		clk <= '0';
		wait for clk_period/2;
		clk <= '1';
		wait for clk_period/2;
   end process;
 

   -- Stimulus process
   stim_proc: process
   begin	
		test <= RST;
		reset <= '1';
		mac_tx <= empty_axi;
		mac_rx_ready <= '0';
		rx_data <= x"00";
		rx_empty <= '1';
		-- hold reset state for 100 ns.
		wait for 100 ns;
		wait until falling_edge(clk);
		reset <= '0';
		wait for clk_period*5;		
		-- check reset conditions
		assert mac_tx_ready = '1' 								report "mac_tx_ready not initialised correctly on reset" severity error;
		assert mac_rx.valid = '0'						report "mac_rx.valid not initialised correctly on reset" severity error;
		assert rx_rd = '0' 								report "rx_rd not initialised correctly on reset" severity error;
		assert tx_wr = '0' 								report "tx_wr not initialised correctly on reset" severity error;
		wait for clk_period*5;		

      -- insert stimulus here 
		
		------------
		-- TEST 1 -- basic transmit
		------------

		report "T1: TX 4 byte pkt";
		test <= T1;
		mac_tx.valid <= '1';
		mac_tx.data <= x"ff";	wait for clk_period;	-- MAC DST
		mac_tx.data <= x"ff";	wait for clk_period;
		mac_tx.data <= x"ff";	wait for clk_period;
		mac_tx.data <= x"ff";	wait for clk_period;
		mac_tx.data <= x"ff";	wait for clk_period;
		mac_tx.data <= x"ff";	wait for clk_period;
		mac_tx.data <= x"02";	wait for clk_period;	-- MAC SRC
		mac_tx.data <= x"45";	wait for clk_period;
		mac_tx.data <= x"67";	wait for clk_period;
		mac_tx.data <= x"89";	wait for clk_period;
		mac_tx.data <= x"34";	wait for clk_period;
		mac_tx.data <= x"88";	wait for clk_period;
		mac_tx.data <= x"06";	wait for clk_period;	-- ETHERTYPE 1560
		mac_tx.data <= x"18";	wait for clk_period;
		mac_tx.data <= x"01";	wait for clk_period;	-- Payload
		mac_tx.data <= x"02";	wait for clk_period;
		mac_tx.data <= x"03";	wait for clk_period;
		mac_tx.data <= x"04";	
		mac_tx.last <= '1';		wait for clk_period;
		mac_tx <= empty_axi;
		wait for clk_period*100;

		test <= DONE;
		report "--- end of tests ---";
		
      wait;
   end process;

end;

