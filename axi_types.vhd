----------------------------------------------------------------------------------
-- Company: 			Cheetah Solutions
-- Engineer: 			Peter Fall
-- 
-- Create Date:    	2 Sep 2016
-- Design Name: 
-- Module Name:    	axi_types 
-- Project Name: 		NWK
-- Target Devices: 
-- Tool versions: 
-- Description: 		Declares types for AXI busses
--
--
--
-- Dependencies: 
--
-- Revision: 
-- Additional Comments: 
--
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.all;

package axi_types is
	
	type axi_t is record
		valid					: std_logic;								-- indicates data is valid
		data					: std_logic_vector (7 downto 0);		-- data value
		last					: std_logic;								-- with data out valid indicates the last byte of a frame
	end record;
	
-- create empty records
function empty_axi return axi_t;	

end axi_types;


package body axi_types is

function empty_axi return axi_t is
	variable a : axi_t;
begin
	a.valid := '0';
	a.data := (others => '0');
	a.last := '0';
	return a;
end empty_axi;

end axi_types;
