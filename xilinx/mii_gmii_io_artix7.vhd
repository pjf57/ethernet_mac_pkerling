-- This file is added to the ethernet_mac projec by Peter Fall
--
-- For the full copyright and license information, please read the
-- LICENSE.md file that was distributed with this source code.

-- IO structure for MII/GMII on Xilinx Artix-7 devices

library ieee;
use ieee.std_logic_1164.all;

library unisim;
use unisim.vcomponents.all;

architecture artix_7 of mii_gmii_io is
	signal gmii_active      : std_ulogic := '0';
	signal clock_tx         : std_ulogic := '0';
	signal clock_tx_inv     : std_ulogic := '1';
	signal clock_mii_rx_io  : std_ulogic := '0';
	signal clock_mii_rx_div : std_ulogic;

	-- IDELAY_VALUE applied to the inputs using IODELAY2
	-- This will need fine-tuning depending on the exact device and the location of the IO pins
	-- The constraints file can be used to override this default value in the fixed_input_delay
	-- instances if needed
	constant MII_RX_INPUT_DELAY : natural := 10;
	signal clock_mii_rx_ibufg   : std_ulogic;
	
--	attribute IODELAY_GROUP : STRING;
--	attribute IODELAY_GROUP of IODEL : label is "IODELAY_1";


