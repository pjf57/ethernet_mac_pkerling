-- This file is part of the ethernet_mac project.
--
-- Added by Peter Fall
-- provides optimised AXI interface, but not currently working.
--
-- For the full copyright and license information, please read the
-- LICENSE.md file that was distributed with this source code.

-- Prebuilt Ethernet MAC with FIFOs connected

library ieee;
use ieee.std_logic_1164.all;
use IEEE.NUMERIC_STD.ALL;
use work.ethernet_types.all;
use work.miim_types.all;
use work.axi_types.all;

library unisim;
use unisim.vcomponents.all;


entity ethernet_with_axi_opt is
	generic(
		MIIM_PHY_ADDRESS      : t_phy_address := (others => '0');
		MIIM_RESET_WAIT_TICKS : natural       := 0;
		MIIM_POLL_WAIT_TICKS  : natural       := DEFAULT_POLL_WAIT_TICKS;
		-- See comment in miim for values
		-- Default is fine for 125 MHz MIIM clock
		MIIM_CLOCK_DIVIDER    : positive      := 50;
		MIIM_DISABLE          : boolean       := FALSE;

		-- See comment in rx_fifo for values
		RX_FIFO_SIZE_BITS     : positive      := 12
	);
	port(
		clk200					: in    std_logic;		-- 200MHz clock for input delay control
		-- Unbuffered 125 MHz clock input
		clock_125_i      		: in    std_ulogic;
		-- Asynchronous reset
		reset_i          		: in    std_ulogic;
		-- MAC address of this station
		-- Must not change after reset is deasserted
		mac_address_i    		: in    t_mac_address;

		-- MII (Media-independent interface)
		mii_tx_clk_i     		: in    std_ulogic;
		mii_tx_er_o      		: out   std_ulogic;
		mii_tx_en_o      		: out   std_ulogic;
		mii_txd_o        		: out   std_ulogic_vector(7 downto 0);
		mii_rx_clk_i     		: in    std_ulogic;
		mii_rx_er_i      		: in    std_ulogic;
		mii_rx_dv_i      		: in    std_ulogic;
		mii_rxd_i        		: in    std_ulogic_vector(7 downto 0);

		-- GMII (Gigabit media-independent interface)
		gmii_gtx_clk_o   		: out   std_ulogic;

		-- RGMII (Reduced pin count gigabit media-independent interface)
		rgmii_tx_ctl_o   		: out   std_ulogic;
		rgmii_rx_ctl_i   		: in    std_ulogic;

		-- MII Management Interface
		-- Clock, can be identical to clock_125_i
		-- If not, adjust MIIM_CLOCK_DIVIDER accordingly
		miim_clock_i     		: in    std_ulogic;
		mdc_o            		: out   std_ulogic;
		mdio_io          		: inout std_ulogic;
		-- Status, synchronous to miim_clock_i
		link_up_o        		: out   std_ulogic;
		speed_o          		: out   t_ethernet_speed;
		-- Also synchronous to miim_clock_i if used!
		speed_override_i 		: in    t_ethernet_speed := SPEED_UNSPECIFIED;

		axi_clk					: in std_logic;					-- clock for AXI TX and RX
		-- MAC Transmitter
		mac_tx		     	    : in axi_t;						-- data to tx
		mac_tx_ready			: out std_logic;				-- mac is ready to accept data
		-- MAC Receiver
		mac_rx		         	: out axi_t;					-- data received
		mac_rx_ready			: in  std_logic					-- tells mac that we have taken data		
	);
end entity;

architecture rtl of ethernet_with_axi_opt is

