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
use work.axi_types.all;

entity axi_ctrl is
	port(
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
		tx_wr					: out std_ulogic;
		tx_ready				: in std_logic
	);
end entity;

architecture rtl of axi_ctrl is

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
	type tx_state_t is (IDLE, FILL_FIFO, CNT_H, CNT_L, TX, WAIT_READY);
	type set_sdcntr_t is (HOLD,SET,DECR);
	type set_ucntr_t is (HOLD,CLR,INCR);
	type set_clr_t is (HOLD,SET,CLR);

	-- state
	signal rx_state			: rx_state_t;
	signal tx_state			: tx_state_t;
	signal rx_cnt_hi_reg	: std_logic_vector(7 downto 0);
	signal rx_cnt			: integer;
	signal tx_cnt			: unsigned(10 downto 0);
	-- interconnects
	signal tx_fifo_dout		: STD_LOGIC_VECTOR(7 DOWNTO 0);
	signal tx_fifo_full		: STD_LOGIC;
	signal tx_fifo_empty	: STD_LOGIC;
	signal tx_fifo_rd_count	: STD_LOGIC_VECTOR(10 DOWNTO 0);
	-- busses
	signal next_rx_state	: rx_state_t;
	signal next_tx_state	: tx_state_t;
	signal next_rx_cnt_hi	: std_logic_vector(7 downto 0);
	signal rx_cnt_val		: integer;
	signal tx_fifo_din		: STD_LOGIC_VECTOR(7 DOWNTO 0);
	-- controls
	signal set_rx_cnt		: set_sdcntr_t;
	signal tx_fifo_wr		: STD_LOGIC;
	signal tx_fifo_rd		: STD_LOGIC;
	signal set_tx_cnt		: set_ucntr_t;

begin

axi_combinatorial : process (
	-- inputs
	reset, mac_tx, mac_rx_ready, rx_data, rx_empty, tx_ready, 
	-- state
	rx_state, tx_state, rx_cnt_hi_reg, rx_cnt, tx_cnt, 
	-- interconnects
	tx_fifo_dout, tx_fifo_full, tx_fifo_empty, tx_fifo_rd_count, 
	-- busses
	next_rx_state, next_tx_state, next_rx_cnt_hi, rx_cnt_val, tx_fifo_din, 
	-- controls
	set_rx_cnt, tx_fifo_wr, tx_fifo_rd, set_tx_cnt
	)
	begin
		-- output defaults
		mac_tx_ready <= '0';
		mac_rx <= empty_axi;
		mac_rx.data <= std_logic_vector(rx_data);
		rx_rd <= '0';
		tx_data <= (others => '0');
		tx_wr <= '0';
		-- output followers
		-- bus defaults
		next_rx_state <= rx_state;
		next_tx_state <= tx_state;
		next_rx_cnt_hi <= rx_cnt_hi_reg;
		rx_cnt_val <= 0;
		tx_fifo_din <= (others => '0');
		-- control defaults
		set_rx_cnt <= HOLD;		
		tx_fifo_wr <= '0';
		tx_fifo_rd <= '0';
		set_tx_cnt <= HOLD;		

		-- logic
		tx_fifo_din <= mac_tx.data;
				
		-- RX FSM
		case rx_state is
		
			when IDLE =>
				if rx_empty = '0' then
					-- RX FIFO has something in it - expect H:L count followed by frame
					next_rx_cnt_hi <= std_logic_vector(rx_data);
					rx_rd <= '1';
					next_rx_state <= CNT_LOW;
				end if;
				
			when CNT_LOW =>
				if rx_empty = '0' then
					-- RX FIFO has something in it - expect H:L count followed by frame
					rx_cnt_val <= to_integer(unsigned(rx_cnt_hi_reg & std_logic_vector(rx_data)));
					set_rx_cnt <= SET;
					rx_rd <= '1';
					next_rx_state <= FRAME;
				end if;
			
			when FRAME =>
				-- read frame
				if (rx_cnt = 0) or (rx_empty = '0') then
					mac_rx.valid <= '1';
				end if;
				if rx_cnt = 0 then
					mac_rx.last <= '1';
				end if;
				if mac_rx_ready = '1' then
					set_rx_cnt <= DECR;
					rx_rd <= '1';
				end if;
				if rx_cnt = 0 and mac_rx_ready = '1' then
					next_rx_state <= IDLE;
				end if;
			
		end case;
		
		-- TX FSM
		
		case tx_state is
			
			when IDLE =>
				set_tx_cnt <= CLR;
				mac_tx_ready <= '1';
				if mac_tx.valid = '1' then
					tx_fifo_wr <= '1';
					set_tx_cnt <= INCR;
					next_tx_state <= FILL_FIFO;
				end if;

			when FILL_FIFO =>
				-- fill the local FIFO
				mac_tx_ready <= '1';
				if mac_tx.valid = '1' then
					tx_fifo_wr <= '1';
					set_tx_cnt <= INCR;
				end if;
				if mac_tx.last = '1' then
					next_tx_state <= CNT_H;
				end if;

			-- transfer the local FIFO contents into the lower layer starting with 2 byte count
			
			when CNT_H =>
				tx_data <= t_ethernet_data("00000" & tx_cnt(10 downto 8));
				if tx_ready = '1' then
					tx_wr <= '1';
					next_tx_state <= CNT_L;
				end if;
				
			when CNT_L =>
				tx_data <= t_ethernet_data(tx_cnt(7 downto 0));
				if tx_ready = '1' then
					tx_wr <= '1';
					next_tx_state <= TX;
				end if;
			
			when TX =>
				-- transfer data from TX FIFO to MAC layer
				tx_data <= t_ethernet_data(tx_fifo_dout);
				if tx_fifo_empty = '1' then
					next_tx_state <= WAIT_READY;
				else
					if tx_ready = '1' then
						tx_wr <= '1';
						tx_fifo_rd <= '1';
					end if;
				end if;
				
			when WAIT_READY =>
				set_tx_cnt <= CLR;
				if tx_ready = '1' then
					next_tx_state <= IDLE;
				end if;
				
			
		end case;			
		
	end process;
	
axi_sequential : process (clk)
	begin
		if rising_edge(clk) then
			if reset = '1' then
				-- set initial state
				rx_state <= IDLE;
				rx_cnt_hi_reg <= x"00";
				rx_cnt <= 0; 
				tx_state <= IDLE;
				tx_cnt <= (others => '0');
			else
				-- normal processing
				
				-- handle state transitioins
				rx_state <= next_rx_state;
				rx_cnt_hi_reg <= next_rx_cnt_hi;
				tx_state <= next_tx_state;
				
				-- process counters
				
				case set_rx_cnt is
					when SET  => rx_cnt <= rx_cnt_val;
					when DECR => rx_cnt <= rx_cnt - 1;
					when HOLD => -- do nothing
				end case;

				case set_tx_cnt is
					when CLR  => tx_cnt <= (others => '0');
					when INCR => tx_cnt <= tx_cnt + 1;
					when HOLD => -- do nothing
				end case;

			end if;
		end if;
	end process;
		
	tx_fifo : mac_tx_axi_fifo
		PORT MAP (
			rst 			=> reset,
			wr_clk			=> clk,
			rd_clk			=> clk,
			din				=> tx_fifo_din,
			wr_en			=> tx_fifo_wr,
			rd_en			=> tx_fifo_rd,
			dout			=> tx_fifo_dout,
			full			=> tx_fifo_full,
			empty			=> tx_fifo_empty,
			rd_data_count	=> tx_fifo_rd_count
		);


end architecture;