begin
	clock_tx_o   <= clock_tx;
	-- Inverter is absorbed into the IOB FF clock inputs
	clock_tx_inv <= not clock_tx;

	-- speed_select_i must be registered so no hazards can reach the BUFGMUX
	with speed_select_i select gmii_active <=
		'1' when SPEED_1000MBPS,
		'0' when others;

	-- Switch between 125 Mhz reference clock and MII_TX_CLK for TX process and register clocking
	-- depending on mode of operation
	-- Asynchronous clock switch-over is required: the MII TX_CLK might not be running any more when
	-- switching to GMII. This means that glitches can occur on the clock and the complete MAC has to 
	-- be reset after a speed change.
	clock_tx_BUFGMUX_inst : BUFGMUX
		generic map(
			CLK_SEL_TYPE => "ASYNC"     -- Glitchles ("SYNC") or fast ("ASYNC") clock switch-over
		)
		port map(
			O  => clock_tx,             -- 1-bit output: Clock buffer output
			I0 => mii_tx_clk_i,         -- 1-bit input: Clock buffer input (S=0)
			I1 => clock_125_i,          -- 1-bit input: Clock buffer input (S=1)
			S  => gmii_active           -- 1-bit input: Clock buffer select
		);

	-- Output clock only when running GMII to reduce switching noise
	-- and avoid outputting a useless 25 MHz clock in MII mode.
	-- Invert clock so that the output values toggle at the falling edge (as seen from the PHY)
	-- and are valid when the clock rises.
	-- The inverse clock is generated by simple inversion. This is not a problem since inverters
	-- are integrated into the ODDR2 clock inputs (no LUT necessary).
	-- Clock enable is not synchronous to clock_tx here, but that shouldn't matter as it
	-- switches only very seldomly. If the setup/hold time is violated, only one or two clock cyles
	-- should be missed. 
	ODDR2_inst : ODDR2
		generic map(
			DDR_ALIGNMENT => "NONE",    -- Sets output alignment to "NONE", "C0", "C1" 
			INIT          => '0',       -- Sets initial state of the Q output to '0' or '1'
			SRTYPE        => "SYNC")    -- Specifies "SYNC" or "ASYNC" set/reset
		port map(
			Q  => gmii_gtx_clk_o,       -- 1-bit output data
			C0 => clock_tx_inv,         -- 1-bit clock input
			C1 => clock_tx,             -- 1-bit clock input
			CE => gmii_active,          -- 1-bit clock enable input
			D0 => '1',                  -- 1-bit data input (associated with C0)
			D1 => '0',                  -- 1-bit data input (associated with C1)
			R  => '0',                  -- 1-bit reset input
			S  => '0'                   -- 1-bit set input
		);

	-- Use FDRE in IOB for output pins to guarantee delay characteristics are identical to the GTX_CLK output.
	-- The registers need to be clocked by clock_tx and not clock_125. Metastability would
	-- ensure otherwise since the TX state machine is clocked by clock_tx and clock_tx/clock_125
	-- have no defined phase relationship.
	mii_tx_en_buffer_inst : entity work.output_buffer
		port map(
			pad_o    => mii_tx_en_o,
			buffer_i => int_mii_tx_en_i,
			clock_i  => clock_tx
		);

	mii_txd_buffer_generate : for i in mii_txd_o'range generate
		mii_txd_buffer_inst : entity work.output_buffer
			port map(
				pad_o    => mii_txd_o(i),
				buffer_i => int_mii_txd_i(i),
				clock_i  => clock_tx
			);
	end generate;

	-- Inserting a delay into the clock path should theoretically allow fine-tuning
	-- of the clock/data offset, but the timing analyzer doesn't like it as very big
	-- IDELAY_VALUE values are necessary that exhibit strong variations. Maybe it works anyway. Try if
	-- the current method fails.
	--	mii_rx_clk_delay_inst : entity work.fixed_input_delay
	--		generic map (
	--			IDELAY_VALUE => 0
	--		)
	--		port map (
	--			pin_i => mii_rx_clk_i,
	--			delayed_o => mii_rx_clk_delayed
	--		); 

	IBUFG_inst : IBUFG
		generic map(
			IBUF_LOW_PWR => FALSE,      -- Low power (TRUE) vs. performance (FALSE) setting for referenced I/O standards
			IOSTANDARD   => "LVCMOS33")
		port map(
			O => clock_mii_rx_ibufg,    -- Clock buffer output
			I => mii_rx_clk_i           -- Clock buffer input (connect directly to top-level port)
		);

	-- Use of a PLL or DCM for RX_CLK is not possible! The clock frequency in 10 Mbps mode (2.5 MHz) 
	-- is below the minimum input frequency of both the PLL and DCM block.
	mii_rx_clk_BUF_inst1 : BUFG
		port map(
			I => clock_mii_rx_ibufg,       -- 1-bit input: Clock buffer input
			O => clock_mii_rx_div          -- 1-bit output: Clock buffer output
		);

	mii_rx_clk_BUF_inst2 : BUFG
		port map(
			I => clock_mii_rx_ibufg,       -- 1-bit input: Clock buffer input
			O => clock_mii_rx_io          -- 1-bit output: Clock buffer output
		);

	mii_rx_clk_BUFG_inst : BUFG
		port map(
			O => clock_rx_o,            -- 1-bit output: Clock buffer output
			I => clock_mii_rx_div       -- 1-bit input: Clock buffer input
		);

	mii_rx_dv_buffer_inst : entity work.input_buffer
		generic map(
			HAS_DELAY    => TRUE,
			IDELAY_VALUE => MII_RX_INPUT_DELAY
		)
		port map(
			pad_i    => mii_rx_dv_i,
			buffer_o => int_mii_rx_dv_o,
			clock_i  => clock_mii_rx_io
		);

	mii_rx_er_buffer_inst : entity work.input_buffer
		generic map(
			HAS_DELAY    => TRUE,
			IDELAY_VALUE => MII_RX_INPUT_DELAY
		)
		port map(
			pad_i    => mii_rx_er_i,
			buffer_o => int_mii_rx_er_o,
			clock_i  => clock_mii_rx_io
		);

	mii_rxd_buffer_generate : for i in mii_rxd_i'range generate
		mii_rxd_buffer_inst : entity work.input_buffer
			generic map(
				HAS_DELAY    => TRUE,
				IDELAY_VALUE => MII_RX_INPUT_DELAY
			)
			port map(
				pad_i    => mii_rxd_i(i),
				buffer_o => int_mii_rxd_o(i),
				clock_i  => clock_mii_rx_io
			);
	end generate;
	

end architecture;