COMPONENT mac_tx_axi_fifo
  PORT (
	rst				: IN STD_LOGIC;
	wr_clk			: IN STD_LOGIC;
	rd_clk			: IN STD_LOGIC;
	din				: IN STD_LOGIC_VECTOR(7 DOWNTO 0);
	wr_en			: IN STD_LOGIC;
	rd_en			: IN STD_LOGIC;
	dout			: OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
	full			: OUT STD_LOGIC;
	empty			: OUT STD_LOGIC;
	rd_data_count	: OUT STD_LOGIC_VECTOR(10 DOWNTO 0)
);
END COMPONENT;

	type rx_state_t is (IDLE, CNT_LOW, FRAME);
	type tx_state_t is (IDLE, WAIT_1, WAIT_2, TX, TX_DONE);
	type set_sdcntr_t is (HOLD,SET,DECR);
	type set_ucntr_t is (HOLD,CLR,INCR);
	type set_clr_t is (HOLD,SET,CLR);

	-- clocks
	signal mac_tx_clock		: std_ulogic;
	signal mac_rx_clock		: std_ulogic;
	-- state
	signal rx_state			: rx_state_t;
	signal tx_state			: tx_state_t;
	signal rx_cnt_hi_reg	: std_logic_vector(7 downto 0);
	signal rx_cnt			: integer;
	signal got_frame_axi	: std_logic;		-- got a frame to TX (axi side)
	signal got_frame_1		: std_logic;
	signal got_frame_mac	: std_logic;		-- got a frame to TX (mac side)
	signal tx_cnt			: integer;
	-- interconnects
	signal rx_empty_o      	: std_ulogic;		-- RX FIFO
	signal rx_data_o       	: t_ethernet_data;
	signal tx_fifo_dout		: STD_LOGIC_VECTOR(7 DOWNTO 0);
	signal tx_fifo_full		: STD_LOGIC;
	signal tx_fifo_empty	: STD_LOGIC;
	signal tx_fifo_rd_count	: STD_LOGIC_VECTOR(10 DOWNTO 0);
	signal mac_tx_byte_sent	: std_ulogic;
	signal mac_tx_busy		: std_ulogic;
	signal mac_tx_busy_int	: std_ulogic;
	signal mac_rx_reset     : std_ulogic;
	signal mac_rx_frame		: std_ulogic;
	signal mac_rx_data		: t_ethernet_data;
	signal mac_rx_byte_received : std_ulogic;
	signal mac_rx_error         : std_ulogic;
	-- busses
	signal next_rx_state	: rx_state_t;
	signal next_tx_state	: tx_state_t;
	signal next_rx_cnt_hi	: std_logic_vector(7 downto 0);
	signal rx_cnt_val		: integer;
	signal tx_fifo_din		: STD_LOGIC_VECTOR(7 DOWNTO 0);
	signal tx_cnt_val		: integer;
	signal mac_tx_data		: t_ethernet_data;
	-- controls
	signal rx_rd_en_i		: std_ulogic;		-- read from RX FIFO
	signal set_rx_cnt		: set_sdcntr_t;
	signal tx_fifo_wr		: STD_LOGIC;
	signal tx_fifo_rd		: STD_LOGIC;
	signal set_got_tx_frame	: set_clr_t;
	signal set_tx_cnt		: set_sdcntr_t;
	signal mac_tx_enable	: std_ulogic;

begin

	-----------------------------------
	-- AXI transfer logic
	----------------------------------
	
