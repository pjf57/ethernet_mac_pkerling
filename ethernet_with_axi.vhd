-- This file is part of the ethernet_mac project.
--
-- Author: Peter Fal
-- this is a lazy version - double buffers the TX so as to obtain the frame size before sending to ethernet_with_fifos
--
-- For the full copyright and license information, please read the
-- LICENSE.md file that was distributed with this source code.

-- Prebuilt Ethernet MAC with FIFOs connected

library ieee;
use ieee.std_logic_1164.all;
use IEEE.NUMERIC_STD.ALL;
use work.ethernet_types.all;
use work.utility.all;
use work.miim_types.all;
use work.axi_types.all;
use work.nwk_types.all;

library unisim;
use unisim.vcomponents.all;


entity ethernet_with_axi is
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
		mac_address_i    		: in    mac_addr_t;

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

architecture rtl of ethernet_with_axi is

	-- interconnects from ethernet mac layer
	signal rx_empty_o      	: std_ulogic;
	signal rx_data_o       	: t_ethernet_data;
	signal mac_tx_full		: std_logic;
	-- interconnects from controller
	signal mac_tx_data		: t_ethernet_data;
	signal mac_tx_wr		: std_ulogic;
	signal rx_rd_en_i		: std_ulogic;
	-- busses
	signal mac_address_rev	: t_mac_address;
	-- controls
	signal tx_ready			: std_logic;

begin

combinatoria : process (
	-- inputs
	reset_i, mac_address_i, 
	mii_tx_clk_i, mii_rx_clk_i, mii_rx_er_i, mii_rx_dv_i, mii_rxd_i, 
	rgmii_rx_ctl_i, miim_clock_i, 
	speed_override_i, axi_clk, mac_tx, mac_rx_ready, 
	-- interconnects
	rx_empty_o, rx_data_o, mac_tx_data, mac_tx_wr, rx_rd_en_i, mac_tx_full, 
	-- busses
	mac_address_rev, 
	-- controls 
	tx_ready
)
begin
	mac_address_rev <= reverse_bytes(std_ulogic_vector(mac_address_i));	-- pkerling stack needs MAC addr reveresed
	tx_ready <= not mac_tx_full;
end process;

	ethernet_inst : entity work.ethernet_with_fifos
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
	    	-- MAC address of this station
			-- Must not change after reset is deasserted
			mac_address_i      => mac_address_rev,
	    	-- MII (Media-independent interface)
			mii_tx_clk_i       => mii_tx_clk_i,
			mii_tx_er_o        => mii_tx_er_o,
			mii_tx_en_o        => mii_tx_en_o,
			mii_txd_o          => mii_txd_o,
			mii_rx_clk_i       => mii_rx_clk_i,
			mii_rx_er_i        => mii_rx_er_i,
			mii_rx_dv_i        => mii_rx_dv_i,
			mii_rxd_i          => mii_rxd_i,
		   	-- GMII (Gigabit media-independent interface)
			gmii_gtx_clk_o     => gmii_gtx_clk_o,
	    	-- RGMII (Reduced pin count gigabit media-independent interface)
			rgmii_tx_ctl_o     => rgmii_tx_ctl_o,
			rgmii_rx_ctl_i     => rgmii_rx_ctl_i,
	    	-- MII Management Interface
			-- Clock, can be identical to clock_125_i
			-- If not, adjust MIIM_CLOCK_DIVIDER accordingly
			miim_clock_i       => miim_clock_i,
			mdc_o              => mdc_o,
			mdio_io            => mdio_io,
	    	-- Status, synchronous to miim_clock_i
			link_up_o			=> link_up_o,
			speed_o				=> speed_o,
	    	-- Also synchronous to miim_clock_i if used!
			speed_override_i	=> speed_override_i,

	    	-- TX FIFO
			tx_clock_i			=> axi_clk,
    		-- Synchronous reset
			-- When asserted, the content of the buffer was lost.
			-- When full is deasserted the next time, a packet size must be written.
			-- The data of the packet previously being written is not available anymore then.
			tx_reset_o			=> open,
			tx_data_i			=> mac_tx_data,
			tx_wr_en_i			=> mac_tx_wr,
			tx_full_o			=> mac_tx_full,
	    	-- RX FIFO
			rx_clock_i			=> axi_clk,
	    	-- Synchronous reset
			-- When asserted, the content of the buffer was lost.
			-- When empty is deasserted the next time, a packet size must be read out.
			-- The data of the packet previously being read out is not available anymore then.
			rx_reset_o			=> open,
			rx_empty_o			=> rx_empty_o,
			rx_rd_en_i			=> rx_rd_en_i,
			rx_data_o			=> rx_data_o
		);

controller : entity work.axi_ctrl
	PORT MAP (
		reset 			=> reset_i,
		clk				=> axi_clk,
		-- MAC Transmitter
		mac_tx			=> mac_tx,
		mac_tx_ready	=> mac_tx_ready,
		-- MAC Receiver
		mac_rx			=> mac_rx,
		mac_rx_ready	=> mac_rx_ready,
		-- ethernet MAC layer signals
		-- RX FIFO
		rx_data			=> rx_data_o,
		rx_rd			=> rx_rd_en_i,
		rx_empty		=> rx_empty_o,
		-- TX FIFO
		tx_data			=> mac_tx_data,
		tx_wr			=> mac_tx_wr,
		tx_ready		=> tx_ready
	);
	

	IDELAYCTRL_inst : IDELAYCTRL
	port map (
	   RDY 		=> open,		-- 1-bit output: Ready output
	   REFCLK 	=> clk200,		-- 1-bit input: Reference clock input
	   RST		=> reset_i		-- 1-bit input: Active high reset input
	);


end architecture;