axi_combinatorial : process (
	-- inputs
	mac_rx_ready, mac_tx, 
	-- state
	rx_state, tx_state, rx_cnt_hi_reg, rx_cnt, got_frame_axi, tx_cnt, 
	-- interconnects
	rx_empty_o, rx_data_o, tx_fifo_dout, tx_fifo_full, tx_fifo_empty, tx_fifo_rd_count, 
	mac_tx_byte_sent, mac_tx_busy, mac_tx_busy_int, mac_rx_reset, mac_rx_frame, mac_rx_data,  
	mac_rx_byte_received, mac_rx_error, 
	-- busses
	next_rx_state, next_tx_state, next_rx_cnt_hi, rx_cnt_val, tx_fifo_din, tx_cnt_val, 
	mac_tx_data, 
	-- controls
	rx_rd_en_i, set_rx_cnt, tx_fifo_wr, tx_fifo_rd, set_got_tx_frame, set_tx_cnt, 
	mac_tx_enable
	)
	begin
		-- output defaults
		mac_tx_ready <= '0';
		mac_rx <= empty_axi;
		-- output followers
		-- bus defaults
		next_rx_state <= rx_state;
		next_tx_state <= tx_state;
		next_rx_cnt_hi <= rx_cnt_hi_reg;
		rx_cnt_val <= 0;
		tx_fifo_din <= (others => '0');
		mac_tx_data <= (others => '0');
		-- control defaults
		rx_rd_en_i <= '0';
		set_rx_cnt <= HOLD;		
		tx_fifo_wr <= '0';
		tx_fifo_rd <= '0';
		set_got_tx_frame <= HOLD;
		mac_tx_enable <= '0';

		-- logic
		tx_fifo_din <= mac_tx.data;
		if mac_tx.last = '1' then
			set_got_tx_frame <= SET;
		end if;
		mac_tx_data <= t_ethernet_data(tx_fifo_dout);
		
		--			mac_tx_byte_sent_i => mac_tx_byte_sent,
		--			mac_tx_busy_i      => mac_tx_busy

		
		-- RX FSM
		case rx_state is
		
			when IDLE =>
				if rx_empty_o = '0' then
					-- RX FIFO has something in it - expect H:L count followed by frame
					next_rx_cnt_hi <= std_logic_vector(rx_data_o);
					rx_rd_en_i <= '1';
					next_rx_state <= CNT_LOW;
				end if;
				
			when CNT_LOW =>
				if rx_empty_o = '0' then
					-- RX FIFO has something in it - expect H:L count followed by frame
					rx_cnt_val <= to_integer(unsigned(rx_cnt_hi_reg & std_logic_vector(rx_data_o)));
					set_rx_cnt <= SET;
					rx_rd_en_i <= '1';
					next_rx_state <= FRAME;
				end if;
			
			when FRAME =>
				-- read frame
				mac_rx.data <= std_logic_vector(rx_data_o);
				if (rx_cnt = 0) or (rx_empty_o = '0') then
					mac_rx.valid <= '1';
				end if;
				if rx_cnt = 0 then
					mac_rx.last <= '1';
				end if;
				if mac_rx_ready = '1' then
					set_rx_cnt <= DECR;
					rx_rd_en_i <= '1';
				end if;
				if rx_cnt = 0 and mac_rx_ready = '1' then
					next_rx_state <= IDLE;
				end if;
			
		end case;
		
		-- TX FSM
		
		case tx_state is
			
			when IDLE =>
				if got_frame_axi = '0' then
					-- not busy, so can offer ready to accept data
					mac_tx_ready <= '1';
					tx_fifo_wr <= mac_tx.valid;
				end if;
				if got_frame_mac = '1' then	-- got_frame_mac is the mac clk sync'd version of got_frame_axi
					-- got a frame ready to transmit
					next_tx_state <= WAIT_1;
				end if;
				
			when WAIT_1 =>
				-- wait a couple of clocks to ensure FIFO rd count has stabilized
				next_tx_state <= WAIT_2;
				
			when WAIT_2 =>
				-- capture FIFO count as frame size
				tx_cnt_val <= to_integer(unsigned(tx_fifo_rd_count));
				set_tx_cnt <= SET;
				if mac_tx_busy = '0' then		-- wait until MAC TX is ready
					next_tx_state <= TX;
				end if;
				
			when TX =>
				-- transfer data from TX FIFO to MAC layer
				mac_tx_enable <= '1';
				if mac_tx_byte_sent = '1' then
					tx_fifo_rd <= '1';
					set_tx_cnt <= DECR;
					if tx_cnt = 0 then
						set_got_tx_frame <= CLR;
						next_tx_state <= TX_DONE;
					end if;
				end if;
				
			when TX_DONE =>
				-- ensure got_tx_frame_mac is cleared
				set_got_tx_frame <= CLR;
				next_tx_state <= IDLE;
			
		end case;
			
		
	end process;
	
axi_sequential : process (axi_clk)
	begin
		if rising_edge(axi_clk) then
			if reset_i = '1' then
				-- set initial state
				rx_state <= IDLE;
				rx_cnt_hi_reg <= x"00";
				rx_cnt <= 0; 
			else
				-- normal processing
				
				-- handle state transitioins
				rx_state <= next_rx_state;
				rx_cnt_hi_reg <= next_rx_cnt_hi;
				
				-- process counters
				
				case set_rx_cnt is
					when SET  => rx_cnt <= rx_cnt_val;
					when DECR => rx_cnt <= rx_cnt - 1;
					when HOLD => -- do nothing
				end case;
					
			end if;
		end if;
	end process;

mac_sequential : process (mac_tx_clock)
	begin
		if rising_edge(mac_tx_clock) then
			if reset_i = '1' then
				-- set initial state
				tx_state <= IDLE;
			else
				-- normal processing
				
				-- handle state transitioins
				tx_state <= next_tx_state;
				
				-- synchronisers
				got_frame_mac <= got_frame_1;
				got_frame_1 <= got_frame_axi;

				-- counters
				case set_tx_cnt is
					when SET  => tx_cnt <= tx_cnt_val;
					when DECR => tx_cnt <= tx_cnt - 1;
					when HOLD => -- do nothing
				end case;
				
			end if;
		end if;
	end process;

	-- Needed for correct simulation of the inter-packet gap
	-- Without any delay, tx_fifo_adapter would see the tx_busy indication too early
	-- This generally applies to all signals, but the behavior of the other ones
	-- does not cause simulation mismatches.
	mac_tx_busy <= transport mac_tx_busy_int after 1 ns;


	ethernet_inst : entity work.ethernet
		generic map(
			MIIM_PHY_ADDRESS      => MIIM_PHY_ADDRESS,
			MIIM_RESET_WAIT_TICKS => MIIM_RESET_WAIT_TICKS,
			MIIM_POLL_WAIT_TICKS  => MIIM_POLL_WAIT_TICKS,
			MIIM_CLOCK_DIVIDER    => MIIM_CLOCK_DIVIDER,
			MIIM_DISABLE          => MIIM_DISABLE
		)
		port map(
			clock_125_i        => clock_125_i,
			reset_i            => reset_i,
			reset_o            => open,
			mac_address_i      => mac_address_i,
			mii_tx_clk_i       => mii_tx_clk_i,
			mii_tx_er_o        => mii_tx_er_o,
			mii_tx_en_o        => mii_tx_en_o,
			mii_txd_o          => mii_txd_o,
			mii_rx_clk_i       => mii_rx_clk_i,
			mii_rx_er_i        => mii_rx_er_i,
			mii_rx_dv_i        => mii_rx_dv_i,
			mii_rxd_i          => mii_rxd_i,
			gmii_gtx_clk_o     => gmii_gtx_clk_o,
			rgmii_tx_ctl_o     => rgmii_tx_ctl_o,
			rgmii_rx_ctl_i     => rgmii_rx_ctl_i,
			miim_clock_i       => miim_clock_i,
			mdc_o              => mdc_o,
			mdio_io            => mdio_io,
			tx_reset_o         => open,
			tx_clock_o         => mac_tx_clock,
			tx_enable_i        => mac_tx_enable,
			tx_data_i          => mac_tx_data,
			tx_byte_sent_o     => mac_tx_byte_sent,
			tx_busy_o          => mac_tx_busy_int,
			rx_reset_o         => mac_rx_reset,
			rx_clock_o         => mac_rx_clock,
			rx_frame_o         => mac_rx_frame,
			rx_data_o          => mac_rx_data,
			rx_byte_received_o => mac_rx_byte_received,
			rx_error_o         => mac_rx_error,
			link_up_o          => link_up_o,
			speed_o            => speed_o,
			speed_override_i   => speed_override_i
		);

	rx_fifo_inst : entity work.rx_fifo
		generic map(
			MEMORY_SIZE_BITS => RX_FIFO_SIZE_BITS
		)
		port map(
			clock_i                => axi_clk,
			mac_rx_reset_i         => mac_rx_reset,
			mac_rx_clock_i         => mac_rx_clock,
			mac_rx_frame_i         => mac_rx_frame,
			mac_rx_data_i          => mac_rx_data,
			mac_rx_byte_received_i => mac_rx_byte_received,
			mac_rx_error_i         => mac_rx_error,
			empty_o                => rx_empty_o,
			rd_en_i                => rx_rd_en_i,
			data_o                 => rx_data_o
		);
		
		
	tx_fifo : mac_tx_axi_fifo
		PORT MAP (
			rst 			=> reset_i,
			wr_clk			=> axi_clk,
			rd_clk			=> mac_tx_clock,
			din				=> tx_fifo_din,
			wr_en			=> tx_fifo_wr,
			rd_en			=> tx_fifo_rd,
			dout			=> tx_fifo_dout,
			full			=> tx_fifo_full,
			empty			=> tx_fifo_empty,
			rd_data_count	=> tx_fifo_rd_count
		);

	IDELAYCTRL_inst : IDELAYCTRL
	port map (
	   RDY 		=> open,		-- 1-bit output: Ready output
	   REFCLK 	=> clk200,		-- 1-bit input: Reference clock input
	   RST		=> reset_i		-- 1-bit input: Active high reset input
	);


--	tx_fifo_inst : entity work.tx_fifo
--		port map(
--			clock_i            => axi_clk,
--			data_i             => tx_data_i,
--			wr_en_i            => tx_wr_en_i,
--			full_o             => tx_full_o,
--			mac_tx_reset_i     => mac_tx_reset,
--			mac_tx_clock_i     => mac_tx_clock,
--			mac_tx_enable_o    => mac_tx_enable,
--			mac_tx_data_o      => mac_tx_data,
--			mac_tx_byte_sent_i => mac_tx_byte_sent,
--			mac_tx_busy_i      => mac_tx_busy
--		);

end architecture;

